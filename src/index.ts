import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { bodyLimit } from "hono/body-limit";
import { isAddress } from "viem";
import crypto from "crypto";
import { config, validateConfig } from "./config";
import { authenticate, buildAuthMessage, validateSession } from "./auth";
import { preflightCheck, meterUsage, refundPreflight } from "./metering";
import { forwardChatCompletion, listModels } from "./proxy";
import {
  getDb,
  getBorrower,
  upsertBorrower,
  addCredit,
  getAllBorrowers,
  getUsageSummary,
  getRecentUsage,
  cleanExpiredSessions,
  invalidateBorrowerSessions,
} from "./db";

validateConfig();

type Env = {
  Variables: {
    borrower: string;
  };
};

const app = new Hono<Env>();

app.use("*", cors());
app.use("*", logger());

// M-1: Body size limit — 64 KB is generous for chat completion payloads
app.use("/v1/*", bodyLimit({ maxSize: 64 * 1024 }));
app.use("/auth/*", bodyLimit({ maxSize: 4 * 1024 }));
app.use("/admin/*", bodyLimit({ maxSize: 16 * 1024 }));

// ── M-4: Simple in-memory rate limiter for auth endpoints ──

const authAttempts = new Map<string, { count: number; resetAt: number }>();
const AUTH_RATE_LIMIT = 10; // max attempts per window
const AUTH_RATE_WINDOW_MS = 60_000; // 1 minute

function checkAuthRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = authAttempts.get(ip);
  if (!entry || now > entry.resetAt) {
    authAttempts.set(ip, { count: 1, resetAt: now + AUTH_RATE_WINDOW_MS });
    return true;
  }
  entry.count++;
  return entry.count <= AUTH_RATE_LIMIT;
}

// Clean up rate limiter map periodically
setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of authAttempts) {
    if (now > entry.resetAt) authAttempts.delete(ip);
  }
}, 60_000);

// ── Health ──

app.get("/health", (c) => c.json({ status: "ok", timestamp: Date.now() }));

// ── Auth endpoints ──

app.get("/auth/message", (c) => {
  const address = c.req.query("address");
  if (!address) return c.json({ error: "address query param required" }, 400);

  // L-2: Validate address format
  if (!isAddress(address)) {
    return c.json({ error: "Invalid Ethereum address format" }, 400);
  }

  const timestamp = Math.floor(Date.now() / 1000);
  const message = buildAuthMessage(address, timestamp);

  return c.json({ message, timestamp });
});

app.post("/auth/login", async (c) => {
  // M-4: Rate limit auth attempts by IP
  const ip = c.req.header("x-forwarded-for") ?? c.req.header("x-real-ip") ?? "unknown";
  if (!checkAuthRateLimit(ip)) {
    return c.json({ error: "Too many auth attempts, try again later" }, 429);
  }

  const body = await c.req.json<{
    address: string;
    timestamp: number;
    signature: `0x${string}`;
  }>();

  // L-2: Validate address format
  if (!body.address || !isAddress(body.address)) {
    return c.json({ error: "Invalid Ethereum address format" }, 400);
  }

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

  // H-1: Pre-flight — atomically reserve estimated cost
  const preflight = preflightCheck(borrower, body.model);
  if (!preflight.allowed) {
    return c.json({ error: preflight.error }, 402);
  }

  // Forward to Venice
  let venice;
  try {
    venice = await forwardChatCompletion(body);
  } catch (err) {
    // H-1: Refund reservation on network/unexpected error
    refundPreflight(borrower, preflight.reservedUsd);
    return c.json({ error: "Upstream API unavailable" }, 502);
  }

  if (!venice.ok) {
    // H-1: Refund reservation on Venice error
    refundPreflight(borrower, preflight.reservedUsd);
    // L-3: Don't leak Venice error details to borrowers
    console.error(`Venice error (${venice.status}): ${venice.error}`);
    return c.json(
      { error: "Upstream API error" },
      venice.status >= 500 ? 502 : (venice.status as any)
    );
  }

  // H-1: Settle actual usage (refunds difference from reservation)
  if (venice.usage) {
    const metering = meterUsage(
      borrower,
      {
        model: body.model,
        promptTokens: venice.usage.promptTokens,
        completionTokens: venice.usage.completionTokens,
        requestId: venice.data?.id,
      },
      preflight.reservedUsd
    );

    // Get updated balance
    const b = getBorrower(borrower);

    // Return Venice response with extra headers
    return c.json(venice.data, 200, {
      "x-diem-charged-usd": metering.chargedUsd.toFixed(6),
      "x-diem-balance-usd": b?.balance_usd.toFixed(6) ?? "0",
      "x-diem-protocol-fee": metering.protocolFee.toFixed(6),
    });
  }

  // No usage data (shouldn't happen with non-streaming) — refund reservation
  refundPreflight(borrower, preflight.reservedUsd);
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
  if (!result.ok) return c.json({ error: "Upstream model list unavailable" }, 502);
  return c.json(result.data);
});

// ── Admin endpoints (secured by admin secret) ──

// H-2: Timing-safe comparison to prevent timing attacks on admin secret
function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b) return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function requireAdmin() {
  return async (c: any, next: any) => {
    const secret = c.req.header("X-Admin-Secret") ?? "";
    if (!timingSafeEqual(secret, config.adminSecret)) {
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

  const { borrower, alreadyProcessed } = addCredit(body.address, body.amountUsd, body.txHash, body.note);
  return c.json({ ...borrower, alreadyProcessed });
});

// M-2: Suspend/unsuspend borrower + invalidate sessions
app.post("/admin/borrowers/:address/suspend", requireAdmin(), (c) => {
  const address = c.req.param("address");
  const borrower = getBorrower(address);
  if (!borrower) return c.json({ error: "Not found" }, 404);

  getDb().prepare(
    "UPDATE borrowers SET active = 0, updated_at = unixepoch() WHERE address = ?"
  ).run(address.toLowerCase());

  const sessionsRemoved = invalidateBorrowerSessions(address);

  return c.json({
    suspended: true,
    sessionsInvalidated: sessionsRemoved,
  });
});

app.post("/admin/borrowers/:address/unsuspend", requireAdmin(), (c) => {
  const address = c.req.param("address");
  const borrower = getBorrower(address);
  if (!borrower) return c.json({ error: "Not found" }, 404);

  getDb().prepare(
    "UPDATE borrowers SET active = 1, updated_at = unixepoch() WHERE address = ?"
  ).run(address.toLowerCase());

  return c.json({ suspended: false });
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

const cleanupInterval = setInterval(() => {
  cleanExpiredSessions();
}, 60_000); // every minute

// ── L-5: Graceful shutdown ──

function shutdown(signal: string) {
  console.log(`\n  Received ${signal}, shutting down gracefully...`);
  clearInterval(cleanupInterval);
  // Give in-flight requests 5s to finish
  setTimeout(() => {
    console.log("  Shutdown complete.");
    process.exit(0);
  }, 5_000);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

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
