/**
 * DIEM daily keeper — csDIEM.harvest() + RevenueSplitter.distribute() (single-shot)
 *
 * Runs once per day under cron. Two independent steps in fixed order:
 *
 *   1. csDIEM.harvest()
 *        Claims the previous day's accrued USDC reward stream from sDIEM,
 *        swaps USDC → DIEM via Slipstream CL (TWAP-protected), restakes the
 *        DIEM into sDIEM. csDIEM share price ticks up; holders compound in DIEM.
 *
 *   2. RevenueSplitter.distribute()
 *        Splits the splitter's USDC balance 20% → platform Safe and
 *        80% → sDIEM.notifyRewardAmount(), starting a fresh 24h reward stream.
 *
 * Order rationale: by the time the keeper fires (24h+ after the last distribute),
 * the previous reward stream is fully accrued in sDIEM. Harvesting first lets
 * csDIEM claim a clean, fully-streamed batch; then distribute() starts the next
 * cycle. Each step is wrapped in try/catch so a swap-side failure on harvest
 * (slippage, oracle, liquidity) does NOT block the platform-fee distribute.
 *
 * Exit code: 0 on success or "nothing to do". Non-zero only on hard config
 * errors (missing RPC_URL / KEEPER_KEY). Step-level failures are surfaced via
 * healthcheck pings and stderr but do not fail the script.
 *
 * Env:
 *   RPC_URL          - Base JSON-RPC URL (required)
 *   KEEPER_KEY       - Hot-wallet private key, gas-only (required)
 *   SPLITTER_ADDRESS - RevenueSplitter (default: 0xd185138CEA135E60CA6E567BE53DEC81D89Ce7D6)
 *   CSDIEM_ADDRESS   - csDIEM vault. If unset, harvest step is skipped silently.
 *   USDC_ADDRESS     - USDC token (default: Base USDC)
 *   MAX_BASEFEE_GWEI - Skip both steps if Base base fee > this (default: 5)
 *   DRY_RUN          - "1" to simulate only (no tx sent)
 *   HEALTHCHECK_URL  - Optional base URL for healthchecks.io-style pings.
 *                      Suffixes used:
 *                        ""               on full success
 *                        "/0"             on no-op (preflight skip)
 *                        "/harvest-fail"  on harvest revert
 *                        "/distribute-fail" on distribute revert
 *                        "/fail"          on unexpected error
 *
 * Usage: bun run src/keeper-distribute.ts
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  formatUnits,
  formatGwei,
  type Address,
} from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// ── Config ──────────────────────────────────────────────────────────────

const RPC_URL = process.env.RPC_URL ?? "";
const KEEPER_KEY = process.env.KEEPER_KEY ?? "";
const SPLITTER_ADDRESS = (process.env.SPLITTER_ADDRESS ??
  "0xd185138CEA135E60CA6E567BE53DEC81D89Ce7D6") as Address;
const CSDIEM_ADDRESS = (process.env.CSDIEM_ADDRESS ?? "") as Address | "";
const USDC_ADDRESS = (process.env.USDC_ADDRESS ??
  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913") as Address;
const MAX_BASEFEE_GWEI = Number(process.env.MAX_BASEFEE_GWEI ?? "5");
const DRY_RUN = process.env.DRY_RUN === "1";
const HEALTHCHECK_URL = process.env.HEALTHCHECK_URL;

if (!RPC_URL) die("RPC_URL is required");
if (!KEEPER_KEY) die("KEEPER_KEY is required");

// ── Clients (module-scope) ──────────────────────────────────────────────

const account = privateKeyToAccount(KEEPER_KEY as `0x${string}`);
const pub = createPublicClient({ chain: base, transport: http(RPC_URL) });
const wallet = createWalletClient({ account, chain: base, transport: http(RPC_URL) });

// ── ABIs ────────────────────────────────────────────────────────────────

const SPLITTER_ABI = [
  { name: "distribute", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "minAmount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "cooldown", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "lastDistribution", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "paused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

const CSDIEM_ABI = [
  { name: "harvest", type: "function", stateMutability: "nonpayable", inputs: [{ name: "deadline", type: "uint256" }], outputs: [] },
  { name: "pendingHarvest", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "minHarvest", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "paused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

// Mempool-delay protection window for harvest swap. Computed at submission
// time (Date.now), not at execution time — that's the whole point.
const HARVEST_DEADLINE_SECS = 300;

const ERC20_ABI = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

// ── Helpers ─────────────────────────────────────────────────────────────

function ts(): string {
  return new Date().toISOString();
}

function log(msg: string): void {
  console.log(`[${ts()}] ${msg}`);
}

function logErr(msg: string): void {
  // Prefix with "ERROR:" so health-check.sh's tail-grep
  // (FATAL:|ERROR:) catches any per-step failure for both
  // harvest and distribute, surfacing them via Telegram.
  console.error(`[${ts()}] ERROR: ${msg}`);
}

function die(msg: string): never {
  console.error(`[${ts()}] FATAL: ${msg}`);
  process.exit(1);
}

async function pingHealthcheck(suffix = ""): Promise<void> {
  if (!HEALTHCHECK_URL) return;
  try {
    await fetch(`${HEALTHCHECK_URL}${suffix}`, { method: "GET" });
  } catch {
    // swallow — healthcheck is best-effort
  }
}

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

// ── Step 1: csDIEM.harvest() ────────────────────────────────────────────

type HarvestState = {
  pending: bigint;
  minHarvest: bigint;
  paused: boolean;
};

async function readHarvestState(csdiem: Address): Promise<HarvestState> {
  const [pending, minHarvest, paused] = await Promise.all([
    pub.readContract({ address: csdiem, abi: CSDIEM_ABI, functionName: "pendingHarvest" }),
    pub.readContract({ address: csdiem, abi: CSDIEM_ABI, functionName: "minHarvest" }),
    pub.readContract({ address: csdiem, abi: CSDIEM_ABI, functionName: "paused" }),
  ]);
  return { pending, minHarvest, paused };
}

/**
 * Returns true on tx success, false on skip or non-fatal failure.
 * Pings /harvest-fail on revert. Never throws.
 */
async function runHarvest(): Promise<boolean> {
  if (!CSDIEM_ADDRESS) {
    log("harvest: CSDIEM_ADDRESS unset — skipping");
    return false;
  }

  let state: HarvestState;
  try {
    state = await readHarvestState(CSDIEM_ADDRESS);
  } catch (e) {
    logErr(`harvest: state read failed: ${errMsg(e)}`);
    await pingHealthcheck("/harvest-fail");
    return false;
  }

  log(
    `harvest state: pending=${formatUnits(state.pending, 6)} USDC ` +
      `min=${formatUnits(state.minHarvest, 6)} paused=${state.paused}`,
  );

  if (state.paused) {
    log("harvest skip: csDIEM paused");
    return false;
  }
  if (state.pending < state.minHarvest) {
    log(
      `harvest skip: pending ${formatUnits(state.pending, 6)} ` +
        `< minHarvest ${formatUnits(state.minHarvest, 6)}`,
    );
    return false;
  }

  // Compute deadline at submission time so it provides real mempool-delay
  // protection — passing block.timestamp+N from on-chain would be useless.
  const deadline = BigInt(Math.floor(Date.now() / 1000) + HARVEST_DEADLINE_SECS);

  if (DRY_RUN) {
    log(`harvest dry-run: would call csDIEM.harvest(deadline=${deadline})`);
    return true;
  }

  try {
    await pub.simulateContract({
      account,
      address: CSDIEM_ADDRESS as Address,
      abi: CSDIEM_ABI,
      functionName: "harvest",
      args: [deadline],
    });

    const hash = await wallet.writeContract({
      address: CSDIEM_ADDRESS as Address,
      abi: CSDIEM_ABI,
      functionName: "harvest",
      args: [deadline],
    });
    log(`harvest tx sent: ${hash} deadline=${deadline}`);

    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 90_000 });
    if (receipt.status !== "success") {
      logErr(`harvest tx reverted: ${hash}`);
      await pingHealthcheck("/harvest-fail");
      return false;
    }
    log(`harvest confirmed block=${receipt.blockNumber} gas_used=${receipt.gasUsed}`);
    return true;
  } catch (e) {
    logErr(`harvest failed: ${errMsg(e)}`);
    await pingHealthcheck("/harvest-fail");
    return false;
  }
}

// ── Step 2: RevenueSplitter.distribute() ────────────────────────────────

type DistributeState = {
  balUsdc: bigint;
  minAmount: bigint;
  cooldown: bigint;
  lastDistribution: bigint;
  paused: boolean;
};

async function readDistributeState(): Promise<DistributeState> {
  const [balUsdc, minAmount, cooldown, lastDistribution, paused] = await Promise.all([
    pub.readContract({ address: USDC_ADDRESS, abi: ERC20_ABI, functionName: "balanceOf", args: [SPLITTER_ADDRESS] }),
    pub.readContract({ address: SPLITTER_ADDRESS, abi: SPLITTER_ABI, functionName: "minAmount" }),
    pub.readContract({ address: SPLITTER_ADDRESS, abi: SPLITTER_ABI, functionName: "cooldown" }),
    pub.readContract({ address: SPLITTER_ADDRESS, abi: SPLITTER_ABI, functionName: "lastDistribution" }),
    pub.readContract({ address: SPLITTER_ADDRESS, abi: SPLITTER_ABI, functionName: "paused" }),
  ]);
  return { balUsdc, minAmount, cooldown, lastDistribution, paused };
}

/**
 * Returns true on tx success, false on skip or non-fatal failure.
 * Pings /distribute-fail on revert. Never throws.
 */
async function runDistribute(): Promise<boolean> {
  let state: DistributeState;
  try {
    state = await readDistributeState();
  } catch (e) {
    logErr(`distribute: state read failed: ${errMsg(e)}`);
    await pingHealthcheck("/distribute-fail");
    return false;
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const cooldownEnd = state.lastDistribution + state.cooldown;
  const secsUntilReady = cooldownEnd > now ? Number(cooldownEnd - now) : 0;

  log(
    `distribute state: bal=${formatUnits(state.balUsdc, 6)} USDC ` +
      `min=${formatUnits(state.minAmount, 6)} ` +
      `cooldown_left=${secsUntilReady}s paused=${state.paused}`,
  );

  if (state.paused) {
    log("distribute skip: splitter paused");
    return false;
  }
  if (state.balUsdc < state.minAmount) {
    log(
      `distribute skip: balance ${formatUnits(state.balUsdc, 6)} ` +
        `< minAmount ${formatUnits(state.minAmount, 6)}`,
    );
    return false;
  }
  if (now < cooldownEnd) {
    log(`distribute skip: cooldown not elapsed (${secsUntilReady}s remaining)`);
    return false;
  }

  if (DRY_RUN) {
    log("distribute dry-run: would call distribute()");
    return true;
  }

  try {
    await pub.simulateContract({
      account,
      address: SPLITTER_ADDRESS,
      abi: SPLITTER_ABI,
      functionName: "distribute",
    });

    const hash = await wallet.writeContract({
      address: SPLITTER_ADDRESS,
      abi: SPLITTER_ABI,
      functionName: "distribute",
    });
    log(`distribute tx sent: ${hash}`);

    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 90_000 });
    if (receipt.status !== "success") {
      logErr(`distribute tx reverted: ${hash}`);
      await pingHealthcheck("/distribute-fail");
      return false;
    }
    log(`distribute confirmed block=${receipt.blockNumber} gas_used=${receipt.gasUsed}`);
    return true;
  } catch (e) {
    logErr(`distribute failed: ${errMsg(e)}`);
    await pingHealthcheck("/distribute-fail");
    return false;
  }
}

// ── Main ────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log(
    `keeper=${account.address} splitter=${SPLITTER_ADDRESS} ` +
      `csdiem=${CSDIEM_ADDRESS || "<unset>"} dry_run=${DRY_RUN}`,
  );

  // Global preflight: gas price and keeper balance.
  const [block, ethBal] = await Promise.all([pub.getBlock(), pub.getBalance({ address: account.address })]);
  const baseFeeGwei = block.baseFeePerGas ? Number(formatGwei(block.baseFeePerGas)) : 0;
  log(`gas: basefee=${baseFeeGwei.toFixed(3)}gwei keeper_eth=${formatUnits(ethBal, 18)}`);

  if (baseFeeGwei > MAX_BASEFEE_GWEI) {
    log(`skip ALL: base fee ${baseFeeGwei.toFixed(3)} gwei > cap ${MAX_BASEFEE_GWEI}`);
    await pingHealthcheck("/0");
    return;
  }

  // Step 1: harvest first — claim previous 24h's accrued USDC, swap, restake.
  const harvestOk = await runHarvest();

  // Step 2: distribute second — push the next 24h batch into sDIEM.
  // Runs regardless of harvest outcome (independent skip + try/catch isolation).
  const distributeOk = await runDistribute();

  if (!harvestOk && !distributeOk) {
    log("done: both steps no-op or skipped");
    await pingHealthcheck("/0");
  } else {
    log(`done: harvest=${harvestOk ? "ok" : "skip/fail"} distribute=${distributeOk ? "ok" : "skip/fail"}`);
    await pingHealthcheck();
  }
}

main().catch(async (e: unknown) => {
  const msg = errMsg(e);
  console.error(`[${ts()}] ERROR: ${msg}`);
  if (HEALTHCHECK_URL) {
    try {
      await fetch(`${HEALTHCHECK_URL}/fail`, {
        method: "POST",
        body: msg.slice(0, 500),
      });
    } catch {
      // ignore
    }
  }
  process.exit(1);
});
