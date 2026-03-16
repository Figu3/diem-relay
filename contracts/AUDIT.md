# DIEM Staking Protocol — Auditor Briefing

> Target: 3 Solidity 0.8.24 contracts (~1,363 LOC total)
> Chain: Base (Aerodrome DEX for swaps/oracle)
> Dependencies: OpenZeppelin 5.x, Aerodrome Router/Pool, Venice DIEM staking

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
          ┌─────────────────────┴───────────┴─────────────────┐
          │                                                   │
    ┌─────┴──────┐                                   ┌────────┴───────┐
    │   sDIEM    │                                   │    csDIEM      │
    │            │                                   │   (ERC-4626)   │
    │ Stake DIEM │                                   │ Deposit DIEM   │
    │ Earn USDC  │                                   │ Auto-compound  │
    │ (linear)   │                                   │ (share price↑) │
    └─────┬──────┘                                   └────────┬───────┘
          │ notifyRewardAmount()                    donate()  │
          │ (USDC transfer from operator)       (DIEM transfer)
          │                                                   │
          └───────────────────────────────────────────────────┘
            Revenue currently seeded manually by operator.
            RevenueSplitter planned for Phase 2 (auto-distribution).

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
| `csDIEM.sol` | 556 | OZ ERC4626 | Virtual shares (1e6 offset), async redemption, Venice forward-staking |
| `DIEMVault.sol` | 176 | ReentrancyGuard | Deposit-only, reserve segregation |

## 3. Trust Assumptions

### External Protocols

| Dependency | Trust Level | What We Trust |
|------------|-------------|---------------|
| **Venice DIEM staking** | High | `stake()`, `initiateUnstake()`, `unstake()` behave correctly. 24h cooldown is honored. `stakedInfos()` returns accurate balances. DIEM is returned after cooldown. |
| **Aerodrome Pool (TWAP)** | Medium | csDIEM uses `observe()` for TWAP price reference during harvest swaps. Pool has sufficient observation history. TWAP is resistant to single-block manipulation. |
| **Aerodrome Router** | High | `exactInputSingle()` respects `amountOutMinimum`. Tokens are transferred atomically. Router does not retain tokens. |
| **DIEM token** | High | Standard ERC-20. Has built-in staking (`IDIEMStaking` interface on the same contract). `mint()` callable by Venice staking infra (not by our contracts). |
| **USDC** | High | Standard ERC-20. 6 decimals. No fee-on-transfer. No rebasing. |
| **OpenZeppelin 5.x** | High | ERC4626, SafeERC20, ReentrancyGuard are correct. |

### Admin Trust

The **admin** role can:
- Pause/unpause all state-changing functions
- Adjust parameters (slippage, min amounts, swap router, oracle pool)
- Recover non-core tokens (cannot recover DIEM from sDIEM/csDIEM)
- Transfer admin via two-step process (except DIEMVault which is single-step)

The admin **cannot**:
- Access staker funds (DIEM in sDIEM/csDIEM)
- Access user deposits (USDC in DIEMVault, only `protocolFees`)
- Bypass withdrawal delays
- Mint shares/tokens
- Change immutable addresses (DIEM, USDC, sDIEM references)

### Operator Trust (sDIEM only)

The operator can:
- Call `notifyRewardAmount()` to seed USDC reward periods

The operator **cannot**:
- Pause, change admin, recover tokens, or modify any parameters
- Notify rewards exceeding the contract's actual USDC balance (sanity check enforced)

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

### 4.2 Compounding (csDIEM)

```
User                   csDIEM                   Venice
  │                      │                         │
  │── deposit(assets) ──→│ mint shares             │
  │                      │── diemStaking.stake() ──→│  forward to Venice
  │                      │                         │
  │── requestRedeem() ──→│ burn shares             │
  │                      │── initiateUnstake() ───→│  starts 24h cooldown
  │                      │                         │
  │── completeRedeem() ─→│── transfer(user) ───────│
```

**Share price increase**: Operator or keeper calls `csdiem.donate(diemAmount)` which increases `totalAssets()` without minting shares → share price goes up. (Phase 2: RevenueSplitter will automate this.)

### 4.3 Revenue Seeding (Phase 1 — Manual)

```
Operator                sDIEM
  │                       │
  │── USDC.approve() ────→│
  │── notifyRewardAmount()→│  pulls USDC, starts 24h linear stream
  │                       │  returns rounding dust to operator
```

Revenue is currently seeded manually by the operator. A RevenueSplitter contract (splitting USDC between sDIEM and csDIEM with on-chain swaps) is planned for Phase 2.

### 4.4 USDC Deposit (DIEMVault)

```
Borrower               DIEMVault            Off-chain Watcher
  │                       │                        │
  │── deposit(amount) ───→│                        │
  │                       │── emit Deposited ─────→│ credits relay account
  │                       │   borrowerBalance++    │
```

## 5. Key Security Mechanisms

### 5.1 Anti-Sandwich (csDIEM harvest)

The `harvest()` → `_swapUsdcToDiem()` flow:
1. Query Aerodrome TWAP via `OracleLibrary.consult()` — configurable observation window (minimum 5 minutes)
2. Apply slippage: `amountOutMin = twapOut * (10000 - maxSlippageBps) / 10000`
3. Execute swap with `amountOutMin` floor
4. Absolute DIEM-per-USDC price floor as circuit breaker

**Attack surface**: If TWAP is stale or manipulated over the full observation window, the price floor is wrong. Admin can adjust `maxSlippageBps` (capped at 10%) and TWAP window.

### 5.2 Inflation Attack Mitigation (csDIEM)

`_decimalsOffset()` returns 6, creating a 1e6 virtual share/asset offset. This makes first-depositor donation attacks cost ~1e6 DIEM per 1 wei stolen — economically infeasible.

### 5.3 Reserve Segregation (DIEMVault)

`totalDeposits` (user funds) is tracked separately from `protocolFees`. Admin can only withdraw from `protocolFees`. There is currently no mechanism that increases `protocolFees` in Phase 1 — it remains zero.

### 5.4 Withdrawal Delays (sDIEM, csDIEM)

Both use a request/complete pattern with `WITHDRAWAL_DELAY = 24 hours`:
- `requestWithdraw()` / `requestRedeem()` — deducts balance, initiates Venice unstake
- `completeWithdraw()` / `completeRedeem()` — requires 24h elapsed + sufficient liquid DIEM

**Batched unstaking**: Requests arriving during an active Venice cooldown are batched via `totalPendingNotInitiated`. When the cooldown matures and any user completes, the entire batch is auto-initiated. Worst-case withdrawal time: ~48h (two Venice cooldowns).

**Important**: Venice resets cooldown for ALL pending unstakes when a new `initiateUnstake()` is called. See KNOWN_ISSUES.md K-1.

### 5.5 Reward Solvency Check (sDIEM)

`notifyRewardAmount()`:
```solidity
uint256 balance = usdc.balanceOf(address(this));
require(rewardRate <= balance / REWARDS_DURATION, "sDIEM: reward too high");
```
Ensures the contract actually holds enough USDC to cover the full reward period. Rounding dust is returned to caller (L-01 fix).

## 6. Areas of Highest Risk

### 6.1 sDIEM Reward Accounting

Synthetix `rewardPerToken()` math with 6-decimal USDC. The 1e18 precision scaling should provide sufficient headroom, but edge cases around:
- Zero `totalStaked` transitions
- Multiple `notifyRewardAmount()` calls within one period (leftover + new)
- Reward claims during withdrawal requests

### 6.2 csDIEM `totalAssets()` Accuracy

```solidity
function totalAssets() {
    (uint256 staked,, uint256 pending) = diemStaking.stakedInfos(address(this));
    uint256 gross = diem.balanceOf(address(this)) + staked + pending;
    return gross > totalPendingRedemptions ? gross - totalPendingRedemptions : 0;
}
```

This includes Venice-staked and Venice-pending DIEM. If Venice's `stakedInfos()` returns incorrect values, share price is wrong. `totalPendingRedemptions` subtraction is critical — without it, redeemers' owed DIEM would inflate the share price for remaining holders.

### 6.3 Venice Interaction Surface

Both sDIEM and csDIEM interact with Venice via:
- `stake(amount)` — deposits DIEM
- `initiateUnstake(amount)` — starts cooldown (resets ALL pending)
- `unstake()` — claims after cooldown

If Venice changes its interface or imposes limits, all deposits/withdrawals are blocked until admin intervention.

### 6.4 Deferred Venice Unstake Initiation

When `requestWithdraw()` is called while Venice has an active cooldown, `_tryInitiateVeniceUnstake()` returns silently and the amount is tracked in `totalPendingNotInitiated`. The M-02 fix ensures `completeWithdraw()` calls `_tryInitiateVeniceUnstake()` **before** the payout check, so the deferred batch gets kicked off. Without this, `completeWithdraw()` would revert permanently for those users.

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
├── csDIEM.sol             # Compounding vault (556 LOC)
├── DIEMVault.sol          # USDC deposit vault (176 LOC)
└── interfaces/
    ├── IsDIEM.sol
    ├── IcsDIEM.sol
    ├── IDIEMVault.sol
    ├── IDIEMStaking.sol       # Venice staking interface
    ├── ICLSwapRouter.sol      # Aerodrome Slipstream CL router
    └── ICLPool.sol            # Aerodrome Slipstream CL pool
libraries/
    ├── OracleLibrary.sol      # TWAP oracle consultation
    ├── TickMath.sol           # Tick-to-price math
    └── FullMath.sol           # 512-bit multiplication helpers
```

## 9. Related Documents

- `KNOWN_ISSUES.md` — Known issues, accepted risks, invariants, out-of-scope items
- `test/` — 190 tests including invariant suites for all 3 contracts
- Static analysis: Slither passed with 0 High/Critical findings
