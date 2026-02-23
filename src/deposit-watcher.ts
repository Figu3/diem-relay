/**
 * DIEM Relay — Deposit Watcher
 *
 * Watches the DIEMVault contract for `Deposited` events and credits
 * the corresponding borrower's relay balance.
 *
 * Env:
 *   VAULT_ADDRESS  - DIEMVault contract address (required)
 *   RPC_URL        - Ethereum JSON-RPC URL (required)
 *   CHAIN_ID       - Chain ID (default 1)
 *   ADMIN_SECRET   - Relay admin secret for crediting
 *   RELAY_URL      - Relay base URL (default http://localhost:3100)
 *
 * Usage: bun run watcher
 */

import {
  createPublicClient,
  http,
  parseAbiItem,
  formatUnits,
  type Log,
  type PublicClient,
} from "viem";
import { mainnet } from "viem/chains";
import fs from "fs";
import path from "path";

// ── Config ──────────────────────────────────────────────────────────────

const VAULT_ADDRESS = process.env.VAULT_ADDRESS as `0x${string}` | undefined;
const RPC_URL = process.env.RPC_URL ?? "";
const CHAIN_ID = Number(process.env.CHAIN_ID ?? "1");
const ADMIN_SECRET = process.env.ADMIN_SECRET ?? "";
const RELAY_URL = process.env.RELAY_URL ?? "http://localhost:3100";

const USDC_DECIMALS = 6;
const POLL_INTERVAL_MS = 12_000; // ~1 block on mainnet
const STATE_FILE = path.join(import.meta.dir, "../data/watcher-state.json");

// ── Validation ──────────────────────────────────────────────────────────

if (!VAULT_ADDRESS) {
  console.error("Error: VAULT_ADDRESS env is required");
  process.exit(1);
}
if (!RPC_URL) {
  console.error("Error: RPC_URL env is required");
  process.exit(1);
}
if (!ADMIN_SECRET) {
  console.error("Error: ADMIN_SECRET env is required");
  process.exit(1);
}

// ── ABI ─────────────────────────────────────────────────────────────────

const DEPOSITED_EVENT = parseAbiItem(
  "event Deposited(address indexed borrower, uint256 amount, uint256 newBalance)"
);

// ── State persistence ───────────────────────────────────────────────────

interface WatcherState {
  lastProcessedBlock: number;
}

function loadState(): WatcherState {
  try {
    if (fs.existsSync(STATE_FILE)) {
      const raw = fs.readFileSync(STATE_FILE, "utf-8");
      return JSON.parse(raw) as WatcherState;
    }
  } catch {
    console.warn("Warning: Could not load watcher state, starting fresh");
  }
  return { lastProcessedBlock: 0 };
}

function saveState(state: WatcherState): void {
  const dir = path.dirname(STATE_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// ── Relay API helpers ───────────────────────────────────────────────────

const adminHeaders = {
  "Content-Type": "application/json",
  "X-Admin-Secret": ADMIN_SECRET,
};

async function ensureBorrower(address: string): Promise<void> {
  const res = await fetch(`${RELAY_URL}/admin/borrowers`, {
    method: "POST",
    headers: adminHeaders,
    body: JSON.stringify({ address }),
  });
  // 200 or 409 (already exists) are both fine
  if (!res.ok && res.status !== 409) {
    const text = await res.text();
    throw new Error(`Failed to ensure borrower ${address}: HTTP ${res.status} — ${text}`);
  }
}

async function creditBorrower(
  address: string,
  amountUsd: number,
  txHash: string
): Promise<{ alreadyProcessed: boolean }> {
  const res = await fetch(`${RELAY_URL}/admin/credit`, {
    method: "POST",
    headers: adminHeaders,
    body: JSON.stringify({
      address,
      amountUsd,
      txHash,
      note: `on-chain deposit (watcher)`,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to credit ${address}: HTTP ${res.status} — ${text}`);
  }

  // Check if the response indicates already processed (relay returns alreadyProcessed field)
  const data = (await res.json()) as any;
  return { alreadyProcessed: !!data.alreadyProcessed };
}

// ── Event processing ────────────────────────────────────────────────────

async function processDepositEvent(log: Log): Promise<void> {
  const txHash = log.transactionHash;
  if (!txHash) {
    console.warn("  Warning: log missing transactionHash, skipping");
    return;
  }

  // Decode event args
  // Deposited(address indexed borrower, uint256 amount, uint256 newBalance)
  const borrower = (log as any).args?.borrower as string | undefined;
  const amount = (log as any).args?.amount as bigint | undefined;

  if (!borrower || amount === undefined) {
    console.warn(`  Warning: could not decode event args for tx ${txHash}`);
    return;
  }

  // M-6: USDC=USD assumption — Phase 0 treats 1 USDC = $1.00 exactly.
  // If USDC depegs significantly, this over/under-credits borrowers.
  // Phase 1 should add a price feed (e.g., Chainlink USDC/USD) to convert accurately.
  const amountUsd = Number(formatUnits(amount, USDC_DECIMALS));

  console.log(`  Deposit: ${borrower} — $${amountUsd.toFixed(2)} (tx: ${txHash.slice(0, 18)}...)`);

  // Ensure borrower exists in relay
  await ensureBorrower(borrower);

  // Credit the relay balance
  const { alreadyProcessed } = await creditBorrower(borrower, amountUsd, txHash);
  if (alreadyProcessed) {
    console.log(`  ↳ Already processed, skipped`);
  } else {
    console.log(`  ↳ Credited $${amountUsd.toFixed(2)}`);
  }
}

// ── Main loop ───────────────────────────────────────────────────────────

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const bold = (s: string) => `\x1b[1m${s}\x1b[0m`;

async function main() {
  console.log(`\n  ${bold("DIEM Relay — Deposit Watcher")}`);
  console.log(dim(`  Vault:   ${VAULT_ADDRESS}`));
  console.log(dim(`  RPC:     ${RPC_URL.slice(0, 50)}...`));
  console.log(dim(`  Relay:   ${RELAY_URL}`));
  console.log(dim(`  Chain:   ${CHAIN_ID}`));

  // Create viem public client
  const client: PublicClient = createPublicClient({
    chain: CHAIN_ID === 1 ? mainnet : { id: CHAIN_ID, name: `Chain ${CHAIN_ID}`, nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } },
    transport: http(RPC_URL),
  }) as PublicClient;

  // Load last processed block
  const state = loadState();
  let fromBlock = state.lastProcessedBlock > 0 ? BigInt(state.lastProcessedBlock + 1) : undefined;

  if (fromBlock) {
    console.log(dim(`  Resuming from block ${fromBlock}\n`));
  } else {
    // Start from current block if no state
    const currentBlock = await client.getBlockNumber();
    fromBlock = currentBlock;
    console.log(dim(`  Starting from current block ${currentBlock}\n`));
  }

  console.log(dim(`  Watching for Deposited events...\n`));

  // H-4: Catch up on missed events BEFORE starting real-time watcher
  // to prevent race where real-time events arrive while catch-up is in progress,
  // potentially causing duplicate processing or block-tracking gaps.
  let watchFromBlock = fromBlock;

  if (state.lastProcessedBlock > 0) {
    const currentBlock = await client.getBlockNumber();
    const gapStart = BigInt(state.lastProcessedBlock + 1);

    if (gapStart <= currentBlock) {
      console.log(dim(`  Catching up: blocks ${gapStart} → ${currentBlock}`));

      const logs = await client.getContractEvents({
        address: VAULT_ADDRESS,
        abi: [DEPOSITED_EVENT],
        eventName: "Deposited",
        fromBlock: gapStart,
        toBlock: currentBlock,
      });

      console.log(dim(`  Found ${logs.length} events to catch up on`));

      for (const log of logs) {
        try {
          await processDepositEvent(log as unknown as Log);
          const blockNumber = Number(log.blockNumber);
          if (blockNumber > state.lastProcessedBlock) {
            state.lastProcessedBlock = blockNumber;
            saveState(state);
          }
        } catch (err: any) {
          console.error(`  Catch-up error: ${err.message}`);
        }
      }

      console.log(dim(`  Catch-up complete\n`));
      // Start real-time watcher from the block AFTER catch-up finished
      watchFromBlock = currentBlock + 1n;
    }
  }

  // Now start real-time watcher — only processes blocks after catch-up range
  const unwatch = client.watchContractEvent({
    address: VAULT_ADDRESS,
    abi: [DEPOSITED_EVENT],
    eventName: "Deposited",
    onLogs: async (logs) => {
      for (const log of logs) {
        try {
          await processDepositEvent(log as Log);

          // Update state after each successfully processed event
          const blockNumber = Number(log.blockNumber);
          if (blockNumber > state.lastProcessedBlock) {
            state.lastProcessedBlock = blockNumber;
            saveState(state);
          }
        } catch (err: any) {
          console.error(`  Error processing event: ${err.message}`);
          // Don't update state — will retry on next poll
        }
      }
    },
    onError: (error) => {
      console.error(`  Watch error: ${error.message}`);
    },
    pollingInterval: POLL_INTERVAL_MS,
  });

  // Keep process alive
  console.log(dim("  Watcher running. Ctrl+C to stop.\n"));

  process.on("SIGINT", () => {
    console.log(dim("\n  Stopping watcher..."));
    unwatch();
    saveState(state);
    console.log(dim(`  State saved at block ${state.lastProcessedBlock}`));
    process.exit(0);
  });

  process.on("SIGTERM", () => {
    unwatch();
    saveState(state);
    process.exit(0);
  });
}

main().catch((e) => {
  console.error(`Fatal: ${e.message}`);
  process.exit(1);
});
