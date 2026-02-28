// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title sDIEMHandler
 * @notice Guided handler for invariant testing. Manages staking/withdrawing/
 *         claiming/rewarding with bounded inputs and realistic sequencing.
 */
contract sDIEMHandler is Test {
    sDIEM public staking;
    MockERC20 public diemToken;
    MockERC20 public usdcToken;

    address[] public actors;
    address public operator;

    // Ghost variables — track what SHOULD be true
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalRewardsNotified;
    uint256 public ghost_totalRewardsClaimed;

    constructor(
        sDIEM _staking,
        MockERC20 _diem,
        MockERC20 _usdc,
        address[] memory _actors,
        address _operator
    ) {
        staking = _staking;
        diemToken = _diem;
        usdcToken = _usdc;
        actors = _actors;
        operator = _operator;
    }

    // ── Actions ─────────────────────────────────────────────────────────

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, diemToken.balanceOf(actor));
        if (amount == 0) return;

        vm.prank(actor);
        staking.stake(amount);

        ghost_totalStaked += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

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

        uint256 earned = staking.earned(actor);

        vm.prank(actor);
        staking.exit();

        ghost_totalStaked -= bal;
        ghost_totalRewardsClaimed += earned;
    }
}

/**
 * @title sDIEMInvariantTest
 * @notice Invariant tests for the sDIEM staking contract.
 *
 * Key invariants:
 *   1. Conservation: totalStaked == sum of all balances == DIEM in contract
 *   2. No over-distribution: total claimed <= total notified
 *   3. Reward solvency: contract USDC >= unclaimed rewards
 */
contract sDIEMInvariantTest is Test {
    sDIEM public staking;
    MockERC20 public diemToken;
    MockERC20 public usdcToken;
    sDIEMHandler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address[] actors;

    function setUp() public {
        diemToken = new MockERC20("DIEM", "DIEM", 18);
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
    // The contract's DIEM balance must always equal totalStaked.
    // totalStaked must always equal the handler's ghost tracking.

    function invariant_diemConservation() public view {
        assertEq(
            diemToken.balanceOf(address(staking)),
            staking.totalStaked(),
            "DIEM balance != totalStaked"
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
    // (unclaimed = notified - claimed - still-streaming)
    // Simplified: contract USDC balance >= sum of all earned()

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
    // Sum of individual balances must equal totalStaked.

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
