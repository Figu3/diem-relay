# DIEM Staking Protocol — Auditor Briefing

> Target: 4 Solidity 0.8.24 contracts (~1,300 LOC total)
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
          │ (USDC transfer)                      (DIEM transfer)
          │                                                   │
    ┌─────┴───────────────────────────────────────────────────┴──┐
    │                    RevenueSplitter                          │
    │                                                            │
    │  Receives USDC → splits by sdiemBps:                       │
    │    - sDIEM portion: USDC transfer + notifyRewardAmount()   │
    │    - csDIEM portion: swap USDC→DIEM on Aerodrome → donate  │
    │                                                            │
    │  Anti-sandwich: Aerodrome TWAP oracle for amountOutMin     │
    └────────────────────────────────────────────────────────────┘

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
| `sDIEM.sol` | 437 | ReentrancyGuard | Synthetix StakingRewards fork |
| `csDIEM.sol` | 349 | OZ ERC4626 | Virtual shares (1e6 offset), async redemption |
| `RevenueSplitter.sol` | 314 | ReentrancyGuard | Permissionless distribution, TWAP oracle |
| `DIEMVault.sol` | 140 | ReentrancyGuard | Deposit-only, reserve segregation |

## 3. Trust Assumptions

### External Protocols

| Dependency | Trust Level | What We Trust |
|------------|-------------|---------------|
| **Venice DIEM staking** | High | `stake()`, `initiateUnstake()`, `unstake()` behave correctly. 24h cooldown is honored. `stakedInfos()` returns accurate balances. DIEM is returned after cooldown. |
| **Aerodrome Router** | High | `swapExactTokensForTokens()` respects `amountOutMinimum`. Tokens are transferred atomically. Router does not retain tokens. |
| **Aerodrome Pool (TWAP)** | Medium | `quote()` returns a reasonable time-weighted price. Pool has sufficient observation history (`observationLength >= granularity`). TWAP is resistant to single-block manipulation. |
| **DIEM token** | High | Standard ERC-20. Has built-in staking (`IDIEMStaking` interface on the same contract). `mint()` callable by Venice staking infra (not by our contracts). |
| **USDC** | High | Standard ERC-20. 6 decimals. No fee-on-transfer. No rebasing. |
| **OpenZeppelin 5.x** | High | ERC4626, SafeERC20, ReentrancyGuard are correct. |

### Admin Trust

The **admin** role can:
- Pause/unpause all state-changing functions
- Adjust parameters (split ratio, slippage, min amounts, swap router, oracle pool)
- Recover non-core tokens (cannot recover DIEM from sDIEM/csDIEM, cannot recover USDC from RevenueSplitter)
- Transfer admin via two-step process (except DIEMVault which is single-step)

The admin **cannot**:
- Access staker funds (DIEM in sDIEM/csDIEM)
- Access user deposits (USDC in DIEMVault, only `protocolFees`)
- Bypass withdrawal delays
- Mint shares/tokens
- Change immutable addresses (DIEM, USDC, sDIEM, csDIEM references)

### Operator Trust (sDIEM only)

The operator can:
- Call `notifyRewardAmount()` to seed USDC reward periods

The operator **cannot**:
- Pause, change admin, recover tokens, or modify any parameters
- Notify rewards exceeding the contract's actual USDC balance (sanity check on L383)

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
  │── claimFromVenice() ─→│── diemStaking.unstake() ──→│  returns DIEM
  │                       │                            │
  │── completeWithdraw() →│── transfer(user, amount) ──│
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

**Share price increase**: RevenueSplitter calls `csdiem.donate(diemAmount)` which increases `totalAssets()` without minting shares → share price goes up.

### 4.3 Revenue Distribution

```
Anyone                 RevenueSplitter           sDIEM        csDIEM      Aerodrome
  │                          │                     │            │            │
  │── distribute() ─────────→│                     │            │            │
  │                          │                     │            │            │
  │  [sdiemBps portion]      │                     │            │            │
  │                          │── USDC.transfer() ─→│            │            │
  │                          │── notifyReward() ──→│            │            │
  │                          │                     │            │            │
  │  [remaining portion]     │                     │            │            │
  │                          │── pool.quote() ─────│────────────│───────────→│ TWAP
  │                          │── router.swap() ────│────────────│───────────→│ USDC→DIEM
  │                          │── csdiem.donate() ──│───────────→│            │
```

### 4.4 USDC Deposit (DIEMVault)

```
Borrower               DIEMVault            Off-chain Watcher
  │                       │                        │
  │── deposit(amount) ───→│                        │
  │                       │── emit Deposited ─────→│ credits relay account
  │                       │   borrowerBalance++    │
```

## 5. Key Security Mechanisms

### 5.1 Anti-Sandwich (RevenueSplitter)

The `_swapUsdcToDiem()` flow:
1. Query Aerodrome TWAP: `pool.quote(usdc, amount, granularity)` — ~2-hour window at default `granularity=4` with `periodSize=1800s`
2. Apply slippage: `amountOutMin = twapOut * (10000 - maxSlippageBps) / 10000`
3. Execute swap with `amountOutMin` floor

**Attack surface**: If TWAP is stale or manipulated over the full observation window, the price floor is wrong. Admin can adjust `maxSlippageBps` (capped at 10%) and `twapGranularity`.

### 5.2 Inflation Attack Mitigation (csDIEM)

`_decimalsOffset()` returns 6, creating a 1e6 virtual share/asset offset. This makes first-depositor donation attacks cost ~1e6 DIEM per 1 wei stolen — economically infeasible.

### 5.3 Reserve Segregation (DIEMVault)

`totalDeposits` (user funds) is tracked separately from `protocolFees`. Admin can only withdraw from `protocolFees`. There is currently no mechanism that increases `protocolFees` in Phase 1 — it remains zero.

### 5.4 Withdrawal Delays (sDIEM, csDIEM)

Both use a request/complete pattern with `WITHDRAWAL_DELAY = 24 hours`:
- `requestWithdraw()` / `requestRedeem()` — deducts balance, initiates Venice unstake
- `completeWithdraw()` / `completeRedeem()` — requires 24h elapsed + sufficient liquid DIEM

**Important**: Venice resets cooldown for ALL pending unstakes when a new `initiateUnstake()` is called. See KNOWN_ISSUES.md K-1.

### 5.5 Reward Solvency Check (sDIEM)

`notifyRewardAmount()` (L382-383):
```solidity
uint256 balance = usdc.balanceOf(address(this));
require(rewardRate <= balance / REWARDS_DURATION, "sDIEM: reward too high");
```
Ensures the contract actually holds enough USDC to cover the full reward period.

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

### 6.3 RevenueSplitter Atomicity

`_distribute()` makes 3-4 external calls atomically:
1. `usdc.safeTransfer(sDIEM)` — can fail if sDIEM is blacklisted
2. `sdiem.notifyRewardAmount()` — can fail if sDIEM is paused or operator is wrong
3. `router.swap()` — can fail if pool is empty/paused
4. `csdiem.donate()` — can fail if csDIEM is paused

Any failure reverts the entire distribution. See KNOWN_ISSUES.md K-2.

### 6.4 Venice Interaction Surface

Both sDIEM and csDIEM interact with Venice via:
- `stake(amount)` — deposits DIEM
- `initiateUnstake(amount)` — starts cooldown (resets ALL pending)
- `unstake()` — claims after cooldown

If Venice changes its interface or imposes limits, all deposits/withdrawals are blocked until admin intervention.

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
├── sDIEM.sol              # Staking rewards
├── csDIEM.sol             # Compounding vault
├── RevenueSplitter.sol    # Revenue distribution
├── DIEMVault.sol          # USDC deposit vault
└── interfaces/
    ├── IsDIEM.sol
    ├── IcsDIEM.sol
    ├── IRevenueSplitter.sol
    ├── IDIEMVault.sol
    ├── IDIEMStaking.sol       # Venice staking interface
    ├── IAerodromeRouter.sol   # Aerodrome swap
    └── IAerodromePool.sol     # Aerodrome TWAP oracle
```

## 9. Related Documents

- `KNOWN_ISSUES.md` — Known issues, accepted risks, invariants, out-of-scope items
- `test/` — 224 tests including invariant suites for all 4 contracts
- Static analysis: Slither passed with 0 High/Critical findings
