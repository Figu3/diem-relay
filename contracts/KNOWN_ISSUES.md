# DIEM Staking Protocol — Audit Known Issues & Accepted Risks

> Prepared for security review. Documents known limitations, accepted risks,
> trust assumptions, and out-of-scope items.

---

## Architecture Overview

```
Revenue Flow (Phase 1 — manual):
  Venice compute credits → USDC revenue → operator calls notifyRewardAmount()
                                            └─ sDIEM  (linear USDC rewards)
  (Phase 2: RevenueSplitter will auto-split to sDIEM + csDIEM)

Staking Flow:
  User DIEM → sDIEM/csDIEM → Venice forward-stake (compute credits)
  Withdrawal: 24h async request → completeWithdraw/Redeem (auto-claims from Venice)

Deposit Flow (Phase 1):
  Borrower USDC → DIEMVault → off-chain relay watcher credits relay account
```

### Contracts in Scope

| Contract | LOC | Purpose |
|----------|-----|---------|
| `sDIEM.sol` | ~631 | Synthetix StakingRewards fork; deposit DIEM, earn USDC |
| `csDIEM.sol` | ~556 | ERC-4626 compounding vault; deposit DIEM, share price grows |
| `DIEMVault.sol` | ~176 | Phase 1 USDC deposit-only vault for relay |

### Privileged Roles

| Role | Scope | Capabilities |
|------|-------|-------------|
| **Admin** (all contracts) | Protocol governance | Pause/unpause, set parameters, two-step transfer, token recovery |
| **Operator** (sDIEM) | Reward seeding | `notifyRewardAmount()` only — cannot pause, change admin, or recover tokens |
| **Operator** (csDIEM) | Reserved | Field exists but unused in Phase 1 |

---

## Known Issues & Accepted Risks

### K-1: Venice Cooldown Reset Cascade (Medium)

**Description**: Venice's `initiateUnstake()` resets the 24h cooldown for ALL
pending unstakes on that contract, not just the new request. When User A
requests withdrawal at T₀, then User B requests at T₁ (T₁ > T₀), User A's
cooldown resets to T₁.

**Affected contracts**: sDIEM, csDIEM

**Impact**: Users who requested earlier may experience unexpected withdrawal
delays (up to an additional 24h per subsequent request from any user).

**Accepted because**:
- This is Venice protocol's inherent behavior, not a bug in our contracts
- Maximum additional delay is bounded at 24h per reset
- In practice, withdrawal request frequency is low (not every block)
- Documenting in UI/docs that withdrawal timing is approximate
- Batched unstaking via `totalPendingNotInitiated` minimizes the number of
  Venice `initiateUnstake()` calls, reducing cascade frequency

---

### K-2: DIEMVault Has No Withdrawal Mechanism (Informational)

**Description**: Phase 1 DIEMVault is deposit-only. Users deposit USDC and
receive relay credits via off-chain watcher. There is no on-chain withdrawal
path.

**Impact**: Deposited USDC is irrecoverable on-chain. Users rely entirely on
the off-chain relay system to credit their accounts.

**Accepted because**:
- This is the intended Phase 1 design — relay credit is the "withdrawal"
- Phase 2 will add on-chain withdrawal/bridge mechanism
- `borrowerBalance` mapping provides on-chain proof of deposits
- Admin can `withdrawProtocolFees()` for protocol fees only, not user deposits

---

### K-3: DIEMVault Uses Single-Step Admin Transfer (Low)

**Description**: Unlike sDIEM and csDIEM (which use two-step
`transferAdmin`/`acceptAdmin`), DIEMVault uses a single-step `setAdmin()`.

**Impact**: Admin key compromise allows immediate, irrecoverable admin takeover.

**Accepted because**:
- DIEMVault is the simplest contract with limited admin powers
  (pause deposits, adjust min deposit, withdraw fees)
- Admin cannot access user deposits (only `protocolFees`)
- Will be upgraded to two-step in Phase 2

---

### K-4: Aerodrome TWAP Oracle Dependency (Low)

**Description**: csDIEM uses Aerodrome's on-chain TWAP oracle for sandwich
protection during harvest swaps. If the DIEM/USDC pool becomes illiquid or
deprecated, TWAP quotes become unreliable.

**Impact**: Swaps could execute at unfavorable rates, or `harvest()` could
revert if the pool has insufficient observations.

**Accepted because**:
- Aerodrome is the sole DIEM liquidity venue — if the pool dies, swaps
  are impossible anyway
- Admin can update `oraclePool` address if pool migrates
- TWAP observation window is configurable (minimum 5 minutes)
- `maxSlippageBps` (capped at 10%) caps worst-case execution

---

### K-5: Withdrawal Liquidity Coordination (Low) — PARTIALLY FIXED

**Description**: `completeWithdraw()` (sDIEM) and `completeRedeem()` (csDIEM)
require sufficient liquid DIEM in the contract. If `requestWithdraw()` was
called while Venice had an active cooldown, `_tryInitiateVeniceUnstake()`
returned silently and the Venice unstake was never initiated. Then
`completeWithdraw()` reverted ("nothing claimable yet") because the re-trigger
at the end of the function was unreachable (after the revert).

**Fix (M-02)**: `completeWithdraw()` now calls `_tryInitiateVeniceUnstake()`
**before** the payout check. This ensures deferred Venice unstakes are kicked
off even when the original `requestWithdraw()` couldn't initiate them. The user
still needs to wait for Venice's 24h cooldown and call `completeWithdraw()`
again, but the process is now self-healing rather than permanently stuck.

**Remaining accepted risk**:
- `claimFromVenice()` is permissionless — any user, keeper, or bot can call it
- UI will auto-detect and prompt users to claim first
- `redeployExcess()` is also permissionless, ensuring idle DIEM earns yield
- Worst case: user calls `completeWithdraw()` twice (first triggers Venice
  unstake, second completes the withdrawal after 24h cooldown)

---

### K-6: Reward Precision with 6-Decimal USDC (Informational)

**Description**: sDIEM uses 1e18 precision scaling for `rewardPerToken`
calculations despite USDC being 6 decimals. Very small stakers relative to
total staked may experience rounding to zero on earned rewards.

**Impact**: Dust-level precision loss for extremely small positions. For
example, staking 1 wei of DIEM when totalStaked is 1e24 could round rewards
to zero.

**Accepted because**:
- Standard Synthetix approach, battle-tested
- Practical impact is negligible — minimum meaningful stake is far above
  the rounding threshold
- 1e18 scaling provides ~12 extra decimal places of precision beyond USDC's 6

---

### K-7: csDIEM Donation Attack Surface (Informational)

**Description**: Anyone can call `csDIEM.donate()` to increase share price.
An attacker could front-run a large deposit by donating DIEM, inflating the
share price, then the depositor gets fewer shares.

**Impact**: First-depositor or donation-based share inflation attacks.

**Accepted because**:
- ERC-4626 virtual shares/assets offset of 1e6 makes this attack
  economically infeasible (attacker must donate ~1e6 DIEM to steal 1 wei)
- OpenZeppelin's ERC-4626 implementation includes this defense by default
- No practical attack vector at realistic DIEM prices

---

## Out of Scope

| Item | Reason |
|------|--------|
| Frontend / UI vulnerabilities | Not part of smart contract audit |
| Off-chain relay watcher security | Separate system, not on-chain |
| Venice protocol internals | Third-party dependency; audited separately |
| Aerodrome protocol internals | Third-party dependency; audited separately |
| DIEM token contract itself | Pre-existing, not modified in this scope |
| Phase 2 features (DIEMVault withdrawals, RevenueSplitter, bridges) | Not yet implemented |
| Keeper/bot infrastructure | Off-chain operational concern |

---

## Invariants

### sDIEM

1. `Σ(balanceOf[user]) == totalStaked` — sum of all staker balances equals totalStaked
2. `rewardPerTokenStored` is monotonically non-decreasing
3. `usdc.balanceOf(sDIEM) >= Σ(earned[user])` — contract always holds enough USDC
  to pay all accrued rewards (reward solvency)
4. `totalPendingWithdrawals` matches sum of all pending withdrawal request amounts
5. `diem.balanceOf(sDIEM) + venice.stakedAmount(sDIEM) + venice.pendingAmount(sDIEM) >= totalStaked + totalPendingWithdrawals`
   — DIEM conservation across Venice

### csDIEM

1. `totalSupply > 0 → totalAssets > 0` — no shares without backing assets
2. Share price (`convertToAssets(1e18)`) is monotonically non-decreasing
   (donations only increase, never decrease)
3. `totalPendingRedemptions` matches sum of all pending redemption request amounts
4. `diem.balanceOf(csDIEM) + venice.stakedAmount(csDIEM) + venice.pendingAmount(csDIEM) >= totalAssets + totalPendingRedemptions`
   — DIEM conservation
5. `convertToShares(convertToAssets(shares)) <= shares` — rounding favors vault

### DIEMVault

1. `usdc.balanceOf(vault) >= totalDeposits + protocolFees`
2. `Σ(borrowerBalance[user]) == totalDeposits`
3. `totalDeposits` is monotonically non-decreasing (deposit-only)
4. `protocolFees` is zero in Phase 1 (no fee mechanism yet)
