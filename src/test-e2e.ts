/**
 * End-to-end test for the DIEM Relay pipeline.
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

const green = (s: string) => `\x1b[32m✓ ${s}\x1b[0m`;
const red = (s: string) => `\x1b[31m✗ ${s}\x1b[0m`;
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

async function main() {
  console.log("\n  DIEM Relay — End-to-End Test\n");
  console.log(dim(`Relay:   ${RELAY_URL}`));
  console.log(dim(`Address: ${account.address}`));
  console.log();

  if (!ADMIN_SECRET) {
    console.log(red("ADMIN_SECRET env var is required"));
    process.exit(1);
  }

  const adminHeaders = {
    "Content-Type": "application/json",
    "X-Admin-Secret": ADMIN_SECRET,
  };

  let sessionToken = "";

  // ── Step 1: Health check ──
  await step("Health check", async () => {
    const res = await fetch(`${RELAY_URL}/health`);
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(data.status === "ok", `Expected status "ok", got "${data.status}"`);
  });

  // ── Step 2: Create test borrower ──
  await step("Create test borrower", async () => {
    const res = await fetch(`${RELAY_URL}/admin/borrowers`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({ address: account.address, alias: "e2e-test" }),
    });
    assert(res.ok, `HTTP ${res.status}: ${await res.text()}`);
  });

  // ── Step 3: Credit $5 ──
  await step("Credit $5.00 to test borrower", async () => {
    const res = await fetch(`${RELAY_URL}/admin/credit`, {
      method: "POST",
      headers: adminHeaders,
      body: JSON.stringify({
        address: account.address,
        amountUsd: 5.0,
        note: "e2e-test",
      }),
    });
    assert(res.ok, `HTTP ${res.status}: ${await res.text()}`);
    const data = (await res.json()) as any;
    assert(data.balance_usd >= 5.0, `Balance ${data.balance_usd} < 5.00`);
  });

  // ── Step 4: Auth handshake ──
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

  // ── Step 5: Check balance ──
  await step("Check balance (≥ $5.00)", async () => {
    const res = await fetch(`${RELAY_URL}/v1/balance`, {
      headers: { Authorization: `Bearer ${sessionToken}` },
    });
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(
      data.balanceUsd >= 5.0,
      `Balance ${data.balanceUsd} < 5.00`
    );
    console.log(dim(`Balance: $${data.balanceUsd.toFixed(4)}`));
  });

  // ── Step 6: Chat completion (live Venice call) ──
  let chargedUsd = 0;
  let balanceAfter = 0;

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
    assert(res.ok, `HTTP ${res.status}: ${await res.text()}`);

    const data = (await res.json()) as any;
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
    balanceAfter = parseFloat(res.headers.get("x-diem-balance-usd") ?? "0");
    const protocolFee = parseFloat(
      res.headers.get("x-diem-protocol-fee") ?? "0"
    );

    assert(chargedUsd > 0, `x-diem-charged-usd = ${chargedUsd}`);
    assert(balanceAfter < 5.0, `Balance not deducted: ${balanceAfter}`);
    console.log(
      dim(
        `Charged: $${chargedUsd.toFixed(6)} | Balance: $${balanceAfter.toFixed(4)} | Fee: $${protocolFee.toFixed(6)}`
      )
    );
  });

  // ── Step 7: Verify via admin API ──
  await step("Verify usage via admin API", async () => {
    const res = await fetch(
      `${RELAY_URL}/admin/borrowers/${account.address}`,
      { headers: { "X-Admin-Secret": ADMIN_SECRET } }
    );
    assert(res.ok, `HTTP ${res.status}`);
    const data = (await res.json()) as any;
    assert(
      data.usage?.requests >= 1,
      `Expected ≥1 requests, got ${data.usage?.requests}`
    );
    assert(
      data.borrower?.total_spent > 0,
      `total_spent = ${data.borrower?.total_spent}`
    );
    console.log(
      dim(
        `Requests: ${data.usage.requests} | Total spent: $${data.borrower.total_spent.toFixed(4)}`
      )
    );
  });

  // ── Summary ──
  console.log();
  if (failed === 0) {
    console.log(`  \x1b[32m${passed}/${passed} steps passed — E2E TEST PASSED\x1b[0m\n`);
  } else {
    console.log(`  \x1b[31m${passed}/${passed + failed} steps passed — E2E TEST FAILED\x1b[0m\n`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.log(`\n  \x1b[31mE2E TEST FAILED\x1b[0m\n`);
  process.exit(1);
});
