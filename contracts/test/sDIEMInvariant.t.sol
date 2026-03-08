// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title sDIEMHandler
 * @notice Guided handler for invariant testing. Manages staking, async
 *         withdrawals, reward claiming, and permissionless Venice ops.
 */
contract sDIEMHandler is Test {
    sDIEM public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;

    address[] public actors;
    address public operator;

    // Ghost variables — track what SHOULD be true
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalPendingWithdrawals;
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

    function requestWithdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        vm.prank(actor);
        staking.requestWithdraw(amount);

        ghost_totalStaked -= amount;
        ghost_totalPendingWithdrawals += amount;
    }

    function completeWithdraw(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 pending, uint256 requestedAt) = staking.withdrawalRequests(actor);
        if (pending == 0) return;

        // Ensure delay has passed
        if (block.timestamp < requestedAt + staking.WITHDRAWAL_DELAY()) {
            vm.warp(requestedAt + staking.WITHDRAWAL_DELAY());
        }

        // Claim from Venice if needed (cooldown is 0 in tests)
        (,, uint256 venicePending) = diemToken.stakedInfos(address(staking));
        if (venicePending > 0) {
            staking.claimFromVenice();
        }

        // Only complete if enough liquid
        uint256 liquid = diemToken.balanceOf(address(staking));
        if (liquid < pending) return;

        vm.prank(actor);
        staking.completeWithdraw();

        ghost_totalPendingWithdrawals -= pending;
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
        ghost_totalPendingWithdrawals += bal;
        ghost_totalRewardsClaimed += earned;
    }

    function claimFromVenice() external {
        (,, uint256 pending) = diemToken.stakedInfos(address(staking));
        if (pending == 0) return;

        staking.claimFromVenice();
    }

    function redeployExcess() external {
        uint256 liquid = diemToken.balanceOf(address(staking));
        uint256 pendingW = staking.totalPendingWithdrawals();
        if (liquid <= pendingW) return;

        staking.redeployExcess();
    }
}

/**
 * @title sDIEMInvariantTest
 * @notice Invariant tests for the sDIEM staking contract with async withdrawals
 *         and permissionless Venice management.
 *
 * Key invariants:
 *   1. Ghost tracking matches totalStaked and totalPendingWithdrawals
 *   2. No over-distribution: total claimed <= total notified
 *   3. Reward solvency: contract USDC >= unclaimed rewards
 *   4. Balance sum equals totalStaked
 *   5. rewardPerToken never decreases
 *   6. Venice DIEM conservation: all DIEM is accounted for
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

    // ── Invariant 1: Ghost tracking matches contract state ───────────────

    function invariant_totalStakedMatchesGhost() public view {
        assertEq(
            staking.totalStaked(),
            handler.ghost_totalStaked(),
            "totalStaked != ghost_totalStaked"
        );
    }

    function invariant_totalPendingWithdrawalsMatchesGhost() public view {
        assertEq(
            staking.totalPendingWithdrawals(),
            handler.ghost_totalPendingWithdrawals(),
            "totalPendingWithdrawals != ghost"
        );
    }

    // ── Invariant 2: No over-distribution ────────────────────────────────
    // Total rewards claimed must never exceed total rewards notified.

    function invariant_noOverDistribution() public view {
        assertLe(
            handler.ghost_totalRewardsClaimed(),
            handler.ghost_totalRewardsNotified(),
            "claimed > notified"
        );
    }

    // ── Invariant 3: Reward solvency ─────────────────────────────────────
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

    // ── Invariant 4: Balance sum equals totalStaked ───────────────────────

    function invariant_balanceSumEqualsTotalStaked() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.balanceOf(actors[i]);
        }

        assertEq(sum, staking.totalStaked(), "sum(balances) != totalStaked");
    }

    // ── Invariant 5: rewardPerToken never decreases ──────────────────────

    uint256 private lastRewardPerToken;

    function invariant_rewardPerTokenMonotonic() public {
        uint256 current = staking.rewardPerToken();
        assertGe(current, lastRewardPerToken, "rewardPerToken decreased");
        lastRewardPerToken = current;
    }

    // ── Invariant 6: Venice DIEM conservation ────────────────────────────
    // All DIEM that was staked is somewhere: Venice staked + Venice pending +
    // liquid in contract. This must account for both active stakers and
    // pending withdrawals.

    function invariant_veniceDiemConservation() public view {
        (uint256 veniceStaked,, uint256 venicePending) = diemToken.stakedInfos(address(staking));
        uint256 liquid = diemToken.balanceOf(address(staking));

        // Total DIEM accounted for = Venice staked + Venice pending + liquid
        uint256 totalAccountedFor = veniceStaked + venicePending + liquid;

        // This should equal totalStaked + totalPendingWithdrawals
        // (totalStaked = DIEM still earning, totalPendingWithdrawals = DIEM owed to redeemers)
        uint256 totalOwed = staking.totalStaked() + staking.totalPendingWithdrawals();

        assertEq(
            totalAccountedFor,
            totalOwed,
            "Venice DIEM != totalStaked + totalPendingWithdrawals"
        );
    }
}
