# DIEM Staking Protocol — Auditor Briefing

> Target: 4 Solidity 0.8.24 contracts (~1,524 LOC total) + Slipstream interfaces & libraries
> Chain: Base
> Dependencies: OpenZeppelin 5.x, Venice DIEM staking, Aerodrome Slipstream (CL pool + SwapRouter)
>
> **Note on scope**: The previous Bretzel + Pashov AI audits (March 2026) covered sDIEM and DIEMVault. RevenueSplitter (April 2026) was reviewed internally with the same Pashov AI tooling, pending an external pass. csDIEM (April 2026) was reviewed with the Pashov AI tooling — 4 findings, 3 applied; finding #2 (timer-reset grief on `syncWithdrawals`) accepted as bounded by the existing in-tree guard.

---

## 1. System Architecture

```
                         ┌──────────────────────────┐
                         │     Venice Protocol       │
                         │  (DIEM staking for AI     │
                         │   compute credits)        │
                         └──────┬───────────┬────────┘
                           stake│  unstake  │initiateUnstake
                                │(24h cool) │
                         ┌──────┴───────────┴──────┐
                         │           sDIEM          │
                         │   Stake DIEM, earn USDC  │
                         │        (linear 24h)      │
                         └────────────┬─────────────┘
                                      │ notifyRewardAmount()
                                      │ (USDC transfer from operator)
                                      │
    ┌───────────────────────┐         │
    │   RevenueSplitter     │─────────┘
    │                       │  Receives USDC from compute customers.
    │   20% → 2/2 Safe      │  Anyone calls distribute() → 20% to platform Safe,
    │   80% → sDIEM         │  80% to sDIEM via notifyRewardAmount() (24h stream).
    │   (permissionless)    │  23h cooldown + minAmount floor prevent stream
    └───────────────────────┘  fragmentation. Splitter is sDIEM's Operator.

                                      ┌──────────────────────────┐
                                      │          csDIEM           │
                                      │ ERC-4626 wrapper. Stakes  │
                                      │ DIEM into sDIEM, harvests │
                                      │ accrued USDC, swaps via   │
                                      │ Aerodrome Slipstream CL,  │
                                      │ restakes. Yield in DIEM.  │
                                      └──┬──────────────────────┬─┘
                                  stake/ │                      │ swap USDC→DIEM
                                  redeem │                      │ (Slipstream
                                         ▼                      ▼  exactInputSingle)
                                  (sDIEM, above)        (DIEM/USDC CL pool)

    ┌───────────────┐
    │  DIEMVault    │  (Standalone — no interaction with staking contracts)
    │               │
    │  USDC deposit │  Off-chain watcher picks up Deposited events
    │  Phase 1 only │  and credits relay accounts.
    └───────────────┘
```

## 2. Contracts in Scope

| Contract | LOC | Base | Key Patterns |
|----------|-----|------|-------------|
| `sDIEM.sol` | 631 | ReentrancyGuard | Synthetix StakingRewards fork, Venice forward-staking, batched async withdrawals |
| `DIEMVault.sol` | 176 | ReentrancyGuard | Deposit-only, reserve segregation |
| `RevenueSplitter.sol` | 161 | ReentrancyGuard | Permissionless 20/80 splitter, immutable USDC + sDIEM, non-rug USDC rescue, 2-step admin |
| `csDIEM.sol` | 556 | OZ ERC4626 + ReentrancyGuard | Auto-compounding wrapper over sDIEM. Standard withdraw/redeem disabled (revert in `_withdraw`); exits via async `requestRedeem → 24h → completeRedeem`. Permissionless `harvest(deadline)` claims sDIEM rewards, swaps USDC→DIEM via Slipstream `exactInputSingle` with TWAP-protected slippage + mandatory absolute floor + 1e6 virtual-shares offset. |

## 3. Trust Assumptions

### External Protocols

| Dependency | Trust Level | What We Trust |
|------------|-------------|---------------|
| **Venice DIEM staking** | High | `stake()`, `initiateUnstake()`, `unstake()` behave correctly. 24h cooldown is honored. `stakedInfos()` returns accurate balances. DIEM is returned after cooldown. |
| **DIEM token** | High | Standard ERC-20. Has built-in staking (`IDIEMStaking` interface on the same contract). `mint()` callable by Venice staking infra (not by our contracts). |
| **USDC** | High | Standard ERC-20. 6 decimals. No fee-on-transfer. No rebasing. |
| **OpenZeppelin 5.x** | High | SafeERC20, ReentrancyGuard, ERC4626 (csDIEM base) are correct. |
| **Aerodrome Slipstream `SwapRouter`** (csDIEM only) | Medium | `exactInputSingle()` honors `amountOutMinimum` + `deadline`, transfers `tokenOut` to `recipient`, never moves more `tokenIn` than `amountIn`. Verified to point at the canonical Slipstream factory before deploy. |
| **DIEM/USDC Slipstream CL pool** (csDIEM only) | Medium | Pool tokens are exactly {DIEM, USDC} and `tickSpacing()` matches the deploy parameter (asserted at deploy). `OracleLibrary.consult()` returns a manipulation-resistant TWAP over the configured window (≥30 min minimum, 1h default). Pool may have low liquidity in early periods — partially mitigated by `minDiemPerUsdc` absolute floor and `maxSlippageBps` relative cap. |

### Admin Trust

The **admin** role can:
- Pause/unpause all state-changing functions
- Adjust parameters (min amounts, cooldown)
- Recover non-core tokens (cannot recover DIEM from sDIEM)
- Transfer admin via two-step process (except DIEMVault which is single-step)

The admin **cannot**:
- Access staker funds (DIEM in sDIEM)
- Access user deposits (USDC in DIEMVault, only `protocolFees`)
- Bypass withdrawal delays
- Mint shares/tokens
- Change immutable addresses (DIEM, USDC, sDIEM references)

### Operator Trust (sDIEM only)

The operator is the deployed `RevenueSplitter` contract. As such:

The operator can:
- Call `notifyRewardAmount()` to seed USDC reward periods (only via `distribute()`)

The operator **cannot** (enforced by RevenueSplitter code):
- Arbitrarily choose amounts — `distribute()` always sends the full current USDC balance
- Redirect the staker share — `notifyRewardAmount` is the only sink
- Change sDIEM parameters, pause sDIEM, or recover tokens

The sDIEM admin (2/2 Safe) can rotate the operator via `setOperator()` if the RevenueSplitter needs to be replaced.

### RevenueSplitter Trust

The RevenueSplitter admin (2/2 Safe — same as sDIEM admin) can:
- Rotate `platformReceiver` (e.g., if Circle blacklists the Safe)
- Adjust `minAmount` (floor capped at 10,000 USDC, must be > 0)
- Adjust `cooldown` (capped at 7 days)
- Pause/unpause the `distribute()` function
- Rescue non-USDC tokens accidentally sent to the contract

The admin **cannot**:
- Rescue USDC — blocked by `require(token != address(USDC))` in `rescueToken()`
- Change the 20/80 split — ratios are constants (redeploy required to change)
- Bypass `distribute()` to access customer USDC directly

### csDIEM Trust

The csDIEM admin (2/2 Safe — same as sDIEM and RevenueSplitter admin) can:
- Rotate `swapRouter` (if Aerodrome Slipstream redeploys)
- Rotate `oraclePool` (if a more liquid CL pool emerges)
- Adjust `maxSlippageBps` (capped at 1000 = 10%), `twapWindow` (≥1800s), `tickSpacing`
- Adjust `minDiemPerUsdc` (must be > 0; mandatory floor — prevents catastrophic mispricing)
- Adjust `minHarvest` (gas-profitability floor, no upper bound but uneconomic if too low)
- Pause/unpause deposits + harvest. Redemptions always allowed (paused or not).
- Two-step admin transfer
- Rescue non-DIEM, non-USDC tokens

The admin **cannot**:
- Access staker funds — DIEM is held in sDIEM, not csDIEM directly
- Steal harvest output — `harvest()` always restakes back into sDIEM, no admin sink
- Rescue DIEM (the underlying) or USDC (harvest intermediate)
- Bypass the 24h redemption delay
- Change the share-price exchange rate directly (it's derived from `totalAssets / totalSupply`)

## 4. Contract Interaction Flows

### 4.1 Staking (sDIEM)

```
User                    sDIEM                   Venice (IDIEMStaking)
  │                       │                            │
  │── stake(amount) ─────→│                            │
  │                       │── transferFrom(user) ──────│
  │                       │── diemStaking.stake() ────→│  forward to Venice
  │                       │                            │
  │── requestWithdraw() ─→│                            │
  │                       │── initiateUnstake() ──────→│  starts 24h cooldown
  │                       │                            │
  │        ... 24h ...    │                            │
  │                       │                            │
  │── completeWithdraw() →│── diemStaking.unstake() ──→│  auto-claims from Venice
  │                       │── transfer(user, amount) ──│
```

### 4.2 Revenue Seeding (automated via RevenueSplitter)

```
Customer                RevenueSplitter            sDIEM
  │                         │                       │
  │── USDC.transfer() ─────→│                       │
  │         (checkout)      │                       │
                            │                       │
  Anyone calls distribute():│                       │
  ─────────────────────────→│                       │
                            │── USDC.transfer() ───→ 2/2 Safe   (20%)
                            │── forceApprove(sDIEM) │
                            │── notifyRewardAmount()→│          (80%)
                            │                       │  pulls USDC, 24h stream
                            │                       │  returns rounding dust
```

Revenue arrives at the RevenueSplitter directly from customers. Anyone can call `distribute()` once the balance is at least `minAmount` and at least `cooldown` seconds have passed since the last call. The splitter is the sole operator of sDIEM, so `notifyRewardAmount()` is reachable only through `distribute()`.

### 4.3 USDC Deposit (DIEMVault)

```
Borrower               DIEMVault            Off-chain Watcher
  │                       │                        │
  │── deposit(amount) ───→│                        │
  │                       │── emit Deposited ─────→│ credits relay account
  │                       │   borrowerBalance++    │
```

### 4.4 Compounding (csDIEM)

```
User                    csDIEM                  sDIEM                    Slipstream CL
  │                       │                       │                            │
  │── deposit(DIEM) ─────→│                       │                            │
  │                       │── transferFrom ───────│                            │
  │                       │── stake(amount) ─────→│  forward to Venice         │
  │                       │← shares minted        │                            │
  │                       │                       │                            │
  Anyone calls harvest(deadline):                 │                            │
  ─────────────────────────→│── claimReward() ───→│  pulls accrued USDC        │
  │                       │── consult TWAP ───────────────────────────────────→│  oracle
  │                       │── exactInputSingle() ─────────────────────────────→│  swap USDC → DIEM
  │                       │← DIEM received                                     │
  │                       │── stake(DIEM) ───────→│  restake (compound)        │
  │                       │                       │                            │
  │── requestRedeem(s) ──→│                       │                            │
  │                       │── _burn shares                                     │
  │                       │── _tryWithdrawFromSdiem (if needed):               │
  │                       │── requestWithdraw() ─→│  starts sDIEM 24h cooldown │
  │                       │                       │                            │
  │        ... 24h ...    │                       │                            │
  │                       │                       │                            │
  │── completeRedeem() ──→│                       │                            │
  │                       │── completeWithdraw() ─→  partial-fill OK           │
  │                       │── transfer(user, DIEM)│                            │
```

## 5. Key Security Mechanisms

### 5.1 Reserve Segregation (DIEMVault)

`totalDeposits` (user funds) is tracked separately from `protocolFees`. Admin can only withdraw from `protocolFees`. There is currently no mechanism that increases `protocolFees` in Phase 1 — it remains zero.

### 5.2 Withdrawal Delays (sDIEM)

Uses a request/complete pattern with `WITHDRAWAL_DELAY = 24 hours`:
- `requestWithdraw()` — deducts balance, initiates Venice unstake
- `completeWithdraw()` — requires 24h elapsed + sufficient liquid DIEM

**Batched unstaking**: Requests arriving during an active Venice cooldown are batched via `totalPendingNotInitiated`. When the cooldown matures and any user completes, the entire batch is auto-initiated. Worst-case withdrawal time: ~48h (two Venice cooldowns).

**Important**: Venice resets cooldown for ALL pending unstakes when a new `initiateUnstake()` is called. See KNOWN_ISSUES.md K-1.

### 5.3 Reward Solvency Check (sDIEM)

`notifyRewardAmount()`:
```solidity
uint256 balance = usdc.balanceOf(address(this));
require(rewardRate <= balance / REWARDS_DURATION, "sDIEM: reward too high");
```
Ensures the contract actually holds enough USDC to cover the full reward period. Rounding dust is returned to caller (L-01 fix), capped at the supplied amount so previous-period leftover stays in the stream.

## 6. Areas of Highest Risk

### 6.1 sDIEM Reward Accounting

Synthetix `rewardPerToken()` math with 6-decimal USDC. The 1e18 precision scaling should provide sufficient headroom, but edge cases around:
- Zero `totalStaked` transitions
- Multiple `notifyRewardAmount()` calls within one period (leftover + new)
- Reward claims during withdrawal requests

### 6.2 Venice Interaction Surface

sDIEM interacts with Venice via:
- `stake(amount)` — deposits DIEM
- `initiateUnstake(amount)` — starts cooldown (resets ALL pending)
- `unstake()` — claims after cooldown

If Venice changes its interface or imposes limits, all deposits/withdrawals are blocked until admin intervention.

### 6.3 Deferred Venice Unstake Initiation

When `requestWithdraw()` is called while Venice has an active cooldown, `_tryInitiateVeniceUnstake()` returns silently and the amount is tracked in `totalPendingNotInitiated`. The M-02 fix ensures `completeWithdraw()` calls `_tryInitiateVeniceUnstake()` **before** the payout check, so the deferred batch gets kicked off. Without this, `completeWithdraw()` would revert permanently for those users.

### 6.4 RevenueSplitter — DoS via external dependencies

`distribute()` can be DoS'd by:
- Circle blacklisting `platformReceiver` → admin rotates receiver (2/2 Safe tx)
- sDIEM being paused → same 2/2 Safe controls both contracts; pause is deliberate
- Attacker front-running with a tiny batch just above `minAmount` → stakers still receive the full rewards, but in smaller fragmented streams. Mitigate by raising `minAmount` via admin.

These are accepted operational concerns. See `KNOWN_ISSUES.md` K-8.

### 6.5 csDIEM — Slipstream swap path

`harvest()` swaps USDC → DIEM through an external CL pool. Risks:
- **TWAP manipulation** during low-liquidity windows. Mitigated by 30-min minimum window (1h default), `maxSlippageBps` cap (default 0.5%), and the mandatory absolute `minDiemPerUsdc` floor (Pashov #3) — admin must set this before deploy; the swap reverts if `minDiemPerUsdc` is unset.
- **Sandwich-style MEV via mempool delay**. Mitigated by caller-supplied `deadline` (Pashov #1) — keeper computes deadline at submission time, not at execution time.
- **Pool liquidity drying up** would cause `harvest()` to revert until liquidity returns. No funds at risk; csDIEM holders just stop compounding until the situation resolves. Admin can rotate `oraclePool` to a new CL pool.
- **`uint128` truncation** of the USDC amount passed to `OracleLibrary.getQuoteAtTick`. Mitigated by an explicit `require(usdcAmount <= type(uint128).max)` (Pashov #4).

### 6.6 csDIEM — Async-redemption batch initiation

After a sDIEM batch withdrawal completes (and `sdiemPending == 0`), the next user (or `syncWithdrawals` caller) initiates a fresh `sdiem.requestWithdraw()` for any remaining outstanding redemptions. Pashov #2 flagged this as a potential timer-reset grief. Accepted because the in-tree guard `if (sdiemPending > 0) return;` bounds the impact to one cycle's perturbation per round (cannot be re-fired while a batch is pending), and any user can themselves re-trigger via their own `requestRedeem` call.

## 7. Compiler & Toolchain

| Setting | Value |
|---------|-------|
| Solidity | `0.8.24` (pinned) |
| EVM target | `cancun` |
| Optimizer | Enabled, 200 runs |
| Framework | Foundry |
| OZ version | 5.x |

## 8. File Structure

```
src/
├── sDIEM.sol              # Staking rewards (631 LOC)
├── DIEMVault.sol          # USDC deposit vault (176 LOC)
├── RevenueSplitter.sol    # 20/80 USDC splitter (161 LOC)
├── csDIEM.sol             # ERC-4626 auto-compounding wrapper (556 LOC)
├── interfaces/
│   ├── IsDIEM.sol
│   ├── IDIEMVault.sol
│   ├── IRevenueSplitter.sol
│   ├── IcsDIEM.sol
│   ├── IDIEMStaking.sol      # Venice staking interface
│   ├── ICLPool.sol           # Aerodrome Slipstream CL pool (TWAP source)
│   └── ICLSwapRouter.sol     # Aerodrome Slipstream swap router
└── libraries/
    ├── OracleLibrary.sol     # TWAP price queries (csDIEM)
    ├── TickMath.sol
    └── FullMath.sol
```

## 9. Related Documents

- `KNOWN_ISSUES.md` — Known issues, accepted risks, invariants, out-of-scope items
- `test/` — invariant suites for sDIEM, DIEMVault, and RevenueSplitter
- Static analysis: Slither passed with 0 High/Critical findings
