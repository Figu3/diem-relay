/**
 * DIEM Relay — Borrower CLI
 *
 * Usage:
 *   bun run borrower auth    --key 0x...              Get session token
 *   bun run borrower balance --key 0x...              Check balance
 *   bun run borrower chat    --key 0x... "message"    One-shot chat
 *   bun run borrower models  --key 0x...              List models
 *   bun run borrower repl    --key 0x...              Interactive REPL
 *
 * Options:
 *   --key <hex>     Private key for signing (or DIEM_PRIVATE_KEY env)
 *   --relay <url>   Relay URL (default http://localhost:3100)
 *   --model <name>  Model (default llama-3.3-70b)
 *   --session <tok> Reuse existing session token (skip auth)
 */

import { privateKeyToAccount } from "viem/accounts";
import type { PrivateKeyAccount } from "viem/accounts";

// ── Arg parsing ──

const args = process.argv.slice(2);
const command = args[0];

function getFlag(name: string): string | undefined {
  const idx = args.indexOf(`--${name}`);
  if (idx === -1) return undefined;
  return args[idx + 1];
}

const RELAY_URL = getFlag("relay") ?? process.env.DIEM_RELAY_URL ?? "http://localhost:3100";
const PRIVATE_KEY = getFlag("key") ?? process.env.DIEM_PRIVATE_KEY ?? "";
const MODEL = getFlag("model") ?? "llama-3.3-70b";
const EXISTING_SESSION = getFlag("session");

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const bold = (s: string) => `\x1b[1m${s}\x1b[0m`;
const cyan = (s: string) => `\x1b[36m${s}\x1b[0m`;
const yellow = (s: string) => `\x1b[33m${s}\x1b[0m`;

// ── Auth helper ──

interface Session {
  token: string;
  expiresAt: number;
  address: string;
}

async function authenticate(account: PrivateKeyAccount): Promise<Session> {
  const msgRes = await fetch(`${RELAY_URL}/auth/message?address=${account.address}`);
  if (!msgRes.ok) throw new Error(`Auth message failed: HTTP ${msgRes.status}`);
  const { message, timestamp } = (await msgRes.json()) as any;

  const signature = await account.signMessage({ message });

  const loginRes = await fetch(`${RELAY_URL}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: account.address, timestamp, signature }),
  });

  if (!loginRes.ok) {
    const err = (await loginRes.json()) as any;
    throw new Error(err.error ?? `Login failed: HTTP ${loginRes.status}`);
  }

  const { sessionToken, expiresAt } = (await loginRes.json()) as any;
  return { token: sessionToken, expiresAt, address: account.address };
}

// ── Chat helper ──

interface ChatResult {
  content: string;
  chargedUsd: number;
  balanceUsd: number;
  promptTokens: number;
  completionTokens: number;
}

async function sendChat(
  sessionToken: string,
  model: string,
  messages: Array<{ role: string; content: string }>
): Promise<ChatResult> {
  const res = await fetch(`${RELAY_URL}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${sessionToken}`,
    },
    body: JSON.stringify({ model, messages }),
  });

  if (res.status === 401) throw new Error("SESSION_EXPIRED");
  if (res.status === 402) {
    const data = (await res.json()) as any;
    throw new Error(`Insufficient balance: ${data.error ?? "no funds"}`);
  }
  if (!res.ok) throw new Error(`Chat failed: HTTP ${res.status}`);

  const data = (await res.json()) as any;
  return {
    content: data.choices?.[0]?.message?.content ?? "(empty response)",
    chargedUsd: parseFloat(res.headers.get("x-diem-charged-usd") ?? "0"),
    balanceUsd: parseFloat(res.headers.get("x-diem-balance-usd") ?? "0"),
    promptTokens: data.usage?.prompt_tokens ?? 0,
    completionTokens: data.usage?.completion_tokens ?? 0,
  };
}

// ── Session management ──

let _session: Session | null = null;
let _account: PrivateKeyAccount | null = null;

function getAccount(): PrivateKeyAccount {
  if (_account) return _account;
  if (!PRIVATE_KEY) {
    console.error("Error: --key <hex> or DIEM_PRIVATE_KEY env required");
    process.exit(1);
  }
  _account = privateKeyToAccount(PRIVATE_KEY as `0x${string}`);
  return _account;
}

async function getSession(): Promise<Session> {
  if (EXISTING_SESSION) {
    return { token: EXISTING_SESSION, expiresAt: 0, address: "unknown" };
  }
  if (_session && _session.expiresAt > Date.now() / 1000 + 60) {
    return _session;
  }
  const account = getAccount();
  process.stdout.write(dim("Authenticating... "));
  _session = await authenticate(account);
  console.log(dim("done"));
  return _session;
}

// ── Commands ──

async function cmdAuth() {
  const account = getAccount();
  const session = await authenticate(account);
  console.log(`\n  ${bold("Session Token")}`);
  console.log(`  ${session.token}`);
  console.log(dim(`  Expires: ${new Date(session.expiresAt * 1000).toLocaleString()}`));
  console.log(dim(`  Address: ${session.address}\n`));
}

async function cmdBalance() {
  const session = await getSession();
  const res = await fetch(`${RELAY_URL}/v1/balance`, {
    headers: { Authorization: `Bearer ${session.token}` },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = (await res.json()) as any;

  console.log(`\n  ${bold("DIEM Balance")}`);
  console.log(`  Address:     ${data.address}`);
  if (data.alias) console.log(`  Alias:       ${data.alias}`);
  console.log(`  Balance:     $${data.balanceUsd.toFixed(4)}`);
  console.log(`  Daily spent: $${data.dailySpent.toFixed(4)} / $${data.maxDailySpend.toFixed(2)}`);
  console.log(dim(`  Discount:    ${((1 - data.discountRate) * 100).toFixed(0)}% off Venice price\n`));
}

async function cmdChat() {
  // Collect message from remaining args (skip flags)
  const msgParts: string[] = [];
  let skip = false;
  for (let i = 1; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      skip = true;
      continue;
    }
    if (skip) {
      skip = false;
      continue;
    }
    msgParts.push(args[i]);
  }
  const userMessage = msgParts.join(" ");
  if (!userMessage) {
    console.error("Usage: bun run borrower chat --key 0x... \"your message\"");
    process.exit(1);
  }

  const session = await getSession();
  const result = await sendChat(session.token, MODEL, [
    { role: "user", content: userMessage },
  ]);

  console.log(`\n${result.content}`);
  console.log(
    dim(
      `\n  ${result.promptTokens} in / ${result.completionTokens} out | ` +
        `$${result.chargedUsd.toFixed(6)} charged | $${result.balanceUsd.toFixed(4)} remaining`
    )
  );
}

async function cmdModels() {
  const session = await getSession();
  const res = await fetch(`${RELAY_URL}/v1/models`, {
    headers: { Authorization: `Bearer ${session.token}` },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = (await res.json()) as any;

  console.log(`\n  ${bold("Available Models")}\n`);
  const models = data.data ?? data;
  if (Array.isArray(models)) {
    for (const m of models) {
      console.log(`  ${m.id ?? m}`);
    }
  } else {
    console.log(JSON.stringify(data, null, 2));
  }
  console.log();
}

async function cmdRepl() {
  const session = await getSession();
  const history: Array<{ role: string; content: string }> = [];
  let currentModel = MODEL;
  let totalCharged = 0;
  let totalRequests = 0;

  console.log(`\n  ${bold("DIEM Relay — Interactive Chat")}`);
  console.log(dim(`  Model:   ${currentModel}`));
  console.log(dim(`  Address: ${session.address}`));
  console.log(dim(`  Type /help for commands, /quit to exit\n`));

  const readline = require("readline");
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const prompt = () => {
    rl.question(cyan("you> "), async (line: string) => {
      if (!line) {
        prompt();
        return;
      }

      const trimmed = line.trim();

      // Handle slash commands
      if (trimmed === "/quit" || trimmed === "/exit") {
        console.log(
          dim(
            `\n  Session: ${totalRequests} requests | $${totalCharged.toFixed(4)} total charged\n`
          )
        );
        rl.close();
        return;
      }

      if (trimmed === "/clear") {
        history.length = 0;
        console.log(dim("  History cleared\n"));
        prompt();
        return;
      }

      if (trimmed === "/help") {
        console.log(dim("  /quit     Exit the REPL"));
        console.log(dim("  /clear    Clear conversation history"));
        console.log(dim("  /balance  Check current balance"));
        console.log(dim("  /model    Show or change model: /model <name>"));
        console.log(dim("  /history  Show conversation history"));
        console.log();
        prompt();
        return;
      }

      if (trimmed === "/balance") {
        try {
          const s = await getSession();
          const res = await fetch(`${RELAY_URL}/v1/balance`, {
            headers: { Authorization: `Bearer ${s.token}` },
          });
          const data = (await res.json()) as any;
          console.log(dim(`  Balance: $${data.balanceUsd.toFixed(4)}\n`));
        } catch (e: any) {
          console.log(dim(`  Error: ${e.message}\n`));
        }
        prompt();
        return;
      }

      if (trimmed.startsWith("/model")) {
        const newModel = trimmed.split(/\s+/)[1];
        if (newModel) {
          currentModel = newModel;
          console.log(dim(`  Model changed to: ${currentModel}\n`));
        } else {
          console.log(dim(`  Current model: ${currentModel}\n`));
        }
        prompt();
        return;
      }

      if (trimmed === "/history") {
        if (history.length === 0) {
          console.log(dim("  (empty)\n"));
        } else {
          for (const msg of history) {
            const tag = msg.role === "user" ? "you" : "ai ";
            console.log(dim(`  ${tag}: ${msg.content.slice(0, 100)}`));
          }
          console.log();
        }
        prompt();
        return;
      }

      // Send message
      history.push({ role: "user", content: trimmed });

      try {
        let s = await getSession();
        let result: ChatResult;

        try {
          result = await sendChat(s.token, currentModel, history);
        } catch (e: any) {
          if (e.message === "SESSION_EXPIRED") {
            console.log(dim("  Session expired, re-authenticating..."));
            _session = null;
            s = await getSession();
            result = await sendChat(s.token, currentModel, history);
          } else {
            throw e;
          }
        }

        history.push({ role: "assistant", content: result.content });
        totalCharged += result.chargedUsd;
        totalRequests++;

        console.log(`\n${result.content}`);
        console.log(
          dim(
            `  $${result.chargedUsd.toFixed(6)} | $${result.balanceUsd.toFixed(4)} remaining\n`
          )
        );
      } catch (e: any) {
        console.log(`\n  ${yellow("Error:")} ${e.message}\n`);
        history.pop();
      }

      prompt();
    });
  };

  prompt();
}

// ── Main ──

async function main() {
  switch (command) {
    case "auth":
      await cmdAuth();
      break;
    case "balance":
      await cmdBalance();
      break;
    case "chat":
      await cmdChat();
      break;
    case "models":
      await cmdModels();
      break;
    case "repl":
      await cmdRepl();
      break;
    default:
      console.log(`
  ${bold("DIEM Relay — Borrower CLI")}

  Usage: bun run borrower <command> --key 0x...

  Commands:
    auth      Get a session token
    balance   Check current balance
    chat      One-shot chat completion
    models    List available models
    repl      Interactive chat mode

  Options:
    --key <hex>     Private key (or DIEM_PRIVATE_KEY env)
    --relay <url>   Relay URL (default ${RELAY_URL})
    --model <name>  Model (default llama-3.3-70b)
    --session <tok> Reuse session token
`);
      if (command) {
        console.error(`  Unknown command: ${command}\n`);
        process.exit(1);
      }
  }
}

main().catch((e) => {
  console.error(`Error: ${e.message}`);
  process.exit(1);
});
