# DIEM Staking

Stake DIEM tokens to earn USDC yield from Venice AI compute revenue. All staked DIEM is forward-staked on Venice for compute credits, and revenue flows back to stakers as USDC. An optional auto-compounding wrapper (csDIEM) re-invests USDC rewards back into DIEM via on-chain swap.

Live at **[diem-relay.com](https://diem-relay.com)**. Deployed on **Base**. Built with Foundry (Solidity 0.8.24).

## Architecture

```
                     ┌──────────────────────────────┐
                     │      Venice AI Compute        │
                     └──────────────┬───────────────┘
                                    │ USDC revenue
                                    ▼
                     ┌──────────────────────────────┐
                     │       RevenueSplitter         │
                     │   Receives USDC from customers│
                     │     20% → platform Safe       │
                     │     80% → sDIEM stakers       │
                     │   Permissionless distribute() │
                     └──────┬─────────────────┬─────┘
                     20%    │             80% │ notifyRewardAmount()
                            ▼                 ▼
                     ┌──────────┐    ┌──────────────────┐    ┌────────────────────────┐
                     │ 2/2 Safe │    │      sDIEM       │←───│        csDIEM           │
                     │ (platform│    │ Synthetix fork   │    │ ERC-4626 wrapper        │
                     │  fees)   │    │ Earn USDC (24h)  │    │ harvest() compounds     │
                     └──────────┘    └──────────────────┘    │   USDC → DIEM via       │
                                                             │   Slipstream CL         │
                                                             └────────────────────────┘
```

### Contracts

| Contract | Description |
|---|---|
| **sDIEM** | Synthetix StakingRewards fork. Stake DIEM, earn USDC rewards streamed linearly over 24h. All staked DIEM is forward-staked on Venice for compute credits. 24h async withdrawals matching Venice's unstake cooldown. |
| **RevenueSplitter** | Receives USDC revenue from compute customers and splits it 20% to the platform 2/2 Safe and 80% to sDIEM stakers via `notifyRewardAmount`. Permissionless `distribute()` with a 23h cooldown and minimum-amount floor to prevent reward-stream fragmentation. |
| **csDIEM** | ERC-4626 auto-compounding wrapper over sDIEM. Deposit DIEM → csDIEM stakes it into sDIEM → permissionless `harvest()` claims accrued USDC, swaps to DIEM via Aerodrome Slipstream CL with TWAP-protected slippage, restakes. Yield compounds in DIEM rather than streaming as USDC. Standard ERC-4626 `withdraw`/`redeem` are disabled — exits use the async `requestRedeem` → 24h delay → `completeRedeem` flow. |
| **DIEMVault** | USDC deposit vault for the DIEM Relay service. Borrowers deposit USDC on-chain; an off-chain watcher credits relay accounts. Deposit-only (Phase 1). |

### Revenue Loop

```
Stake DIEM → sDIEM
         → forward-staked on Venice ($1/day compute per staked DIEM)
         → compute revenue lands on RevenueSplitter as USDC
         → distribute(): 20% → 2/2 Safe, 80% → sDIEM.notifyRewardAmount()
         → streamed to stakers over 24h

Optional: deposit DIEM into csDIEM instead
         → csDIEM forwards to sDIEM (same Venice forward-stake)
         → harvest(): claims USDC reward stream → swaps via Slipstream CL → re-stakes in sDIEM
         → csDIEM share price ticks up; holders compound in DIEM, not USDC
```

USDC revenue lands directly on the RevenueSplitter contract. Anyone can trigger `distribute()` once the balance exceeds the minimum floor and the 23h cooldown has elapsed. The splitter is the only authorized operator for `sDIEM.notifyRewardAmount()`. csDIEM consumes from sDIEM downstream and never calls `notifyRewardAmount()` itself.

### Venice Forward-Staking

All deposited DIEM is immediately forward-staked on Venice (the DIEM token contract has staking built in). No liquid buffer is held.

- **Permissionless management**: `claimFromVenice()` and `redeployExcess()` callable by anyone.
- **24h async withdrawals**: `requestWithdraw()` auto-initiates Venice unstake. After 24h, `completeWithdraw()` auto-claims from Venice. Users can `cancelWithdraw()` at any time.
- **Partial withdrawals**: `completeWithdraw()` supports partial payouts when only some Venice-unstaked DIEM is available, preventing one user's unfunded batch from blocking others. After partial completion, Venice unstake is auto-initiated for remaining amounts.
- **Batched unstaking**: Withdrawal requests that arrive during an active Venice cooldown are batched via `totalPendingNotInitiated`. When the cooldown matures and a user completes, the next batch is auto-initiated. Worst-case withdrawal time: ~48h (two Venice cooldowns).

### csDIEM Compounding

csDIEM is a thin ERC-4626 vault layered on sDIEM. It does not interact with Venice directly — sDIEM handles that. The only mechanically novel piece is `harvest()`:

- **Permissionless** (anyone can call). The keeper does it daily; users can also trigger ad-hoc.
- **Caller-supplied deadline**: `harvest(uint256 deadline)` — caller computes deadline at submission time. An internally-set deadline gives no mempool-delay protection (Pashov audit #1).
- **TWAP-protected swap**: USDC → DIEM via Aerodrome Slipstream `exactInputSingle`, with `amountOutMin` derived from a 1h TWAP and a max-slippage parameter (default 0.5%).
- **Mandatory absolute floor**: `minDiemPerUsdc` must be set before any harvest can run (Pashov audit #3); admin can tune via `setMinDiemPerUsdc`.
- **Min-harvest threshold**: 100 USDC default — keeper skips if accrued rewards are below this.
- **Async redemption**: `requestRedeem(shares)` burns shares, records owed DIEM, optionally initiates an sDIEM withdrawal. After 24h, `completeRedeem()` pays out (with partial-fill support). `cancelRedeem()` re-mints at current rate (anti-arbitrage).

## Project Structure

```
contracts/
  src/
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    RevenueSplitter.sol     20/80 USDC splitter: Safe + sDIEM
    csDIEM.sol              ERC-4626 auto-compounding wrapper over sDIEM
    DIEMVault.sol           USDC deposit vault for relay credits
    interfaces/
      IsDIEM.sol            sDIEM interface
      IRevenueSplitter.sol  RevenueSplitter interface
      IcsDIEM.sol           csDIEM interface
      IDIEMStaking.sol      DIEM token staking interface (Base)
      IDIEMVault.sol        DIEMVault interface
      ICLPool.sol           Aerodrome Slipstream pool (TWAP oracle source)
      ICLSwapRouter.sol     Aerodrome Slipstream swap router
    libraries/
      OracleLibrary.sol     TWAP price queries from CL pools
      TickMath.sol          sqrtPriceX96 ↔ tick conversion
      FullMath.sol          Uniswap-style mulDiv with 512-bit intermediates
  test/
    sDIEM.t.sol             67 unit/fuzz tests
    sDIEMInvariant.t.sol    7 invariant tests
    DIEMVault.t.sol         52 unit/fuzz tests
    DIEMVaultInvariant.t.sol 3 invariant tests
    RevenueSplitter.t.sol   20 unit/fuzz tests
    RevenueSplitterInvariant.t.sol  2 invariant tests
    RevenueSplitterFork.t.sol  1 Base-fork integration test
    csDIEM.t.sol            56 unit/fuzz tests
    csDIEMInvariant.t.sol   5 invariant tests
    mocks/                  MockDIEMStaking, MockSwapRouter, MockCLPool, MockERC20
  script/
    DeploySDiem.s.sol             sDIEM deployment
    DeployDIEMVault.s.sol         DIEMVault deployment
    DeployRevenueSplitter.s.sol   RevenueSplitter deployment
    DeployCSDiem.s.sol            csDIEM deployment (hardened: pre/post asserts,
                                  setMinDiemPerUsdc + transferAdmin in single broadcast)
src/                        Relay server (TypeScript / Bun / Hono)
  index.ts                  Hono server: /v1/buy, /v1/chat/completions, etc.
  deposit-watcher.ts        Picks up DIEMVault Deposited events → SQLite
  keeper-distribute.ts      Daily cron — runs csDIEM.harvest() then RevenueSplitter.distribute()
  admin.ts, borrower-cli.ts, ... Operator + user CLIs
scripts/
  health-check.sh           Daily Telegram alerter — flags missed cron, errored
                            runs (any "ERROR:" or "FATAL:" in latest run), and
                            mid-run kills (latest run never reached "done:")
app/                        Staking UI (Next.js 16 / wagmi / RainbowKit / Tailwind 4)
                            Live at https://diem-relay.com
```

## Build and Test

```bash
cd contracts
forge install
forge build
forge test            # 213 tests across 9 suites (unit, fuzz, invariant, fork)
```

## Deployment

All contracts are deployed on **Base** (chain ID 8453).

| Contract | Address |
|---|---|
| **DIEMVault** | `0xdc9625b026f6Dd17F9d96e608592A9C592e27eEF` |
| **sDIEM** | `0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2` |
| **RevenueSplitter** | `0xd185138CEA135E60CA6E567BE53DEC81D89Ce7D6` |
| **csDIEM** | `0x4899f5fBA1bf43C8Bea483bE6342e55Bc16e045a` |
| sDIEM (superseded) | `0x59650b79eF4c2eC193B49DbFc23d50d48EBf9f34` |
| sDIEM (superseded) | `0x9566a919c7A4a7b22243736f39781A2787ddC11e` |

All contracts are admin'd by the same 2/2 Safe `0x01Ea790410D9863A57771D992D2A72ea326DD7C9`.

Deploy scripts:

```bash
cd contracts

# sDIEM
OPERATOR=0x... forge script script/DeploySDiem.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# DIEMVault
forge script script/DeployDIEMVault.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# RevenueSplitter (addresses default to Base mainnet + 2/2 Safe)
forge script script/DeployRevenueSplitter.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# csDIEM (sets the mandatory minDiemPerUsdc floor and transfers admin
# to the Safe in the same broadcast — Safe must follow up with acceptAdmin)
SDIEM=0xdbF05... SWAP_ROUTER=0x... ORACLE_POOL=0x... TICK_SPACING=100 \
ADMIN=0x01Ea7904... MIN_DIEM_PER_USDC=<floor in DIEM-base-units-per-USDC> \
  forge script script/DeployCSDiem.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

After RevenueSplitter deployment, the sDIEM admin must call `sDIEM.setOperator(splitter)` so the splitter becomes the sole caller of `notifyRewardAmount`. After csDIEM deployment, the Safe must call `acceptAdmin()` on the csDIEM contract to complete the two-step admin transfer.

### Off-chain operations

A daily cron on the project's NUC runs `src/keeper-distribute.ts` at 00:05 UTC, which:

1. **`csDIEM.harvest(deadline)`** — claim previous 24h's USDC stream from sDIEM, swap via Slipstream CL, restake. Skipped silently if `pendingHarvest < minHarvest`.
2. **`RevenueSplitter.distribute()`** — split next 24h batch 20/80 into platform Safe + sDIEM rewards. Skipped silently if balance below `minAmount` or cooldown not elapsed.

Each step has independent skip conditions and try/catch isolation — a swap-side failure on harvest does NOT block the platform-fee distribute. A second cron at 06:00 UTC runs `scripts/health-check.sh`, which alerts via Telegram on missed runs (>36h log staleness), errored runs (any `ERROR:`/`FATAL:` in the latest run), or mid-run kills (latest run never reached `done:`).

## Security

**Access control**: Two-step admin transfer on sDIEM, RevenueSplitter, and csDIEM. Separate operator role on sDIEM for reward notification.

**Emergency pause**: Deposits, staking, and harvest are gated behind pause. Withdrawals/redemptions and reward claims always allowed, even when paused — users can always exit.

**Reentrancy**: ReentrancyGuard on all mutative functions across all contracts. CEI (Checks-Effects-Interactions) pattern throughout.

**Token safety**: SafeERC20 for all ERC-20 operations. Zero-address checks on all constructors and admin setters.

**Token recovery**: `recoverERC20()` on all contracts for accidentally sent tokens, with safeguards preventing recovery of core assets (DIEM, USDC).

**Venice cooldown handling**: Claim-first semantics in `initiateVeniceUnstake()` — claims matured cooldown before initiating new one, preventing cooldown reset DoS (Bretzel finding M-01).

**Venice unstake auto-initiation**: `completeWithdraw()` calls `_tryInitiateVeniceUnstake()` before the payout check, ensuring deferred Venice unstakes are kicked off even when `requestWithdraw()` couldn't initiate them (Bretzel M-02 fix).

**Partial withdrawal support**: `completeWithdraw()` pays out available liquid DIEM rather than reverting when full amount isn't funded. Auto-initiates next Venice unstake batch after partial completion.

**csDIEM swap protection**: Caller-supplied harvest deadline (Pashov #1), mandatory absolute price floor `minDiemPerUsdc` (Pashov #3), `uint128` bounds check on TWAP query (Pashov #4), 30-minute minimum TWAP window, max-slippage cap of 10%.

**Reward dust**: `notifyRewardAmount()` returns integer division rounding dust to caller instead of stranding it in the contract (Bretzel L-01).

### Audit

| Audit | Scope | Result |
|---|---|---|
| Bretzel (March 2026) | sDIEM, DIEMVault | 0 Critical, 0 High, 1 Medium, 1 Low, 4 Informational. All findings remediated. |
| Pashov AI deep pass (March 2026) | sDIEM, DIEMVault | 2 additional findings, both remediated. |
| Internal Pashov (April 2026) | RevenueSplitter | Reviewed with same Pashov AI tooling, pending external pass. |
| Internal Pashov (April 2026) | csDIEM | 4 findings (1 high, 1 medium, 1 low, 1 below-threshold). Findings #1, #3, #4 applied. Finding #2 (timer-reset grief on `syncWithdrawals`) accepted as bounded by the existing `if (sdiemPending > 0) return;` guard. |

See `contracts/AUDIT.md` and `contracts/KNOWN_ISSUES.md`.

### Test Coverage

213 tests across 9 suites: unit, fuzz, invariant, and Base-fork integration tests. Key invariants verified:
- Sum of staker balances equals `totalStaked` (sDIEM)
- Sum of borrower balances equals `totalDeposits` (DIEMVault)
- Share price never decreases (sDIEM, csDIEM — absent slashing)
- csDIEM `totalAssets` accounts for all DIEM (sdiemBalance + sdiemPending + liquid − pendingRedemptions)
- RevenueSplitter conserves USDC (in == 20% Safe + 80% sDIEM, no dust stranded)
