/**
 * End-to-end test for the DIEM Relay v0.2.0 pipeline.
 *
 * Tests the full credit model: pricing, buy (sameday/advance),
 * idempotency, auth, balance, chat completions, and usage settlement.
 *
 * Requires:
 *   - Relay server running (bun run dev)
 *   - ADMIN_SECRET env var set
 *   - RELAY_URL env var (default http://localhost:3100)
 *
 * Usage: bun run test:e2e
 */

import { privateKeyToAccount } from "viem/accounts";

const RELAY_URL = process.env.RELAY_URL ?? "http://localhost:3100";
const ADMIN_SECRET = process.env.ADMIN_SECRET ?? "";

// Hardhat account #0 — throwaway test key, never used for real funds
const TEST_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const account = privateKeyToAccount(TEST_PRIVATE_KEY);

const green = (s: string) => `\x1b[32m\u2713 ${s}\x1b[0m`;
const red = (s: string) => `\x1b[31m\u2717 ${s}\x1b[0m`;
const dim = (s: string) => `\x1b[2m  ${s}\x1b[0m`;

let passed = 0;
let failed = 0;

async function step(name: string, fn: () => Promise<void>) {
  try {
    await fn();
    console.log(green(name));
    passed++;
  } catch (e: any) {
    console.log(red(name));
    console.log(dim(e.message ?? String(e)));
    failed++;
    throw e; // stop on first failure
  }
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

const adminHeaders = {
  "Content-Type": "application/json",
  "X-Admin-Secret": ADMIN_SECRET,
};

async function main() {
  console.log("\n  DIEM Relay v0.2.0 \u2014 End-to-End Test\n");
  console.log(dim(`Relay:   ${RELAY_URL}`));
  console.log(dim(`Address: ${account.address}`));
  console.log();

  if (!ADMIN_SECRET) {
    console.log(red("ADMIN_SECRET env var is required"));
    process.exit(1);
  }

  let sessionToken = "";

  // ── Step 1: Health check ──
  await step("Health check", async () => {
    const res = await fetch(`${RELAY_URL}/health`);
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(data.status === "ok", `Expected status "ok", got "${data.status}"`);
  });

  // ── Step 2: Pricing endpoint ──
  await step("GET /v1/pricing returns rates", async () => {
    const res = await fetch(`${RELAY_URL}/v1/pricing`);
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;

    // Advance should always be available
    assert(data.advance?.available === true, "advance.available should be true");
    assert(
      typeof data.advance?.discountRate === "number",
      "advance.discountRate should be a number"
    );
    assert(!!data.advance?.validDate, "advance.validDate missing");

    // Sameday has dynamic availability
    assert(typeof data.sameday?.available === "boolean", "sameday.available missing");
    assert(typeof data.sameday?.cutoffHourUtc === "number", "sameday.cutoffHourUtc missing");

    // Protocol fee
    assert(typeof data.protocolFeeBps === "number", "protocolFeeBps missing");

    console.log(
      dim(
        `Advance: ${data.advance.discountRate} | Sameday: ${data.sameday.discountRate ?? "closed"} | Fee: ${data.protocolFeeBps}bps`
      )
    );
  });

  // ── Step 3: Create test borrower ──
  await step("Create test borrower", async () => {
    const res = await fetch(`${RELAY_URL}/admin/borrowers`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({ address: account.address, alias: "e2e-test" }),
    });
    // 200 OK or 409 Conflict (already exists) are both fine
    assert(res.ok || res.status === 409, `HTTP ${res.status}: ${await res.text()}`);
  });

  // ── Step 4: Buy credits via /v1/buy (advance) ──
  let advanceCreditId = 0;
  await step("POST /v1/buy advance $10", async () => {
    const res = await fetch(`${RELAY_URL}/v1/buy`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 10.0,
        purchaseType: "advance",
        txHash: "0xe2e_advance_test_" + Date.now(),
      }),
    });
    const body = await res.text();
    assert(res.status === 201, `Expected 201, got ${res.status}: ${body}`);
    const data = JSON.parse(body) as any;
    assert(data.creditId > 0, `creditId should be > 0, got ${data.creditId}`);
    assert(data.alreadyProcessed === false, "Should not be already processed");
    assert(data.purchaseType === "advance", `Expected advance, got ${data.purchaseType}`);
    assert(data.discountRate === 0.85, `Expected 0.85, got ${data.discountRate}`);
    advanceCreditId = data.creditId;
    console.log(
      dim(`creditId=${data.creditId} valid=${data.validDate} rate=${data.discountRate}`)
    );
  });

  // ── Step 5: Buy credits via /v1/buy (sameday) — for today ──
  await step("POST /v1/buy sameday $5", async () => {
    const res = await fetch(`${RELAY_URL}/v1/buy`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 5.0,
        purchaseType: "sameday",
      }),
    });

    // Sameday might be closed depending on UTC hour — both outcomes are valid
    if (res.status === 400) {
      const data = (await res.json()) as any;
      if (data.error === "Same-day credit sales closed") {
        console.log(dim("Sameday closed (past cutoff) — OK, skipping"));
        return;
      }
    }

    assert(res.status === 201, `Expected 201, got ${res.status}`);
    const data = (await res.json()) as any;
    assert(data.creditId > 0, `creditId should be > 0`);
    assert(data.purchaseType === "sameday", `Expected sameday, got ${data.purchaseType}`);
    assert(data.discountRate > 0 && data.discountRate < 1, `Unexpected rate: ${data.discountRate}`);
    console.log(
      dim(`creditId=${data.creditId} valid=${data.validDate} rate=${data.discountRate.toFixed(3)}`)
    );
  });

  // ── Step 6: Idempotency — retry same txHash ──
  await step("POST /v1/buy idempotent retry", async () => {
    const txHash = "0xe2e_idempotent_" + Date.now();

    // First call
    const res1 = await fetch(`${RELAY_URL}/v1/buy`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 1.0,
        purchaseType: "advance",
        txHash,
      }),
    });
    assert(res1.status === 201, `First call expected 201, got ${res1.status}`);
    const data1 = (await res1.json()) as any;
    assert(!data1.alreadyProcessed, "First call should NOT be alreadyProcessed");

    // Retry with same txHash
    const res2 = await fetch(`${RELAY_URL}/v1/buy`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 1.0,
        purchaseType: "advance",
        txHash,
      }),
    });
    assert(res2.status === 200, `Retry expected 200, got ${res2.status}`);
    const data2 = (await res2.json()) as any;
    assert(data2.alreadyProcessed === true, "Retry should be alreadyProcessed");
    assert(data2.creditId === data1.creditId, "Same creditId expected");
    console.log(dim(`creditId=${data2.creditId} alreadyProcessed=true`));
  });

  // ── Step 7: /v1/buy validation — missing auth ──
  await step("POST /v1/buy rejects without admin secret", async () => {
    const res = await fetch(`${RELAY_URL}/v1/buy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address: account.address, amountUsd: 1.0 }),
    });
    assert(res.status === 401, `Expected 401, got ${res.status}`);
  });

  // ── Step 8: Credit via admin/credit for today (for balance + chat tests) ──
  await step("POST /admin/credit $5 for today", async () => {
    const today = new Date().toISOString().slice(0, 10);
    const res = await fetch(`${RELAY_URL}/admin/credit`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 5.0,
        validDate: today,
        purchaseType: "advance",
        discountRate: 0.85,
        note: "e2e-test-today",
      }),
    });
    const body = await res.text();
    assert(res.ok, `HTTP ${res.status}: ${body}`);
    const data = JSON.parse(body) as any;
    assert(data.creditId > 0, `creditId should be > 0, got ${data.creditId}`);
    assert(data.alreadyProcessed === false, "Should not be already processed");
    assert(data.borrower !== undefined, "borrower should be present");
    console.log(dim(`creditId=${data.creditId} borrower.balance_usd=${data.borrower?.balance_usd}`));
  });

  // ── Step 9: Auth handshake ──
  await step("Auth handshake (sign + login)", async () => {
    // Get message to sign
    const msgRes = await fetch(
      `${RELAY_URL}/auth/message?address=${account.address}`
    );
    assert(msgRes.ok, `GET /auth/message: HTTP ${msgRes.status}`);
    const { message, timestamp } = (await msgRes.json()) as any;
    assert(!!message, "No message returned");

    // Sign it
    const signature = await account.signMessage({ message });

    // Login
    const loginRes = await fetch(`${RELAY_URL}/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        address: account.address,
        timestamp,
        signature,
      }),
    });
    assert(loginRes.ok, `POST /auth/login: HTTP ${loginRes.status}`);
    const loginData = (await loginRes.json()) as any;
    assert(!!loginData.sessionToken, "No session token returned");
    sessionToken = loginData.sessionToken;
  });

  // ── Step 10: Check balance (dated credits) ──
  await step("GET /v1/balance reflects today's credits", async () => {
    const res = await fetch(`${RELAY_URL}/v1/balance`, {
      headers: { Authorization: `Bearer ${sessionToken}` },
    });
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;

    // We credited $5 for today in step 8 (plus any sameday from step 5)
    assert(
      data.balanceUsd >= 5.0,
      `Today balance ${data.balanceUsd} < 5.00 (expected at least $5 from step 8)`
    );
    assert(Array.isArray(data.credits?.today), "credits.today should be an array");
    assert(data.credits.today.length > 0, "Should have at least 1 credit for today");
    console.log(
      dim(`Balance: $${data.balanceUsd.toFixed(4)} | Credits today: ${data.credits.today.length}`)
    );
  });

  // ── Step 11: Chat completion (live Venice call) ──
  let chargedUsd = 0;

  // Capture balance before chat call
  const balRes = await fetch(`${RELAY_URL}/v1/balance`, {
    headers: { Authorization: `Bearer ${sessionToken}` },
  });
  const balanceBefore = ((await balRes.json()) as any).balanceUsd as number;

  await step("Chat completion (Venice proxy)", async () => {
    const res = await fetch(`${RELAY_URL}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${sessionToken}`,
      },
      body: JSON.stringify({
        model: "llama-3.3-70b",
        messages: [{ role: "user", content: "Say hello in exactly 5 words." }],
        max_tokens: 50,
      }),
    });
    const chatBody = await res.text();
    assert(res.ok, `HTTP ${res.status}: ${chatBody}`);

    const data = JSON.parse(chatBody) as any;
    const content = data.choices?.[0]?.message?.content;
    assert(!!content, "No content in response");
    console.log(dim(`Response: "${content.slice(0, 80)}"`));

    // Check usage
    assert(data.usage?.prompt_tokens > 0, "No prompt tokens");
    assert(data.usage?.completion_tokens > 0, "No completion tokens");
    console.log(
      dim(
        `Tokens: ${data.usage.prompt_tokens} in / ${data.usage.completion_tokens} out`
      )
    );

    // Check metering headers
    chargedUsd = parseFloat(res.headers.get("x-diem-charged-usd") ?? "0");
    const balanceAfter = parseFloat(res.headers.get("x-diem-balance-usd") ?? "0");
    const protocolFee = parseFloat(
      res.headers.get("x-diem-protocol-fee") ?? "0"
    );

    assert(chargedUsd > 0, `x-diem-charged-usd = ${chargedUsd}`);
    assert(balanceAfter < balanceBefore, `Balance not deducted: before=${balanceBefore} after=${balanceAfter}`);
    console.log(
      dim(
        `Charged: $${chargedUsd.toFixed(6)} | Balance: $${balanceAfter.toFixed(4)} | Fee: $${protocolFee.toFixed(6)}`
      )
    );
  });

  // ── Step 12: Verify usage via admin API ──
  await step("Verify usage + credits via admin API", async () => {
    const res = await fetch(
      `${RELAY_URL}/admin/borrowers/${account.address}`,
      { headers: { "X-Admin-Secret": ADMIN_SECRET } }
    );
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(
      data.usage?.requests >= 1,
      `Expected >= 1 requests, got ${data.usage?.requests}`
    );
    assert(
      data.borrower?.total_spent > 0,
      `total_spent = ${data.borrower?.total_spent}`
    );
    // Verify credits array is present (v0.2.0 response)
    assert(Array.isArray(data.credits), "credits array should be present");
    assert(data.credits.length > 0, "Should have credit records");
    console.log(
      dim(
        `Requests: ${data.usage.requests} | Total spent: $${data.borrower.total_spent.toFixed(4)} | Credits: ${data.credits.length}`
      )
    );
  });

  // ── Step 13: Admin sweep (expired credits) ──
  await step("POST /admin/sweep runs without error", async () => {
    const res = await fetch(`${RELAY_URL}/admin/sweep`, {
      method: "POST",
      headers: adminHeaders,
    });
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(typeof data.count === "number", "count should be a number");
    assert(typeof data.totalUsd === "number", "totalUsd should be a number");
    console.log(dim(`Swept: ${data.count} credits ($${data.totalUsd.toFixed(2)})`));
  });

  // ── Summary ──
  console.log();
  if (failed === 0) {
    console.log(
      `  \x1b[32m${passed}/${passed} steps passed \u2014 E2E TEST PASSED\x1b[0m\n`
    );
  } else {
    console.log(
      `  \x1b[31m${passed}/${passed + failed} steps passed \u2014 E2E TEST FAILED\x1b[0m\n`
    );
    process.exit(1);
  }
}

main().catch((e) => {
  console.log(`\n  \x1b[31mE2E TEST FAILED\x1b[0m\n`);
  process.exit(1);
});
