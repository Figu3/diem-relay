# RevenueSplitter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, test, and deploy a permissionless `RevenueSplitter` contract on Base that receives USDC from cheaptokens.ai customers, splits each distribution 20% to the 2/2 Safe and 80% to sDIEM stakers via `notifyRewardAmount()`, enabling the first distribution today.

**Architecture:** Stateless pass-through splitter with immutable USDC + sDIEM addresses. Customers pay the contract directly. Permissionless `distribute()` trigger with 23h cooldown and 100 USDC minimum prevents stream fragmentation. Safe admin can rotate `platformReceiver`, pause, and rescue non-USDC tokens; cannot drain customer payments (USDC is hard-blocked from rescue). Splitter replaces the Safe as sDIEM's Operator via a one-time 2/2 tx post-deploy.

**Tech Stack:** Solidity 0.8.24, Foundry, OpenZeppelin (SafeERC20, ReentrancyGuard), existing `IsDIEM` interface, Base chain.

**Spec reference:** `docs/superpowers/specs/2026-04-14-revenue-splitter-design.md`

---

## File Structure

Files to create:
- `contracts/src/RevenueSplitter.sol` — main contract (~180 lines)
- `contracts/src/interfaces/IRevenueSplitter.sol` — external interface
- `contracts/test/RevenueSplitter.t.sol` — unit + fuzz tests
- `contracts/test/RevenueSplitterInvariant.t.sol` — invariant tests
- `contracts/test/RevenueSplitterFork.t.sol` — Base-fork integration test against real sDIEM + USDC
- `contracts/script/DeployRevenueSplitter.s.sol` — deployment script

Files to modify: none (contract is a new addition, no existing file touches).

Each file has one clear responsibility. Test files split by type (unit / invariant / fork) so each is short and focused.

---

## Task 1: Scaffold interface and empty contract

**Files:**
- Create: `contracts/src/interfaces/IRevenueSplitter.sol`
- Create: `contracts/src/RevenueSplitter.sol`

- [ ] **Step 1: Write the interface**

Create `contracts/src/interfaces/IRevenueSplitter.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsDIEM} from "./IsDIEM.sol";

/**
 * @title IRevenueSplitter
 * @notice Receives USDC revenue from cheaptokens.ai customers and distributes
 *         it 20% to a platform Safe and 80% to sDIEM stakers via
 *         notifyRewardAmount. Permissionless trigger with cooldown.
 */
interface IRevenueSplitter {
    // ── Events ──────────────────────────────────────────────────────────────
    event Distributed(
        address indexed caller,
        uint256 platformCut,
        uint256 stakerCut,
        uint256 timestamp
    );
    event PlatformReceiverSet(address indexed newReceiver);
    event MinAmountSet(uint256 newMinAmount);
    event CooldownSet(uint256 newCooldown);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferAccepted(address indexed newAdmin);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ── Views ───────────────────────────────────────────────────────────────
    function USDC() external view returns (IERC20);
    function sdiem() external view returns (IsDIEM);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function platformReceiver() external view returns (address);
    function minAmount() external view returns (uint256);
    function cooldown() external view returns (uint256);
    function lastDistribution() external view returns (uint256);
    function paused() external view returns (bool);
    function totalPlatformPaid() external view returns (uint256);
    function totalStakerPaid() external view returns (uint256);

    // ── Core ────────────────────────────────────────────────────────────────
    function distribute() external;

    // ── Admin ───────────────────────────────────────────────────────────────
    function setPlatformReceiver(address newReceiver) external;
    function setMinAmount(uint256 newMinAmount) external;
    function setCooldown(uint256 newCooldown) external;
    function pause() external;
    function unpause() external;
    function rescueToken(address token, address to, uint256 amount) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
}
```

- [ ] **Step 2: Write empty contract skeleton**

Create `contracts/src/RevenueSplitter.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRevenueSplitter} from "./interfaces/IRevenueSplitter.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";

/**
 * @title RevenueSplitter
 * @notice 20/80 USDC revenue splitter for DIEM ecosystem.
 *         Platform fees → 2/2 Safe, staker rewards → sDIEM.notifyRewardAmount.
 *         Permissionless distribute() with 23h cooldown + min amount floor.
 *
 * Security:
 *   - Immutable USDC and sDIEM addresses.
 *   - Admin cannot rescue USDC (non-rug by design).
 *   - Admin config bounds (cooldown ≤ 7 days, minAmount ≤ 10,000 USDC).
 *   - CEI pattern on distribute().
 *   - ReentrancyGuard on distribute().
 *   - 2-step admin transfer.
 */
contract RevenueSplitter is IRevenueSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ───────────────────────────────────────────────────────────
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PLATFORM_BPS = 2_000;         // 20%
    uint256 public constant STAKER_BPS = 8_000;           // 80%
    uint256 public constant MIN_AMOUNT_CAP = 10_000e6;    // 10,000 USDC (6 decimals)
    uint256 public constant MAX_COOLDOWN = 7 days;
    uint256 public constant DEFAULT_MIN_AMOUNT = 100e6;   // 100 USDC
    uint256 public constant DEFAULT_COOLDOWN = 23 hours;

    // ── Immutables ──────────────────────────────────────────────────────────
    IERC20 public immutable override USDC;
    IsDIEM public immutable override sdiem;

    // ── State ───────────────────────────────────────────────────────────────
    address public override admin;
    address public override pendingAdmin;
    address public override platformReceiver;
    uint256 public override minAmount;
    uint256 public override cooldown;
    uint256 public override lastDistribution;
    bool public override paused;

    uint256 public override totalPlatformPaid;
    uint256 public override totalStakerPaid;

    // ── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyAdmin() {
        require(msg.sender == admin, "RS: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "RS: paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor(
        IERC20 _usdc,
        IsDIEM _sdiem,
        address _admin,
        address _platformReceiver
    ) {
        require(address(_usdc) != address(0), "RS: zero usdc");
        require(address(_sdiem) != address(0), "RS: zero sdiem");
        require(_admin != address(0), "RS: zero admin");
        require(_platformReceiver != address(0), "RS: zero receiver");

        USDC = _usdc;
        sdiem = _sdiem;
        admin = _admin;
        platformReceiver = _platformReceiver;
        minAmount = DEFAULT_MIN_AMOUNT;
        cooldown = DEFAULT_COOLDOWN;
    }

    // Implementations added in later tasks (each TDD-driven).
}
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
cd contracts && forge build --use 0.8.24 2>&1 | tail -20
```

Expected: compiles cleanly (may report unimplemented functions — that's fine since the interface methods will be added task-by-task). If "function not implemented" errors appear, add stubs that `revert("RS: not implemented");` for each interface method to keep the compiler happy.

- [ ] **Step 4: Commit**

```bash
cd /Users/figue/Desktop/Vibe\ Coding/DeFi/_active/diem-lending
git add contracts/src/RevenueSplitter.sol contracts/src/interfaces/IRevenueSplitter.sol
git commit -m "feat(splitter): scaffold RevenueSplitter contract + interface"
```

---

## Task 2: Write invariant-first tests (before implementation)

**Files:**
- Create: `contracts/test/RevenueSplitterInvariant.t.sol`

Per project rule: **invariant tests BEFORE implementation**. These express what the contract must guarantee.

- [ ] **Step 1: Write invariant test file**

Create `contracts/test/RevenueSplitterInvariant.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSDiem} from "./mocks/MockSDiem.sol";

/**
 * Invariant tests for RevenueSplitter.
 *
 * Properties:
 *   I1: After distribute(), USDC balance drops by exactly platformCut + stakerCut.
 *   I2: totalPlatformPaid / (totalPlatformPaid + totalStakerPaid) <= 2000/10000 at all times.
 *   I3: stakerCut per distribution >= (balanceAtCall * 8000) / 10000 (stakers never get less).
 *   I4: rescueToken can never remove USDC from the contract.
 */
contract RevenueSplitterInvariantTest is Test {
    RevenueSplitter internal splitter;
    MockERC20 internal usdc;
    MockSDiem internal sdiem;

    address internal admin = address(0xA11CE);
    address internal receiver = address(0xB0B);

    uint256 internal initialUsdcSnapshot;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        sdiem = new MockSDiem(usdc);
        splitter = new RevenueSplitter(usdc, sdiem, admin, receiver);

        // Hand operator role to splitter on mock sdiem
        sdiem.setOperator(address(splitter));

        // Seed contract with revenue
        usdc.mint(address(splitter), 10_000e6);

        targetContract(address(splitter));
    }

    // ── Invariant I2: platform share never exceeds 20% ────────────────────
    function invariant_platformShareCap() public view {
        uint256 total = splitter.totalPlatformPaid() + splitter.totalStakerPaid();
        if (total == 0) return;
        // platformPaid * 10000 <= total * 2000 (i.e. share <= 20%)
        assertLe(
            splitter.totalPlatformPaid() * 10_000,
            total * 2_000,
            "I2: platform share > 20%"
        );
    }

    // ── Invariant I4: USDC never drainable by admin ───────────────────────
    function invariant_usdcNotRescuable() public {
        // Direct call must revert even if admin tries
        vm.prank(admin);
        vm.expectRevert();
        splitter.rescueToken(address(usdc), admin, 1);
    }
}
```

- [ ] **Step 2: Write mocks (MockERC20, MockSDiem)**

Check if `contracts/test/mocks/MockERC20.sol` already exists:

```bash
ls contracts/test/mocks/
```

If MockERC20 exists, reuse it. Otherwise, create a minimal ERC20 mock with `mint()` for tests.

Create `contracts/test/mocks/MockSDiem.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Minimal sDIEM mock that matches IsDIEM.notifyRewardAmount behavior:
 * pulls USDC from msg.sender via safeTransferFrom, only operator can call.
 */
contract MockSDiem {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public operator;
    uint256 public totalNotified;
    uint256 public rewardRate;
    uint256 public periodFinish;

    uint256 public constant REWARDS_DURATION = 1 days;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
        operator = msg.sender;
    }

    function setOperator(address _op) external {
        operator = _op;
    }

    function notifyRewardAmount(uint256 reward) external {
        require(msg.sender == operator, "MockSDiem: not operator");
        usdc.safeTransferFrom(msg.sender, address(this), reward);
        totalNotified += reward;
        rewardRate = reward / REWARDS_DURATION;
        periodFinish = block.timestamp + REWARDS_DURATION;
    }
}
```

- [ ] **Step 3: Try to run invariant tests**

```bash
cd contracts && forge test --match-contract RevenueSplitterInvariant -vv 2>&1 | tail -30
```

Expected: invariants don't run yet because `distribute()` reverts with "not implemented" (fuzzer never successfully calls it), OR they pass trivially with 0 distributions. Either outcome is OK — we're establishing the tests first. Proceed to Task 3 to implement `distribute()`.

- [ ] **Step 4: Commit**

```bash
git add contracts/test/RevenueSplitterInvariant.t.sol contracts/test/mocks/MockSDiem.sol
[ -e contracts/test/mocks/MockERC20.sol ] && git add contracts/test/mocks/MockERC20.sol
git commit -m "test(splitter): invariant tests for platform cap and USDC non-rescuability"
```

---

## Task 3: Implement `distribute()` with TDD

**Files:**
- Create: `contracts/test/RevenueSplitter.t.sol`
- Modify: `contracts/src/RevenueSplitter.sol`

- [ ] **Step 1: Write failing happy-path test**

Create `contracts/test/RevenueSplitter.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IRevenueSplitter} from "../src/interfaces/IRevenueSplitter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSDiem} from "./mocks/MockSDiem.sol";

contract RevenueSplitterTest is Test {
    RevenueSplitter internal splitter;
    MockERC20 internal usdc;
    MockSDiem internal sdiem;

    address internal admin = address(0xA11CE);
    address internal receiver = address(0xB0B);
    address internal anyone = address(0xCAFE);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        sdiem = new MockSDiem(usdc);
        splitter = new RevenueSplitter(usdc, sdiem, admin, receiver);
        sdiem.setOperator(address(splitter));
    }

    function test_distribute_splits20_80() public {
        usdc.mint(address(splitter), 1_000e6);

        vm.prank(anyone);
        splitter.distribute();

        assertEq(usdc.balanceOf(receiver), 200e6, "platform cut");
        assertEq(sdiem.totalNotified(), 800e6, "staker cut");
        assertEq(usdc.balanceOf(address(splitter)), 0, "no dust");
        assertEq(splitter.lastDistribution(), block.timestamp, "timestamp");
        assertEq(splitter.totalPlatformPaid(), 200e6);
        assertEq(splitter.totalStakerPaid(), 800e6);
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

```bash
forge test --match-test test_distribute_splits20_80 -vv
```

Expected: FAIL — function not implemented or reverts.

- [ ] **Step 3: Implement `distribute()`**

In `contracts/src/RevenueSplitter.sol`, add (before closing brace):

```solidity
    // ── Core ────────────────────────────────────────────────────────────────
    function distribute() external override nonReentrant whenNotPaused {
        require(block.timestamp >= lastDistribution + cooldown, "RS: cooldown");

        uint256 bal = USDC.balanceOf(address(this));
        require(bal >= minAmount, "RS: below min");

        uint256 platformCut = (bal * PLATFORM_BPS) / BPS_DENOMINATOR;
        uint256 stakerCut = bal - platformCut;

        // Effects
        lastDistribution = block.timestamp;
        totalPlatformPaid += platformCut;
        totalStakerPaid += stakerCut;

        // Interactions
        USDC.safeTransfer(platformReceiver, platformCut);
        USDC.forceApprove(address(sdiem), stakerCut);
        sdiem.notifyRewardAmount(stakerCut);

        emit Distributed(msg.sender, platformCut, stakerCut, block.timestamp);
    }
```

- [ ] **Step 4: Run test, verify it passes**

```bash
forge test --match-test test_distribute_splits20_80 -vv
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "feat(splitter): implement distribute() with 20/80 split"
```

---

## Task 4: Cooldown gate

**Files:**
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing cooldown test**

Append to `RevenueSplitterTest`:

```solidity
    function test_distribute_revertsDuringCooldown() public {
        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();

        // Second distribution immediately → revert
        usdc.mint(address(splitter), 1_000e6);
        vm.expectRevert(bytes("RS: cooldown"));
        splitter.distribute();

        // Warp past cooldown → succeeds
        vm.warp(block.timestamp + 23 hours);
        splitter.distribute();
        assertEq(splitter.totalPlatformPaid(), 400e6);
    }

    function test_distribute_firstCallHasNoCooldown() public {
        // lastDistribution == 0 initially, so first call should work
        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();
        assertGt(splitter.totalPlatformPaid(), 0);
    }
```

- [ ] **Step 2: Run tests**

```bash
forge test --match-test "test_distribute_revertsDuringCooldown|test_distribute_firstCallHasNoCooldown" -vv
```

Expected: both PASS (distribute() already implements cooldown in Task 3).

- [ ] **Step 3: Commit**

```bash
git add contracts/test/RevenueSplitter.t.sol
git commit -m "test(splitter): cooldown gate covered"
```

---

## Task 5: MinAmount gate + rounding dust direction

**Files:**
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing tests**

Append:

```solidity
    function test_distribute_revertsBelowMinAmount() public {
        usdc.mint(address(splitter), 50e6); // default min is 100 USDC
        vm.expectRevert(bytes("RS: below min"));
        splitter.distribute();
    }

    function test_distribute_roundingDustGoesToStakers() public {
        // Use a balance that doesn't divide evenly by 10000
        // 1000.000001 USDC = 1_000_000_001
        usdc.mint(address(splitter), 1_000_000_001);
        splitter.distribute();

        // platformCut = (1_000_000_001 * 2000) / 10000 = 200_000_000 (truncated)
        // stakerCut  = 1_000_000_001 - 200_000_000 = 800_000_001 (gets the dust)
        assertEq(usdc.balanceOf(receiver), 200_000_000, "platform truncated");
        assertEq(sdiem.totalNotified(), 800_000_001, "staker gets dust");
    }
```

- [ ] **Step 2: Run tests**

```bash
forge test --match-test "test_distribute_revertsBelowMinAmount|test_distribute_roundingDustGoesToStakers" -vv
```

Expected: both PASS.

- [ ] **Step 3: Commit**

```bash
git add contracts/test/RevenueSplitter.t.sol
git commit -m "test(splitter): minAmount gate + dust-to-stakers coverage"
```

---

## Task 6: Pause / unpause

**Files:**
- Modify: `contracts/src/RevenueSplitter.sol`
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing pause tests**

Append to `RevenueSplitterTest`:

```solidity
    function test_pause_blocksDistribute() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.prank(admin);
        splitter.pause();

        vm.expectRevert(bytes("RS: paused"));
        splitter.distribute();
    }

    function test_unpause_restoresDistribute() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.startPrank(admin);
        splitter.pause();
        splitter.unpause();
        vm.stopPrank();

        splitter.distribute();
        assertEq(usdc.balanceOf(receiver), 200e6);
    }

    function test_pause_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.pause();
    }
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
forge test --match-test "test_pause_blocksDistribute|test_unpause_restoresDistribute|test_pause_revertsForNonAdmin" -vv
```

Expected: FAIL — functions don't exist yet.

- [ ] **Step 3: Implement pause/unpause**

In `RevenueSplitter.sol`, add:

```solidity
    // ── Admin — pause ───────────────────────────────────────────────────────
    function pause() external override onlyAdmin {
        require(!paused, "RS: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyAdmin {
        require(paused, "RS: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }
```

- [ ] **Step 4: Run tests**

```bash
forge test --match-test "test_pause" -vv
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "feat(splitter): pause/unpause (admin-only)"
```

---

## Task 7: Admin config setters (setPlatformReceiver, setMinAmount, setCooldown)

**Files:**
- Modify: `contracts/src/RevenueSplitter.sol`
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing tests**

Append:

```solidity
    function test_setPlatformReceiver_worksForAdmin() public {
        address newReceiver = address(0xFEED);
        vm.prank(admin);
        splitter.setPlatformReceiver(newReceiver);
        assertEq(splitter.platformReceiver(), newReceiver);
    }

    function test_setPlatformReceiver_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.setPlatformReceiver(address(0xFEED));
    }

    function test_setPlatformReceiver_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("RS: zero receiver"));
        splitter.setPlatformReceiver(address(0));
    }

    function test_setMinAmount_bounded() public {
        vm.prank(admin);
        splitter.setMinAmount(500e6);
        assertEq(splitter.minAmount(), 500e6);

        vm.prank(admin);
        vm.expectRevert(bytes("RS: min too high"));
        splitter.setMinAmount(20_000e6); // exceeds MIN_AMOUNT_CAP
    }

    function test_setCooldown_bounded() public {
        vm.prank(admin);
        splitter.setCooldown(12 hours);
        assertEq(splitter.cooldown(), 12 hours);

        vm.prank(admin);
        vm.expectRevert(bytes("RS: cooldown too high"));
        splitter.setCooldown(30 days);
    }
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
forge test --match-test "test_setPlatformReceiver|test_setMinAmount|test_setCooldown" -vv
```

Expected: FAIL.

- [ ] **Step 3: Implement setters**

In `RevenueSplitter.sol`, add:

```solidity
    // ── Admin — config setters ──────────────────────────────────────────────
    function setPlatformReceiver(address newReceiver) external override onlyAdmin {
        require(newReceiver != address(0), "RS: zero receiver");
        platformReceiver = newReceiver;
        emit PlatformReceiverSet(newReceiver);
    }

    function setMinAmount(uint256 newMinAmount) external override onlyAdmin {
        require(newMinAmount <= MIN_AMOUNT_CAP, "RS: min too high");
        minAmount = newMinAmount;
        emit MinAmountSet(newMinAmount);
    }

    function setCooldown(uint256 newCooldown) external override onlyAdmin {
        require(newCooldown <= MAX_COOLDOWN, "RS: cooldown too high");
        cooldown = newCooldown;
        emit CooldownSet(newCooldown);
    }
```

- [ ] **Step 4: Run tests**

```bash
forge test --match-test "test_setPlatformReceiver|test_setMinAmount|test_setCooldown" -vv
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "feat(splitter): admin config setters with bounds"
```

---

## Task 8: Token rescue with USDC block

**Files:**
- Modify: `contracts/src/RevenueSplitter.sol`
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing tests**

Append:

```solidity
    function test_rescueToken_rescuesRandomToken() public {
        MockERC20 rando = new MockERC20("RND", "RND", 18);
        rando.mint(address(splitter), 1 ether);

        vm.prank(admin);
        splitter.rescueToken(address(rando), admin, 1 ether);

        assertEq(rando.balanceOf(admin), 1 ether);
        assertEq(rando.balanceOf(address(splitter)), 0);
    }

    function test_rescueToken_revertsForUSDC() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.prank(admin);
        vm.expectRevert(bytes("RS: cannot rescue USDC"));
        splitter.rescueToken(address(usdc), admin, 1_000e6);
    }

    function test_rescueToken_revertsForNonAdmin() public {
        MockERC20 rando = new MockERC20("RND", "RND", 18);
        rando.mint(address(splitter), 1 ether);
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.rescueToken(address(rando), anyone, 1 ether);
    }
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
forge test --match-test "test_rescueToken" -vv
```

Expected: FAIL.

- [ ] **Step 3: Implement rescueToken**

Add:

```solidity
    // ── Admin — rescue ──────────────────────────────────────────────────────
    function rescueToken(address token, address to, uint256 amount) external override onlyAdmin {
        require(token != address(USDC), "RS: cannot rescue USDC");
        require(to != address(0), "RS: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
```

- [ ] **Step 4: Run tests**

```bash
forge test --match-test "test_rescueToken" -vv
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "feat(splitter): rescueToken with USDC block"
```

---

## Task 9: 2-step admin transfer

**Files:**
- Modify: `contracts/src/RevenueSplitter.sol`
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Write failing tests**

Append:

```solidity
    function test_transferAdmin_twoStep() public {
        address newAdmin = address(0xD00D);

        vm.prank(admin);
        splitter.transferAdmin(newAdmin);
        assertEq(splitter.pendingAdmin(), newAdmin);
        assertEq(splitter.admin(), admin, "still old admin");

        vm.prank(newAdmin);
        splitter.acceptAdmin();
        assertEq(splitter.admin(), newAdmin);
        assertEq(splitter.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_revertsForNonPending() public {
        vm.prank(admin);
        splitter.transferAdmin(address(0xD00D));

        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not pending admin"));
        splitter.acceptAdmin();
    }

    function test_transferAdmin_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.transferAdmin(anyone);
    }
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
forge test --match-test "test_transferAdmin|test_acceptAdmin" -vv
```

Expected: FAIL.

- [ ] **Step 3: Implement admin handoff**

Add:

```solidity
    // ── Admin — transfer ────────────────────────────────────────────────────
    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "RS: zero new admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(newAdmin);
    }

    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "RS: not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferAccepted(msg.sender);
    }
```

- [ ] **Step 4: Run tests**

```bash
forge test --match-test "test_transferAdmin|test_acceptAdmin" -vv
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "feat(splitter): 2-step admin transfer"
```

---

## Task 10: Full suite + invariants + fuzz

**Files:**
- Modify: `contracts/test/RevenueSplitter.t.sol`

- [ ] **Step 1: Add fuzz test**

Append to `RevenueSplitterTest`:

```solidity
    function testFuzz_distribute_conservation(uint256 amount) public {
        amount = bound(amount, 100e6, 1e18); // min to ~1 trillion USDC
        usdc.mint(address(splitter), amount);
        splitter.distribute();

        uint256 platform = usdc.balanceOf(receiver);
        uint256 staker = sdiem.totalNotified();
        assertEq(platform + staker, amount, "conservation");
        assertEq(usdc.balanceOf(address(splitter)), 0, "no residual");
    }
```

- [ ] **Step 2: Run full suite**

```bash
forge test --match-path "test/RevenueSplitter*.t.sol" -vv 2>&1 | tail -30
```

Expected: ALL pass, including the invariants from Task 2.

- [ ] **Step 3: Confirm coverage**

```bash
forge coverage --match-path "test/RevenueSplitter*.t.sol" --report summary 2>&1 | grep "RevenueSplitter"
```

Expected: >95% line and branch coverage on `RevenueSplitter.sol`.

- [ ] **Step 4: Commit**

```bash
git add contracts/test/RevenueSplitter.t.sol
git commit -m "test(splitter): fuzz conservation invariant"
```

---

## Task 11: Base-fork integration test

**Files:**
- Create: `contracts/test/RevenueSplitterFork.t.sol`

This task uses real Base mainnet addresses to prove the contract works end-to-end against actual sDIEM.

- [ ] **Step 1: Write fork test**

Create `contracts/test/RevenueSplitterFork.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";

/**
 * Fork integration test.
 *
 * Runs against Base mainnet using a recent block. Verifies the full flow:
 *   - Deploy splitter with real USDC and real sDIEM.
 *   - Admin Safe switches sDIEM operator to splitter.
 *   - USDC transferred to splitter.
 *   - distribute() sends 20% to Safe, 80% to sDIEM (rewardRate increases).
 */
contract RevenueSplitterForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SDIEM = 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2;
    address constant SAFE = 0x01Ea790410D9863A57771D992D2A72ea326DD7C9;

    RevenueSplitter internal splitter;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc);

        splitter = new RevenueSplitter(
            IERC20(USDC),
            IsDIEM(SDIEM),
            SAFE, // admin
            SAFE  // platformReceiver
        );

        // Impersonate Safe to set splitter as sDIEM operator
        vm.prank(SAFE);
        IsDIEM(SDIEM).setOperator(address(splitter));
    }

    function test_fork_distributeEndToEnd() public {
        // Seed splitter with USDC from a whale / forced mint via deal
        uint256 revenue = 1_000e6;
        deal(USDC, address(splitter), revenue);

        uint256 safeBalBefore = IERC20(USDC).balanceOf(SAFE);
        uint256 sdiemBalBefore = IERC20(USDC).balanceOf(SDIEM);

        splitter.distribute();

        assertEq(
            IERC20(USDC).balanceOf(SAFE) - safeBalBefore,
            200e6,
            "Safe got 20%"
        );
        assertEq(
            IERC20(USDC).balanceOf(SDIEM) - sdiemBalBefore,
            800e6,
            "sDIEM got 80%"
        );
        assertGt(IsDIEM(SDIEM).rewardRate(), 0, "rewardRate set");
    }
}
```

- [ ] **Step 2: Run the fork test**

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract RevenueSplitterForkTest -vv 2>&1 | tail -30
```

If the public RPC rate-limits, retry with `--fork-block-number <recent-block>` to pin, or use an Alchemy/Infura key in `BASE_RPC_URL`.

Expected: PASS. If it fails because sDIEM is paused at the fork block, use a different block where it's unpaused, OR add `vm.prank(SAFE); IsDIEM(SDIEM).unpause();` to setUp.

- [ ] **Step 3: Commit**

```bash
git add contracts/test/RevenueSplitterFork.t.sol
git commit -m "test(splitter): Base-fork integration test against real sDIEM"
```

---

## Task 12: Deployment script

**Files:**
- Create: `contracts/script/DeployRevenueSplitter.s.sol`

- [ ] **Step 1: Write deploy script**

Create `contracts/script/DeployRevenueSplitter.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";

/**
 * @title DeployRevenueSplitter
 * @notice Deploys RevenueSplitter to Base.
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   forge script script/DeployRevenueSplitter.s.sol \
 *     --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Env (all default to Base mainnet values):
 *   USDC            — defaults to 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   SDIEM           — defaults to 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2
 *   ADMIN           — defaults to 2/2 Safe 0x01Ea...D7C9
 *   PLATFORM_RECV   — defaults to 2/2 Safe 0x01Ea...D7C9
 *   PRIVATE_KEY     — deployer key (required)
 *
 * Post-deploy:
 *   1. Safe signs: sDIEM.setOperator(splitter)
 *   2. atd updates cheaptokens.ai checkout to pay splitter address
 *   3. Once balance >= 100 USDC, anyone can call distribute()
 */
contract DeployRevenueSplitter is Script {
    address constant DEFAULT_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant DEFAULT_SDIEM = 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2;
    address constant DEFAULT_SAFE = 0x01Ea790410D9863A57771D992D2A72ea326DD7C9;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envOr("USDC", DEFAULT_USDC);
        address sdiem = vm.envOr("SDIEM", DEFAULT_SDIEM);
        address admin = vm.envOr("ADMIN", DEFAULT_SAFE);
        address receiver = vm.envOr("PLATFORM_RECV", DEFAULT_SAFE);

        console.log("Deploying RevenueSplitter");
        console.log("  deployer:  ", deployer);
        console.log("  USDC:      ", usdc);
        console.log("  sDIEM:     ", sdiem);
        console.log("  admin:     ", admin);
        console.log("  receiver:  ", receiver);

        vm.startBroadcast(deployerKey);
        RevenueSplitter splitter = new RevenueSplitter(
            IERC20(usdc),
            IsDIEM(sdiem),
            admin,
            receiver
        );
        vm.stopBroadcast();

        console.log("");
        console.log("  RevenueSplitter deployed at:", address(splitter));
        console.log("");
        console.log("  Next steps:");
        console.log("   1. Safe: call sDIEM.setOperator(splitter)");
        console.log("   2. atd: route cheaptokens.ai payments here");
        console.log("   3. Anyone: call distribute() once bal >= 100 USDC");
    }
}
```

- [ ] **Step 2: Verify script compiles**

```bash
forge build 2>&1 | tail -10
```

Expected: clean build, no warnings.

- [ ] **Step 3: Commit**

```bash
git add contracts/script/DeployRevenueSplitter.s.sol
git commit -m "chore(splitter): deployment script"
```

---

## Task 13: Adversarial audit pass

**Files:** none (read-only review)

- [ ] **Step 1: Run the solidity-auditor skill**

Invoke: `/solidity-auditor contracts/src/RevenueSplitter.sol`

This is a requirement per `rules/solidity-security.md` and the `migration-checklist.md` (Step 4: Adversarial audit pass).

- [ ] **Step 2: Address any HIGH or CRITICAL findings**

If findings are reported:
- For each finding, write a failing test that demonstrates the bug (if it's a real issue)
- Fix the bug
- Verify test passes
- Commit each fix separately

If all findings are informational or false positives, note why in a comment.

- [ ] **Step 3: Commit audit-response fixes**

If any fixes were made:
```bash
git add contracts/src/RevenueSplitter.sol contracts/test/RevenueSplitter.t.sol
git commit -m "fix(splitter): address audit finding <id> — <short description>"
```

---

## Task 14: Run full suite + fork tests + confirm clean

**Files:** none (verification)

- [ ] **Step 1: Run all splitter tests**

```bash
cd contracts
forge test --match-path "test/RevenueSplitter*" -vv 2>&1 | tail -30
```

Expected: all tests pass. Report count (e.g., "X passed, 0 failed").

- [ ] **Step 2: Run full repo test suite to confirm no regressions**

```bash
forge test 2>&1 | tail -5
```

Expected: all previously-passing tests still pass. No failures.

- [ ] **Step 3: Paste test output into PR / notes**

Keep the output — per `rules/migration-checklist.md` Step 6, human review needs visible evidence.

- [ ] **Step 4: Commit any final touch-ups**

If touch-ups were needed:
```bash
git commit -am "chore(splitter): final test cleanup"
```

Otherwise skip this step.

---

## Task 15: Deploy to Base + on-chain verification

**Files:** none (deploy action)

Per `rules/migration-checklist.md` Step 7: verify on-chain state before announcing.

- [ ] **Step 1: Confirm deployer wallet has ETH on Base**

```bash
cast balance <deployer-address> --rpc-url $BASE_RPC_URL
```

- [ ] **Step 2: Run deploy script**

```bash
cd contracts
PRIVATE_KEY=<deployer-key> BASE_RPC_URL=<your-alchemy-or-base-rpc> \
  forge script script/DeployRevenueSplitter.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

Expected output: `RevenueSplitter deployed at: 0x...`. Save this address.

- [ ] **Step 3: Verify on-chain state matches expected**

```bash
SPLITTER=<deployed-address>
cast call $SPLITTER "admin()(address)" --rpc-url $BASE_RPC_URL
# → 0x01Ea790410D9863A57771D992D2A72ea326DD7C9
cast call $SPLITTER "platformReceiver()(address)" --rpc-url $BASE_RPC_URL
# → 0x01Ea790410D9863A57771D992D2A72ea326DD7C9
cast call $SPLITTER "USDC()(address)" --rpc-url $BASE_RPC_URL
# → 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
cast call $SPLITTER "sdiem()(address)" --rpc-url $BASE_RPC_URL
# → 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2
cast call $SPLITTER "minAmount()(uint256)" --rpc-url $BASE_RPC_URL
# → 100000000 (100 USDC)
cast call $SPLITTER "cooldown()(uint256)" --rpc-url $BASE_RPC_URL
# → 82800 (23 hours)
```

If any of these return unexpected values, stop and investigate before proceeding.

- [ ] **Step 4: Update project CLAUDE.md with deployed address**

Edit `.claude/CLAUDE.md` to add under "Deployed Contracts (Base)":
```
- **RevenueSplitter**: <deployed-address>
  - admin + platformReceiver: 0x01Ea790410D9863A57771D992D2A72ea326DD7C9 (2/2 Safe)
  - 20/80 USDC splitter: 20% → Safe, 80% → sDIEM.notifyRewardAmount
  - Permissionless distribute(), 23h cooldown, 100 USDC min
```

Commit:
```bash
git add .claude/CLAUDE.md
git commit -m "docs: add RevenueSplitter deployed address"
```

---

## Task 16: Operator handoff + first distribution

**Files:** none (on-chain operations)

- [ ] **Step 1: Safe signs sDIEM operator change**

Via Safe UI, compose a transaction:
- `to`: `0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2` (sDIEM)
- `data`: `setOperator(address)` with the new splitter address
- Both signers approve → execute

Verify after execution:
```bash
cast call 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2 "operator()(address)" --rpc-url $BASE_RPC_URL
# → <splitter-address>
```

- [ ] **Step 2: Hand splitter address to atd**

Message atd with: "Please route cheaptokens.ai USDC payments to `<splitter-address>` on Base. The splitter will handle the 20/80 distribution automatically."

- [ ] **Step 3: Wait for first USDC to arrive**

Monitor:
```bash
watch -n 30 "cast call 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 'balanceOf(address)(uint256)' <splitter-address> --rpc-url $BASE_RPC_URL"
```

Wait for balance ≥ 100 USDC.

- [ ] **Step 4: Call `distribute()` (permissionless, anyone can)**

```bash
cast send <splitter-address> "distribute()" --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL
```

- [ ] **Step 5: Verify first distribution on-chain**

```bash
# Safe received 20%
cast call 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "balanceOf(address)(uint256)" \
  0x01Ea790410D9863A57771D992D2A72ea326DD7C9 --rpc-url $BASE_RPC_URL
# (Should have increased by ~20% of what arrived)

# sDIEM rewardRate is non-zero and periodFinish is 24h from now
cast call 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2 "rewardRate()(uint256)" --rpc-url $BASE_RPC_URL
cast call 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2 "periodFinish()(uint256)" --rpc-url $BASE_RPC_URL

# Splitter lifetime counters updated
cast call <splitter> "totalPlatformPaid()(uint256)" --rpc-url $BASE_RPC_URL
cast call <splitter> "totalStakerPaid()(uint256)" --rpc-url $BASE_RPC_URL
```

- [ ] **Step 6: Tag the commit and announce**

```bash
git tag -a v1.0-splitter -m "RevenueSplitter deployed + first distribution"
git push --tags
```

Post to Discord / Twitter / internal channels — but ONLY after Step 5 confirms the funds arrived on-chain (per migration-checklist.md Step 7).

---

## Success Criteria

All 16 tasks complete, with evidence:
- Full local test suite passes (all 4 test files)
- Fork test passes against real sDIEM on Base
- `/solidity-auditor` produced no HIGH/CRITICAL findings (or findings were addressed)
- Contract deployed and verified on Basescan
- On-chain state reads match expected (admin, receiver, addresses, defaults)
- sDIEM operator is the splitter
- First distribute() executed, Safe has 20%, sDIEM rewardRate is non-zero
- CLAUDE.md updated with deployed address
