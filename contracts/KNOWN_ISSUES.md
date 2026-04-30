# DIEM Staking Protocol — Audit Known Issues & Accepted Risks

> Prepared for security review. Documents known limitations, accepted risks,
> trust assumptions, and out-of-scope items.

---

## Architecture Overview

```
Revenue Flow (automated via RevenueSplitter):
  Compute customer USDC payments → RevenueSplitter
                                     ├─ 20% → 2/2 Safe (platform)
                                     └─ 80% → sDIEM.notifyRewardAmount (24h stream)

Staking Flow:
  User DIEM → sDIEM → Venice forward-stake (compute credits)
  Withdrawal: 24h async request → completeWithdraw (auto-claims from Venice)

Compounding Flow (optional):
  User DIEM → csDIEM → sDIEM (auto-staked)
  harvest(deadline): sDIEM USDC reward stream → swap via Slipstream CL → restake
  Redemption: 24h async requestRedeem → completeRedeem (mirrors sDIEM)

Deposit Flow (Phase 1):
  Borrower USDC → DIEMVault → off-chain relay watcher credits relay account
```

### Contracts in Scope

| Contract | LOC | Purpose |
|----------|-----|---------|
| `sDIEM.sol` | ~631 | Synthetix StakingRewards fork; deposit DIEM, earn USDC |
| `DIEMVault.sol` | ~176 | Phase 1 USDC deposit-only vault for relay |
| `RevenueSplitter.sol` | ~161 | 20/80 USDC splitter: Safe + sDIEM (see K-8 below) |
| `csDIEM.sol` | ~556 | ERC-4626 auto-compounding wrapper over sDIEM (see K-9 below) |

### Privileged Roles

| Role | Scope | Capabilities |
|------|-------|-------------|
| **Admin** (all contracts) | Protocol governance | Pause/unpause, set parameters, two-step transfer, token recovery |
| **Operator** (sDIEM) | Reward seeding | `notifyRewardAmount()` only. Deployed operator is the RevenueSplitter contract (not an EOA), so rewards are auto-forwarded from customer USDC receipts. |
| **Admin** (RevenueSplitter) | Revenue-flow governance | Same 2/2 Safe. Can rotate `platformReceiver`, adjust `minAmount`/`cooldown` (within bounds), pause, and rescue non-USDC tokens. Cannot rescue USDC and cannot change the 20/80 ratio. |
| **Admin** (csDIEM) | Compounding-vault governance | Same 2/2 Safe. Can rotate `swapRouter`/`oraclePool`, tune slippage/TWAP/`minDiemPerUsdc`/`minHarvest`, pause deposits+harvest. Cannot rescue DIEM/USDC, cannot bypass 24h redemption delay, cannot change share-price math. |

---

## Known Issues & Accepted Risks

### K-1: Venice Cooldown Reset Cascade (Medium)

**Description**: Venice's `initiateUnstake()` resets the 24h cooldown for ALL
pending unstakes on that contract, not just the new request. When User A
requests withdrawal at T₀, then User B requests at T₁ (T₁ > T₀), User A's
cooldown resets to T₁.

**Affected contracts**: sDIEM

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

**Description**: Unlike sDIEM (which uses two-step
`transferAdmin`/`acceptAdmin`), DIEMVault uses a single-step `setAdmin()`.

**Impact**: Admin key compromise allows immediate, irrecoverable admin takeover.

**Accepted because**:
- DIEMVault is the simplest contract with limited admin powers
  (pause deposits, adjust min deposit, withdraw fees)
- Admin cannot access user deposits (only `protocolFees`)
- Will be upgraded to two-step in Phase 2

---

### K-5: Withdrawal Liquidity Coordination (Low) — PARTIALLY FIXED

**Description**: `completeWithdraw()` (sDIEM) requires sufficient liquid DIEM
in the contract. If `requestWithdraw()` was called while Venice had an active
cooldown, `_tryInitiateVeniceUnstake()` returned silently and the Venice
unstake was never initiated. Then `completeWithdraw()` reverted ("nothing
claimable yet") because the re-trigger at the end of the function was
unreachable (after the revert).

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

### K-8: RevenueSplitter — Pending External Audit (Informational)

**Description**: `RevenueSplitter.sol` was deployed in April 2026 and has not been covered by the Bretzel or Pashov AI external audits (which were scoped to sDIEM and DIEMVault as of March 2026).

**Internal review only**: The contract passed an in-house adversarial pass using the Pashov AI `solidity-auditor` skill on 2026-04-14. Findings:

- **Remediated**: `setMinAmount(0)` was permitted by the bounds check, which would have let an admin misconfiguration enable an attacker to call `distribute()` with zero balance, resetting the cooldown for up to 7 days with no payout. Fixed by adding `require(newMinAmount > 0, "RS: min zero")`.
- **Accepted (admin-fixable)**: If Circle blacklists `platformReceiver`, every `distribute()` reverts on `safeTransfer`. Mitigation: the 2/2 Safe rotates the receiver via `setPlatformReceiver`.
- **Accepted (operational)**: A griefer can trigger `distribute()` the moment the balance crosses `minAmount`, fragmenting the staker reward stream into small batches. Stakers still receive all funds. Mitigation: admin raises `minAmount`.
- **Not a real finding**: sDIEM being paused would DoS `distribute()` — but the same 2/2 Safe admins both contracts, so any pause is deliberate.

**Impact**: The remediated grief vector was the only issue that could cause incorrect behavior. The other three are operational concerns, not exploits.

**Accepted because**:
- An external review is recommended before meaningful customer revenue flows through the contract — explicitly called out in the README Security section.
- The attack surface is small (~161 LOC, no loops, no oracles, no swaps).
- `rescueToken()` explicitly blocks USDC, so the admin cannot drain customer payments.
- The split ratio is hardcoded (`PLATFORM_BPS = 2000`, `STAKER_BPS = 8000`); changing it requires redeploy.
- All setters have bounded admin mutability (`MIN_AMOUNT_CAP = 10,000 USDC`, `MAX_COOLDOWN = 7 days`).

---

### K-9: csDIEM — Internal Audit Coverage Only (Informational)

**Description**: `csDIEM.sol` was deployed in April 2026. Like RevenueSplitter (K-8), it has not been covered by an external audit. It was reviewed in-house using the Pashov AI `solidity-auditor` skill on 2026-04-30.

**Findings + remediations**:

- **#1 [85] — Internally-derived swap deadline (REMEDIATED)**: `harvest()` previously hard-coded `deadline = block.timestamp + 300`, which is always satisfied at execution time and provides no mempool-delay protection. Fixed by changing the signature to `harvest(uint256 deadline)` — caller computes the deadline at submission time, not at execution.
- **#3 [75] — Missing absolute output floor (REMEDIATED)**: `minDiemPerUsdc` defaulted to 0, in which case the absolute price floor was skipped entirely (only the relative TWAP-derived `amountOutMin` protected the swap). A sustained 30-min TWAP manipulation could have drained harvest USDC. Fixed by making the floor mandatory: `_swapUsdcToDiem` now `require(minDiemPerUsdc > 0)`, and the deploy script sets it before the broadcast ends.
- **#4 [65] — Unsafe uint128 downcast (REMEDIATED)**: Belt-and-suspenders `require(usdcAmount <= type(uint128).max)` added before the OracleLibrary call. Practically unreachable given USDC supply, but eliminates a silent footgun.
- **#2 [80] — Timer-reset grief on `syncWithdrawals` (ACCEPTED)**: After an sDIEM batch withdrawal completes (`sdiemPending == 0`), any caller can invoke `syncWithdrawals` to initiate the next batch, starting a fresh 24h sDIEM cooldown for everyone with a pending csDIEM redemption.

**Why K-9 (#2) is accepted**:
- The in-tree guard `if (sdiemPending > 0) return;` in `_tryWithdrawFromSdiem` already bounds the impact: while a batch is pending, no one can re-trigger and reset its timer.
- After a batch completes, *some* caller has to initiate the next batch — that's the architectural design, not griefing. Whether that caller is a real redeemer or an attacker doesn't change the 24h Venice cooldown the next batch must wait through.
- Worst-case impact is one cycle's perturbation per round (a few seconds of timing shift), not "indefinite delay."
- A defensive `lastSdiemBatchInitiated` rate-limit could be added in a future redeploy if the operational pattern shows real grief, but it adds complexity without a concrete attack scenario.

**Other accepted Trust Assumptions** (see AUDIT.md §3 for full table): csDIEM depends on Aerodrome Slipstream's `SwapRouter` and the DIEM/USDC CL pool. The deploy script asserts `oraclePool.token0/1 == {DIEM, USDC}` and `tickSpacing()` matches before broadcasting; an external review is recommended before significant TVL accumulates.

---

## Out of Scope

| Item | Reason |
|------|--------|
| Frontend / UI vulnerabilities | Not part of smart contract audit |
| Off-chain relay watcher security | Separate system, not on-chain |
| Venice protocol internals | Third-party dependency; audited separately |
| DIEM token contract itself | Pre-existing, not modified in this scope |
| DIEMVault withdrawals, bridges | Not yet implemented (Phase 2) |
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

### DIEMVault

1. `usdc.balanceOf(vault) >= totalDeposits + protocolFees`
2. `Σ(borrowerBalance[user]) == totalDeposits`
3. `totalDeposits` is monotonically non-decreasing (deposit-only)
4. `protocolFees` is zero in Phase 1 (no fee mechanism yet)

### RevenueSplitter

1. After any `distribute()`, `usdc.balanceOf(splitter)` drops by exactly `platformCut + stakerCut`
2. `totalPlatformPaid * 10000 <= (totalPlatformPaid + totalStakerPaid) * 2000` — platform share never exceeds 20%
3. `stakerCut >= (bal * 8000) / 10000` on every distribution — stakers never get less than 80%, rounding dust always flows to stakers
4. `rescueToken(USDC, ...)` always reverts — USDC is permanently non-rescuable
5. `admin` cannot change `USDC`, `sdiem`, `PLATFORM_BPS`, or `STAKER_BPS` (immutable / constant)

### csDIEM

1. `totalAssets() == sdiem.balanceOf(csDIEM) + sdiemPendingWithdrawal + IERC20(DIEM).balanceOf(csDIEM) - totalPendingRedemptions` — DIEM accounted for across all states
2. Share price (`convertToAssets(1e18)`) is monotonically non-decreasing across `harvest()` calls (no slashing path)
3. Sum of `redemptionRequests[user].assets` over all users == `totalPendingRedemptions`
4. Standard ERC-4626 `withdraw`/`redeem` always revert — exits go through `requestRedeem`/`completeRedeem` only
5. `harvest()` reverts when `minDiemPerUsdc == 0` (mandatory floor enforced post-Pashov #3)
6. After successful `harvest()`, `usdc.balanceOf(csDIEM) == 0` (all claimed USDC swapped + restaked)
7. `recoverERC20()` always reverts for `DIEM` (underlying) and `USDC` (harvest intermediate)
