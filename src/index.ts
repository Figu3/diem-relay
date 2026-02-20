import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { config, validateConfig } from "./config";
import { authenticate, buildAuthMessage, validateSession } from "./auth";
import { preflightCheck, meterUsage } from "./metering";
import { forwardChatCompletion, listModels } from "./proxy";
import {
  getBorrower,
  upsertBorrower,
  addCredit,
  getAllBorrowers,
  getUsageSummary,
  getRecentUsage,
  cleanExpiredSessions,
} from "./db";

validateConfig();

const app = new Hono();

app.use("*", cors());
app.use("*", logger());

// ── Health ──

app.get("/health", (c) => c.json({ status: "ok", timestamp: Date.now() }));

// ── Auth endpoints ──

app.get("/auth/message", (c) => {
  const address = c.req.query("address");
  if (!address) return c.json({ error: "address query param required" }, 400);

  const timestamp = Math.floor(Date.now() / 1000);
  const message = buildAuthMessage(address, timestamp);

  return c.json({ message, timestamp });
});

app.post("/auth/login", async (c) => {
  const body = await c.req.json<{
    address: string;
    timestamp: number;
    signature: `0x${string}`;
  }>();

  const result = await authenticate(body);
  if (!result.success) {
    return c.json({ error: result.error }, 401);
  }

  return c.json({
    sessionToken: result.sessionToken,
    expiresAt: result.expiresAt,
  });
});

// ── Session middleware for protected routes ──

function requireSession() {
  return async (c: any, next: any) => {
    const authHeader = c.req.header("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return c.json({ error: "Missing Authorization: Bearer <session_token>" }, 401);
    }

    const token = authHeader.slice(7);
    const session = validateSession(token);
    if (!session.valid) {
      return c.json({ error: session.error }, 401);
    }

    c.set("borrower", session.borrower);
    await next();
  };
}

// ── Proxy: OpenAI-compatible chat completions ──

app.post("/v1/chat/completions", requireSession(), async (c) => {
  const borrower = c.get("borrower") as string;
  const body = await c.req.json();

  if (!body.model || !body.messages) {
    return c.json({ error: "model and messages are required" }, 400);
  }

  // Pre-flight: check balance and daily limit
  const preflight = preflightCheck(borrower, body.model);
  if (!preflight.allowed) {
    return c.json({ error: preflight.error }, 402);
  }

  // Forward to Venice
  const venice = await forwardChatCompletion(body);

  if (!venice.ok) {
    return c.json(
      { error: "Venice API error", details: venice.error },
      venice.status as any
    );
  }

  // Meter usage
  if (venice.usage) {
    const metering = meterUsage(borrower, {
      model: body.model,
      promptTokens: venice.usage.promptTokens,
      completionTokens: venice.usage.completionTokens,
      requestId: venice.data?.id,
    });

    if (!metering.allowed) {
      // Rare: balance was sufficient at preflight but not after computing exact cost
      return c.json({ error: metering.error }, 402);
    }

    // Get updated balance
    const b = getBorrower(borrower);

    // Return Venice response with extra headers
    return c.json(venice.data, 200, {
      "x-diem-charged-usd": metering.chargedUsd.toFixed(6),
      "x-diem-balance-usd": b?.balance_usd.toFixed(6) ?? "0",
      "x-diem-protocol-fee": metering.protocolFee.toFixed(6),
    });
  }

  // No usage data (shouldn't happen with non-streaming)
  return c.json(venice.data, 200);
});

// ── Borrower info ──

app.get("/v1/balance", requireSession(), (c) => {
  const borrower = c.get("borrower") as string;
  const b = getBorrower(borrower);
  if (!b) return c.json({ error: "Not found" }, 404);

  return c.json({
    address: b.address,
    alias: b.alias,
    balanceUsd: b.balance_usd,
    totalSpent: b.total_spent,
    dailySpent: b.daily_spent,
    maxDailySpend: config.maxDailySpendUsd,
    discountRate: config.discountRate,
  });
});

app.get("/v1/models", requireSession(), async (c) => {
  const result = await listModels();
  if (!result.ok) return c.json({ error: result.error }, 502);
  return c.json(result.data);
});

// ── Admin endpoints (secured by admin secret) ──

function requireAdmin() {
  return async (c: any, next: any) => {
    const secret = c.req.header("X-Admin-Secret");
    if (secret !== config.adminSecret) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    await next();
  };
}

app.post("/admin/borrowers", requireAdmin(), async (c) => {
  const body = await c.req.json<{ address: string; alias?: string }>();
  if (!body.address) return c.json({ error: "address required" }, 400);
  const borrower = upsertBorrower(body.address, body.alias);
  return c.json(borrower);
});

app.post("/admin/credit", requireAdmin(), async (c) => {
  const body = await c.req.json<{
    address: string;
    amountUsd: number;
    txHash?: string;
    note?: string;
  }>();

  if (!body.address || !body.amountUsd) {
    return c.json({ error: "address and amountUsd required" }, 400);
  }

  const borrower = addCredit(body.address, body.amountUsd, body.txHash, body.note);
  return c.json(borrower);
});

app.get("/admin/borrowers", requireAdmin(), (c) => {
  return c.json(getAllBorrowers());
});

app.get("/admin/borrowers/:address", requireAdmin(), (c) => {
  const address = c.req.param("address");
  const borrower = getBorrower(address);
  if (!borrower) return c.json({ error: "Not found" }, 404);

  const usage = getUsageSummary(address);
  return c.json({ borrower, usage });
});

app.get("/admin/usage", requireAdmin(), (c) => {
  const days = Number(c.req.query("days") ?? 30);
  const summary = getUsageSummary(undefined, days);
  const recent = getRecentUsage(50);
  return c.json({ summary, recent });
});

app.get("/admin/stats", requireAdmin(), (c) => {
  const summary = getUsageSummary(undefined, 30);
  const borrowers = getAllBorrowers();
  const activeBorrowers = borrowers.filter((b) => b.total_spent > 0).length;
  const totalBalance = borrowers.reduce((s, b) => s + b.balance_usd, 0);

  return c.json({
    totalBorrowers: borrowers.length,
    activeBorrowers,
    totalCreditBalance: totalBalance,
    last30Days: summary,
  });
});

// ── Periodic cleanup ──

setInterval(() => {
  cleanExpiredSessions();
}, 60_000); // every minute

// ── Start ──

console.log(`\n  DIEM Relay v0.1.0`);
console.log(`  Listening on ${config.host}:${config.port}`);
console.log(`  Discount rate: ${config.discountRate * 100}%`);
console.log(`  Protocol fee: ${config.protocolFeeBps / 100}%`);
console.log(`  Daily limit: $${config.maxDailySpendUsd}\n`);

export default {
  port: config.port,
  hostname: config.host,
  fetch: app.fetch,
};
