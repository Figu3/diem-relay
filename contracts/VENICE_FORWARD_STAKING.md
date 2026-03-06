# Venice Forward-Staking: Design Document

## Problem

sDIEM and csDIEM accept user DIEM deposits, but the tokens sit **idle**. The relay operator needs DIEM **staked on Venice** (via the DIEM token contract) to receive daily compute credits ($1/day per staked DIEM). Without forward-staking, we have no Venice compute to sell, which means no revenue, which means no staker rewards.

## On-Chain DIEM Staking Interface (Reverse-Engineered)

Contract: `0xf4d97f2da56e8c3098f3a8d538db630a2606a024` (Base)

```
stake(uint256 amount)         — locks DIEM, tracked in stakedInfos
initiateUnstake(uint256 amt)  — starts 24h cooldown
unstake()                     — after cooldown, returns DIEM
cooldownDuration()            — 86400 (24 hours)
stakedInfos(address)          — returns (stakedAmount, cooldownEndTimestamp, pendingUnstakeAmount)
totalStaked()                 — ~28,530 DIEM currently staked
```

**Critical finding: No EOA restriction on `stake()`.** Smart contracts can call it.

The DIEM staking mechanism transfers tokens into the DIEM contract's own `balanceOf` and tracks amounts internally. Unstaking is **two-step**: `initiateUnstake(amount)` → wait 24h → `unstake()`.

## Revenue Flow (Target Architecture)

```
Users deposit DIEM → sDIEM/csDIEM
                          │
                    forward-stake via DIEM.stake()
                          │
                    Venice sees on-chain stake
                          │
                    allocates $X/day compute credits
                          │
                    relay operator uses compute
                          │
                    borrowers pay USDC for inference
                          │
              ┌───────────┴───────────┐
              │                       │
         sDIEM stakers           csDIEM stakers
         receive USDC            operator buys DIEM
         (Synthetix stream)      and calls donate()
```

## Design: Hybrid Buffer Model

### Core Concept

Each contract (sDIEM and csDIEM) maintains a **liquidity buffer** — a percentage of total deposits kept un-staked for instant withdrawals. The rest is forward-staked on Venice.

```
totalDeposits = liquidBuffer + forwardStaked + pendingUnstake

liquidBuffer    = DIEM.balanceOf(address(this))         — available for instant withdrawals
forwardStaked   = DIEM.stakedInfos(this).stakedAmount   — earning Venice compute
pendingUnstake  = DIEM.stakedInfos(this).pendingAmount  — in 24h cooldown
```

### Buffer Parameters

```solidity
uint256 public constant BUFFER_TARGET_BPS = 1000;  // 10% target
uint256 public constant BUFFER_FLOOR_BPS  = 500;   // 5% — trigger replenish
uint256 public constant BUFFER_CEIL_BPS   = 1500;  // 15% — trigger deploy
uint256 public constant BPS = 10000;
```

### Who Manages the Buffer?

The **operator** (off-chain keeper). Reasons:
- `initiateUnstake()` and `unstake()` on the DIEM contract interact with per-address state
- Cooldown timing is asynchronous (24h wait)
- Only one unstake can be in-flight at a time per address (DIEM contract limitation)
- Automated keeper can monitor buffer and rebalance on a schedule

The operator calls:
1. `deployToVenice(amount)` — forward-stake excess buffer
2. `initiateBufferReplenish(amount)` — start unstaking from Venice
3. `completeBufferReplenish()` — finalize unstake after cooldown

Users can always withdraw up to the liquid buffer instantly. If buffer is insufficient, they must wait for operator to replenish (or use a withdrawal queue).

---

## Contract Modifications

### New Interface: IDIEMStaking

```solidity
interface IDIEMStaking {
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    function cooldownDuration() external view returns (uint256);
    function stakedInfos(address) external view returns (
        uint256 stakedAmount,
        uint256 cooldownEndTimestamp,
        uint256 pendingUnstakeAmount
    );
    function totalStaked() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (uint256);
}
```

### sDIEM v2 — Changes

```diff
 contract sDIEM is IsDIEM, ReentrancyGuard {
+    IDIEMStaking public immutable diemStaking;  // = DIEM token (staking is built-in)
+
+    // ── Buffer state ──────────────────────────────────────────────────
+    uint256 public constant BUFFER_TARGET_BPS = 1000;
+    uint256 public constant BUFFER_FLOOR_BPS  = 500;
+    uint256 public constant BPS = 10000;

     // ── Views ──────────────────────────────────────────────────────────
+    function liquidBuffer() public view returns (uint256) {
+        return diem.balanceOf(address(this));
+    }
+
+    function forwardStaked() public view returns (uint256) {
+        (uint256 staked,,) = diemStaking.stakedInfos(address(this));
+        return staked;
+    }
+
+    function pendingUnstake() public view returns (uint256) {
+        (,,uint256 pending) = diemStaking.stakedInfos(address(this));
+        return pending;
+    }

     // ── Mutative — staking ─────────────────────────────────────────────
     function stake(uint256 amount) external ... {
         require(amount > 0, "sDIEM: zero amount");
         totalStaked += amount;
         _balances[msg.sender] += amount;
         diem.safeTransferFrom(msg.sender, address(this), amount);
         emit Staked(msg.sender, amount);
+        // Note: tokens sit in buffer until operator calls deployToVenice()
     }

     function _withdraw(address user, uint256 amount) internal {
         require(amount > 0, "sDIEM: zero amount");
         require(_balances[user] >= amount, "sDIEM: insufficient balance");
+        require(diem.balanceOf(address(this)) >= amount, "sDIEM: buffer insufficient");
         totalStaked -= amount;
         _balances[user] -= amount;
         diem.safeTransfer(user, amount);
         emit Withdrawn(user, amount);
     }

+    // ── Operator — Venice forward-staking ────────────────────────────
+    function deployToVenice(uint256 amount) external onlyOperator {
+        require(amount > 0, "sDIEM: zero amount");
+        uint256 bufferAfter = diem.balanceOf(address(this)) - amount;
+        require(bufferAfter >= (totalStaked * BUFFER_FLOOR_BPS) / BPS,
+                "sDIEM: would breach buffer floor");
+        diemStaking.stake(amount);
+        emit DeployedToVenice(amount);
+    }
+
+    function initiateBufferReplenish(uint256 amount) external onlyOperator {
+        require(amount > 0, "sDIEM: zero amount");
+        diemStaking.initiateUnstake(amount);
+        emit BufferReplenishInitiated(amount);
+    }
+
+    function completeBufferReplenish() external onlyOperator {
+        diemStaking.unstake();
+        emit BufferReplenishCompleted(diem.balanceOf(address(this)));
+    }
 }
```

### csDIEM v2 — Changes

Very similar to sDIEM, but using ERC-4626 hooks:

```diff
 contract csDIEM is ERC4626, IcsDIEM {
+    IDIEMStaking public immutable diemStaking;
+    uint256 public constant BUFFER_TARGET_BPS = 1000;
+    uint256 public constant BUFFER_FLOOR_BPS  = 500;
+    uint256 public constant BPS = 10000;

+    // ── Views ──────────────────────────────────────────────────────────
+    function liquidBuffer() public view returns (uint256) {
+        return IERC20(asset()).balanceOf(address(this));
+    }
+
+    function forwardStaked() public view returns (uint256) {
+        (uint256 staked,,) = diemStaking.stakedInfos(address(this));
+        return staked;
+    }

     // ── ERC-4626 overrides ──────────────────────────────────────────────

+    /// @dev Override totalAssets to include forward-staked DIEM.
+    /// Without this, share price would drop when tokens are deployed to Venice.
+    function totalAssets() public view override returns (uint256) {
+        (uint256 staked,, uint256 pending) = diemStaking.stakedInfos(address(this));
+        return IERC20(asset()).balanceOf(address(this)) + staked + pending;
+    }

     function _deposit(...) internal override whenNotPaused {
         super._deposit(caller, receiver, assets, shares);
+        // Tokens sit in buffer until operator deploys
     }

+    /// @dev Gate withdrawals to liquid buffer.
+    function _withdraw(
+        address caller, address receiver, address owner,
+        uint256 assets, uint256 shares
+    ) internal override {
+        require(IERC20(asset()).balanceOf(address(this)) >= assets,
+                "csDIEM: buffer insufficient");
+        super._withdraw(caller, receiver, owner, assets, shares);
+    }

+    // ── Operator — Venice forward-staking ────────────────────────────
+    function deployToVenice(uint256 amount) external onlyOperator { ... }
+    function initiateBufferReplenish(uint256 amount) external onlyOperator { ... }
+    function completeBufferReplenish() external onlyOperator { ... }
 }
```

### Critical: csDIEM `totalAssets()` Override

This is the **most important change** for csDIEM. Without it:

1. Operator deploys 90% of DIEM to Venice
2. `totalAssets()` only counts `balanceOf(address(this))` → drops to 10%
3. Share price collapses (shares backed by much less)
4. Users lose value on paper

With the override, `totalAssets()` = `liquidBuffer + forwardStaked + pendingUnstake`, so share price stays accurate regardless of how much is deployed.

sDIEM doesn't have this problem because it tracks `totalStaked` independently (Synthetix model).

---

## Withdrawal UX

### Happy Path (buffer sufficient)
```
User calls withdraw(1000 DIEM)
→ Contract checks: liquidBuffer >= 1000? Yes
→ Instant transfer. Done.
```

### Degraded Path (buffer insufficient)
```
User calls withdraw(5000 DIEM) but buffer = 2000
→ Revert: "sDIEM: buffer insufficient"
→ Frontend shows: "Only 2,000 DIEM available for instant withdrawal.
   Withdraw up to 2,000 now, or wait ~24h for buffer replenishment."
→ Operator is alerted, calls initiateBufferReplenish()
→ 24h later, operator calls completeBufferReplenish()
→ User can now withdraw
```

### Future Enhancement: Withdrawal Queue
```solidity
struct WithdrawalRequest {
    address user;
    uint256 amount;
    uint256 requestedAt;
}
WithdrawalRequest[] public withdrawalQueue;

function requestWithdrawal(uint256 amount) external {
    // Lock shares, add to queue
    // Operator processes queue when buffer is replenished
}
```

This is a **v2 enhancement** — start with the simpler buffer model first.

---

## Operator Keeper Bot

The operator runs a keeper bot that:

1. **Every hour**: Check buffer levels
   - If buffer < 5% of totalDeposits → `initiateBufferReplenish(replenishAmount)`
   - If buffer > 15% of totalDeposits → `deployToVenice(excessAmount)`

2. **After cooldown expires**: Call `completeBufferReplenish()`

3. **Daily**: Collect Venice revenue
   - For sDIEM: Convert to USDC, call `notifyRewardAmount()`
   - For csDIEM: Buy DIEM with USDC, call `donate()`

```typescript
// Pseudocode for keeper
async function checkBuffer(contract: sDIEM | csDIEM) {
    const total = await contract.totalStaked();  // or totalAssets()
    const buffer = await contract.liquidBuffer();
    const ratio = buffer * 10000n / total;

    if (ratio < 500n) {
        // Below floor — need to replenish
        const target = total * 1000n / 10000n;  // 10%
        const replenish = target - buffer;
        await contract.initiateBufferReplenish(replenish);
    } else if (ratio > 1500n) {
        // Above ceiling — deploy excess
        const target = total * 1000n / 10000n;
        const excess = buffer - target;
        await contract.deployToVenice(excess);
    }
}
```

---

## Edge Cases

### 1. First Deposit (Cold Start)
No forward-staking until operator deploys. First deposits sit in buffer.

### 2. Mass Withdrawal (Bank Run)
If all users withdraw simultaneously:
- Buffer covers first 10%
- Remaining 90% requires 24h unstaking cooldown
- Users must wait or withdraw in waves
- **Mitigation**: Operator can `initiateUnstake(totalForwardStaked)` to start unstaking everything

### 3. Only One Unstake In-Flight
The DIEM contract appears to allow only one pending unstake per address (the `pendingUnstakeAmount` accumulates, but `cooldownEndTimestamp` resets on each `initiateUnstake()` call). This means:
- If operator initiates unstake for 1000, then initiates another for 500, the cooldown timer **resets** for the combined 1500
- Operator should batch unstake requests rather than doing them incrementally

### 4. Paused DIEM Staking
If DIEM contract pauses staking (unlikely but possible):
- `deployToVenice()` would revert
- Buffer stays at 100% — contracts work normally but earn no Venice compute
- Withdrawals unaffected

### 5. csDIEM Donation During Forward-Stake
When operator calls `csDIEM.donate(amount)`:
- DIEM is pulled from operator to csDIEM contract
- Increases `balanceOf(address(this))` (liquid buffer goes up)
- `totalAssets()` goes up → share price increases
- The donated DIEM can then be deployed to Venice in next rebalance

---

## DIEM Token Approval

Before `deployToVenice()` works, the contract must approve the DIEM token contract to spend its DIEM. Since `stake()` does an internal `balanceOf` transfer (not a `transferFrom`), we need to check whether approval is needed.

From the decompiled source: `stake()` does:
```
balanceOf[msg.sender] -= amount
balanceOf[address(this)] += amount
```

This is an **internal balance adjustment**, NOT a `transferFrom`. So the DIEM token contract modifies its own storage for `msg.sender` (our contract). **No approval needed.** The DIEM contract trusts the `stake()` caller to have the balance.

---

## Security Considerations

1. **Buffer floor enforcement**: `deployToVenice()` enforces a minimum buffer, preventing operator from over-deploying
2. **No user funds at operator risk**: Operator can only move funds between Venice staking and buffer — never to external addresses
3. **totalAssets accuracy**: csDIEM share price always reflects true total (buffer + staked + pending)
4. **Withdrawal always allowed**: Even if paused, users can withdraw from buffer (same as current design)
5. **Reentrancy**: DIEM.stake() and DIEM.unstake() are external calls — ensure CEI pattern
6. **Single pending unstake**: Operator must be careful about re-initiating unstakes (resets cooldown)

---

## Implementation Plan

### Phase 1: Interface + Modified Contracts
1. Create `IDIEMStaking.sol` interface
2. Modify `sDIEM.sol` — add buffer management + forward-staking
3. Modify `csDIEM.sol` — add buffer management + `totalAssets()` override
4. Update interfaces `IsDIEM.sol` and `IcsDIEM.sol`

### Phase 2: Tests
5. Unit tests for buffer management
6. Unit tests for forward-staking flow
7. Fuzz tests for buffer invariants
8. Integration tests with mock DIEM staking contract
9. Invariant: `liquidBuffer + forwardStaked + pending == totalDeposits`

### Phase 3: Keeper Bot
10. Buffer monitoring script
11. Auto-rebalance logic
12. Cooldown tracking
13. Alert system for low buffer

### Phase 4: Frontend Updates
14. Show buffer level on vault cards
15. Show forward-staked amount
16. Warn users when buffer is low
17. Show estimated wait time if buffer insufficient

---

## Open Questions

1. **Venice API key linkage**: How does Venice associate our contract's on-chain stake with the relay operator's API key? Need to verify this works with smart contract addresses as stakers.

2. **Multiple contracts staking**: Can both sDIEM and csDIEM forward-stake independently? Each would be a separate address with separate `stakedInfos`. Venice should allocate compute credits to each. Relay operator would need both contract addresses linked to their account.

3. **Unstake accumulation**: Does calling `initiateUnstake()` multiple times accumulate `pendingUnstakeAmount` and reset the cooldown? Or does it revert if there's already a pending unstake? From decompiled source, it appears to **accumulate and reset** — which means the operator should batch unstake requests.

4. **Buffer BPS governance**: Should buffer target/floor/ceiling be configurable by admin? Probably yes for v2, but hard-code constants for v1 to reduce attack surface.
