// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title sDIEMHandler
 * @notice Guided handler for invariant testing. Manages staking/withdrawing/
 *         claiming/rewarding/Venice operations with bounded inputs.
 */
contract sDIEMHandler is Test {
    sDIEM public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;

    address[] public actors;
    address public operator;

    // Ghost variables — track what SHOULD be true
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalRewardsNotified;
    uint256 public ghost_totalRewardsClaimed;

    constructor(
        sDIEM _staking,
        MockDIEMStaking _diem,
        MockERC20 _usdc,
        address[] memory _actors,
        address _operator
    ) {
        staking = _staking;
        diemToken = _diem;
        usdcToken = _usdc;
        actors = _actors;
        operator = _operator;

        // Set cooldown to 0 for instant unstake in invariant testing
        diemToken.setCooldownDuration(0);
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ── Actions ───────────────────────────────────────────────────────────

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = diemToken.balanceOf(actor);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        vm.prank(actor);
        staking.stake(amount);

        ghost_totalStaked += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;

        // Bound by both user balance and liquid buffer
        uint256 buffer = staking.liquidBuffer();
        if (buffer == 0) return;

        amount = bound(amount, 1, _min(bal, buffer));

        vm.prank(actor);
        staking.withdraw(amount);

        ghost_totalStaked -= amount;
    }

    function claimReward(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 earned = staking.earned(actor);

        vm.prank(actor);
        staking.claimReward();

        ghost_totalRewardsClaimed += earned;
    }

    function notifyReward(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000e6); // 1 to 10K USDC

        usdcToken.mint(address(staking), amount);
        vm.prank(operator);
        staking.notifyRewardAmount(amount);

        ghost_totalRewardsNotified += amount;
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 48 hours);
        vm.warp(block.timestamp + seconds_);
    }

    function exit(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;

        // Exit requires buffer >= full balance
        uint256 buffer = staking.liquidBuffer();
        if (buffer < bal) return;

        uint256 earned = staking.earned(actor);

        vm.prank(actor);
        staking.exit();

        ghost_totalStaked -= bal;
        ghost_totalRewardsClaimed += earned;
    }

    // ── Venice actions ────────────────────────────────────────────────────

    function deployToVenice(uint256 amount) external {
        uint256 buffer = staking.liquidBuffer();
        if (buffer == 0) return;

        uint256 total = staking.totalStaked();
        if (total == 0) return;

        uint256 floor = (total * 500) / 10000; // 5% floor
        if (buffer <= floor) return;

        amount = bound(amount, 1, buffer - floor);

        vm.prank(operator);
        staking.deployToVenice(amount);
    }

    function initiateBufferReplenish(uint256 amount) external {
        uint256 staked = staking.forwardStaked();
        if (staked == 0) return;

        amount = bound(amount, 1, staked);

        vm.prank(operator);
        staking.initiateBufferReplenish(amount);
    }

    function completeBufferReplenish() external {
        uint256 pending = staking.pendingUnstake();
        if (pending == 0) return;

        vm.prank(operator);
        staking.completeBufferReplenish();
    }
}

/**
 * @title sDIEMInvariantTest
 * @notice Invariant tests for the sDIEM staking contract with Venice forward-staking.
 *
 * Key invariants:
 *   1. Conservation: liquidBuffer + forwardStaked + pendingUnstake == totalStaked
 *   2. Ghost tracking matches totalStaked
 *   3. No over-distribution: total claimed <= total notified
 *   4. Reward solvency: contract USDC >= unclaimed rewards
 *   5. rewardPerToken never decreases
 */
contract sDIEMInvariantTest is Test {
    sDIEM public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;
    sDIEMHandler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address[] actors;

    function setUp() public {
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);

        staking = new sDIEM(
            address(diemToken),
            address(usdcToken),
            admin,
            operator
        );

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);

            diemToken.mint(actor, 10_000e18);

            vm.prank(actor);
            diemToken.approve(address(staking), type(uint256).max);
        }

        handler = new sDIEMHandler(
            staking,
            diemToken,
            usdcToken,
            actors,
            operator
        );

        // Target only the handler
        targetContract(address(handler));
    }

    // ── Invariant 1: DIEM conservation ──────────────────────────────────
    // liquidBuffer + forwardStaked + pendingUnstake must always equal totalStaked.
    // This holds even when DIEM is forward-staked on Venice.

    function invariant_diemConservation() public view {
        assertEq(
            staking.liquidBuffer() + staking.forwardStaked() + staking.pendingUnstake(),
            staking.totalStaked(),
            "liquidBuffer + forwardStaked + pendingUnstake != totalStaked"
        );
    }

    function invariant_totalStakedMatchesGhost() public view {
        assertEq(
            staking.totalStaked(),
            handler.ghost_totalStaked(),
            "totalStaked != ghost_totalStaked"
        );
    }

    // ── Invariant 2: No over-distribution ───────────────────────────────
    // Total rewards claimed must never exceed total rewards notified.

    function invariant_noOverDistribution() public view {
        assertLe(
            handler.ghost_totalRewardsClaimed(),
            handler.ghost_totalRewardsNotified(),
            "claimed > notified"
        );
    }

    // ── Invariant 3: Reward solvency ────────────────────────────────────
    // The contract must always hold enough USDC to cover all unclaimed rewards.

    function invariant_rewardSolvency() public view {
        uint256 totalUnclaimed;
        for (uint256 i = 0; i < actors.length; i++) {
            totalUnclaimed += staking.earned(actors[i]);
        }

        assertGe(
            usdcToken.balanceOf(address(staking)),
            totalUnclaimed,
            "USDC balance < unclaimed rewards"
        );
    }

    // ── Invariant 4: Balance sum equals totalStaked ──────────────────────

    function invariant_balanceSumEqualsTotalStaked() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.balanceOf(actors[i]);
        }

        assertEq(sum, staking.totalStaked(), "sum(balances) != totalStaked");
    }

    // ── Invariant 5: rewardPerToken never decreases ─────────────────────

    uint256 private lastRewardPerToken;

    function invariant_rewardPerTokenMonotonic() public {
        uint256 current = staking.rewardPerToken();
        assertGe(current, lastRewardPerToken, "rewardPerToken decreased");
        lastRewardPerToken = current;
    }
}
