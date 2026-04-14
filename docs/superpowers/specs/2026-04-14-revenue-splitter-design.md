# RevenueSplitter Design

**Date**: 2026-04-14
**Status**: Approved, ready for implementation
**Target**: First distribution today

## Problem

Customers of `cheaptokens.ai` pay USDC for discounted Venice AI compute. This USDC is the yield that should flow back to DIEM stakers via `sDIEM.notifyRewardAmount()`. Today, there is no automated pipeline: yield would need to be manually transferred by atd (operator) and split by hand between platform fees and staker rewards.

We need a trust-minimized on-chain contract that:
1. Receives USDC directly from customer payments (no upstream custodian)
2. Splits each distribution into platform fees (to the 2/2 Safe) and staker rewards (to sDIEM)
3. Can be triggered by anyone without creating operational dependencies
4. Aligns with the 24h streaming window of sDIEM's Synthetix-style rewards

## Non-Goals

- **Not a reward-timing contract**. sDIEM already handles the 24h linear stream. The splitter just forwards.
- **Not a swap router**. USDC stays as USDC all the way through; csDIEM handles USDC→DIEM conversion separately.
- **Not a configurable-ratio contract**. The split is hardcoded 20/80. If the ratio needs to change, redeploy.
- **Not a replacement for DIEMVault**. DIEMVault is for B2B relay deposit settlement, unrelated to cheaptokens.ai revenue.

## Architecture

```
cheaptokens.ai customers (pay USDC on checkout)
           │
           ▼
    RevenueSplitter ──── accumulates USDC
           │
           │ distribute() — permissionless, 23h cooldown, ≥100 USDC floor
           │
   ┌───────┴───────┐
   │ 20%           │ 80% (+ rounding dust)
   ▼               ▼
2/2 Safe       sDIEM.notifyRewardAmount()
(platform)     (streamed 24h to stakers;
                csDIEM harvest pulls from here)
```

**Key observation**: Splitter must be set as sDIEM's `operator` (one-time `setOperator(splitter)` by the sDIEM admin). This is the only function that can call `notifyRewardAmount`.

## Contract Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract RevenueSplitter {
    using SafeERC20 for IERC20;

    // ── Constants ──────────────────────────────────────────────
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PLATFORM_BPS    = 2_000;   // 20%
    uint256 public constant STAKER_BPS      = 8_000;   // 80%
    uint256 public constant MIN_AMOUNT_CAP  = 10_000e6; // admin can't set minAmount absurdly high
    uint256 public constant MAX_COOLDOWN    = 7 days;   // admin can't lock funds forever

    // ── Immutables ─────────────────────────────────────────────
    IERC20 public immutable USDC;
    ISDiem public immutable sdiem;

    // ── State ──────────────────────────────────────────────────
    address public admin;
    address public pendingAdmin;
    address public platformReceiver;   // 2/2 Safe
    uint256 public minAmount;          // default 100 USDC (100e6)
    uint256 public cooldown;           // default 23 hours
    uint256 public lastDistribution;
    bool    public paused;

    // Lifetime counters for indexing/analytics
    uint256 public totalPlatformPaid;
    uint256 public totalStakerPaid;

    // ── Events ─────────────────────────────────────────────────
    event Distributed(
        address indexed caller,
        uint256 platformCut,
        uint256 stakerCut,
        uint256 timestamp
    );
    event PlatformReceiverSet(address indexed newReceiver);
    event MinAmountSet(uint256 newMinAmount);
    event CooldownSet(uint256 newCooldown);
    event Paused(bool paused);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferAccepted(address indexed newAdmin);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ── Core ───────────────────────────────────────────────────
    /**
     * @notice Permissionless distribution. Splits current USDC balance 20/80.
     *         Rounding dust (from integer division) flows to stakers.
     */
    function distribute() external;

    // ── Admin (Safe) ───────────────────────────────────────────
    function setPlatformReceiver(address) external;
    function setMinAmount(uint256) external;   // capped at MIN_AMOUNT_CAP
    function setCooldown(uint256) external;    // capped at MAX_COOLDOWN
    function pause() external;
    function unpause() external;
    function rescueToken(address token, address to, uint256 amount) external; // reverts if token == USDC
    function transferAdmin(address) external;  // 2-step
    function acceptAdmin() external;
}
```

## Core Function: `distribute()`

```solidity
function distribute() external nonReentrant {
    require(!paused, "RS: paused");
    require(block.timestamp >= lastDistribution + cooldown, "RS: cooldown");

    uint256 bal = USDC.balanceOf(address(this));
    require(bal >= minAmount, "RS: below min");

    // Compute split — rounding dust flows to stakers
    uint256 platformCut = (bal * PLATFORM_BPS) / BPS_DENOMINATOR;
    uint256 stakerCut   = bal - platformCut;

    // CEI: effects before interactions
    lastDistribution = block.timestamp;
    totalPlatformPaid += platformCut;
    totalStakerPaid   += stakerCut;

    // Transfer platform share
    USDC.safeTransfer(platformReceiver, platformCut);

    // Approve sDIEM and call notifyRewardAmount (sDIEM pulls via safeTransferFrom)
    USDC.forceApprove(address(sdiem), stakerCut);
    sdiem.notifyRewardAmount(stakerCut);

    emit Distributed(msg.sender, platformCut, stakerCut, block.timestamp);
}
```

## Security Properties

**Conservation invariants**:
- `platformCut + stakerCut == bal` at every `distribute()` call
- `totalPlatformPaid + totalStakerPaid == sum of all distributed USDC` (ignoring USDC donated outside `distribute()` — see below)
- `totalPlatformPaid / (totalPlatformPaid + totalStakerPaid) ≤ 2000/10000 + 1 wei` (platform never exceeds 20%, dust always to stakers)

**Access control**:
- `distribute()`: permissionless (no auth)
- `setPlatformReceiver / setMinAmount / setCooldown / pause / unpause / rescueToken / transferAdmin`: onlyAdmin (Safe)
- `acceptAdmin`: only the address currently set as `pendingAdmin`

**Rug protection**:
- `rescueToken` reverts if `token == USDC` — admin cannot drain customer payments
- `cooldown` capped at `MAX_COOLDOWN = 7 days` — admin cannot indefinitely freeze distribution
- `minAmount` capped at `MIN_AMOUNT_CAP = 10,000 USDC` — admin cannot set it so high that distribution never triggers
- `platformReceiver` cannot be set to `address(0)`

**Reentrancy**:
- `distribute()` uses `nonReentrant` guard
- External calls: USDC.transfer (safe), USDC.forceApprove (safe), sDIEM.notifyRewardAmount (trusted, known contract)

**Pause scope**:
- Only freezes `distribute()`. USDC deposits always succeed (USDC is plain ERC20; we cannot block `transfer` to the splitter).

**Cooldown edge case**:
- First call: `lastDistribution == 0`, so `block.timestamp >= 0 + cooldown` is always true (no issue)

## Data Flow — First Distribution (Today)

1. **Deploy** `RevenueSplitter` with:
   - `USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
   - `sdiem = 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2`
   - `platformReceiver = <2/2 Safe>` (provided at deploy)
   - `admin = <2/2 Safe>`

2. **One-time admin ops on sDIEM** (`0x01Ea...D7C9` calls):
   - `sdiem.setOperator(splitter)` — splitter becomes the sole `notifyRewardAmount` caller

3. **atd redirects cheaptokens.ai checkout** to pay USDC directly to splitter address

4. **Customers pay** → splitter balance grows

5. **First `distribute()`** (anyone calls) once balance ≥ 100 USDC:
   - 20% → Safe
   - 80% → sDIEM, streamed over 24h
   - `lastDistribution = block.timestamp`

6. Subsequent `distribute()` calls every ≥23h with accumulated revenue

## Testing Plan (invariant-first, per project rule)

### Invariants (property tests with fuzzing)

1. **Conservation**: After any `distribute()`, the contract's USDC balance decreases by exactly the sum of platform and staker transfers (no stuck funds).
2. **Ratio bound**: `totalPlatformPaid * 10000 <= totalPlatformPaid + totalStakerPaid) * 2000 + n` where `n` is the number of distributions (1 wei dust per call tolerance).
3. **Dust direction**: `stakerCut >= (bal * 8000) / 10000` always (stakers never get less than 80%, can get more by 1 wei from rounding).
4. **Admin cannot drain USDC**: For any sequence of admin operations followed by `rescueToken(USDC, ...)`, the call reverts.

### Lifecycle tests

1. **Happy path**: Deploy → receive 1,000 USDC → `distribute()` → verify Safe got 200, sDIEM got 800, events emitted, `lastDistribution` set.
2. **Cooldown gate**: First `distribute()` succeeds → receive more → second `distribute()` reverts with "cooldown" → advance 23h → succeeds.
3. **MinAmount gate**: Balance 50 USDC (min is 100) → `distribute()` reverts with "below min" → receive 60 more → succeeds.
4. **Pause flow**: `pause()` → `distribute()` reverts → USDC still arrives → `unpause()` → distribute works.
5. **Admin handoff**: Current admin `transferAdmin(newAdmin)` → `pendingAdmin` set → old admin still active → `newAdmin.acceptAdmin()` → newAdmin active.
6. **Rescue accidental ETH/tokens**: Send some random ERC20 to splitter → `rescueToken(randomToken, safe, amount)` → succeeds. Attempt same with USDC → reverts.

### Access control tests

- `setPlatformReceiver`, `setMinAmount`, `setCooldown`, `pause`, `unpause`, `rescueToken`, `transferAdmin` all revert for non-admin callers.
- `acceptAdmin` reverts if called by anyone other than `pendingAdmin`.

### Integration (fork) tests

- **Fork Base mainnet** at a recent block.
- Deploy splitter with real USDC + real sDIEM.
- Impersonate sDIEM admin → `setOperator(splitter)`.
- Send USDC to splitter.
- Call `distribute()`.
- Verify:
  - `Safe.balance()` increased by `platformCut`
  - `sdiem.rewardRate()` increased (confirming `notifyRewardAmount` landed)
  - A real sDIEM staker address accrues `earned()` over time

## Deployment Plan (Today)

1. Write contract + tests (invariant-first)
2. Run full test suite including fork tests — 100% pass required
3. Run `/solidity-auditor` over the contract
4. Get Safe address from user
5. Deploy to Base via `forge script` (use existing deployer pattern)
6. Verify on Basescan
7. Set as sDIEM operator via admin Safe tx (`0x01Ea...D7C9`)
8. Hand splitter address to atd for checkout redirect
9. Wait for first USDC to arrive
10. Call `distribute()` (permissionlessly) and verify on-chain

## Decisions Locked

| Decision | Choice | Rationale |
|---|---|---|
| Split ratio | 20% / 80% (fixed) | Standard DeFi fee split, generous to users, avoids configurable-param attack surface |
| Ratio mutability | Constants (redeploy to change) | Simpler, auditable, users can verify code = rate |
| Trigger mechanism | Permissionless with 23h cooldown + 100 USDC floor | No keeper fees, no manual ops, cooldown prevents stream fragmentation |
| Rounding dust | To stakers | Better for UX, admin can't game dust |
| Pause scope | `distribute()` only | USDC is plain ERC20, can't block receives anyway |
| Payment path | Direct — customers pay splitter | Non-custodial, no trust in upstream wallet |
| Admin | 2/2 Safe (both admin + platformReceiver) | Matches existing protocol pattern |
| Admin handoff | 2-step `transferAdmin` + `acceptAdmin` | Prevents accidentally locking to wrong address |

## Open Items

- **Safe address** to be provided at deploy time by user
- **sDIEM operator swap**: need to coordinate with sDIEM admin (`0x01Ea...D7C9`) to call `setOperator(splitter)` after deploy
- **cheaptokens.ai checkout update**: atd must update the payment address to splitter after deploy
