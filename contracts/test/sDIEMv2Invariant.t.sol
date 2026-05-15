// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEMv2} from "../src/sDIEMv2.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title sDIEMv2Handler
 * @notice Guided handler for invariant testing of sDIEM v2.
 *
 *         Exercises: stake, requestWithdraw, completeWithdraw, cancelWithdraw,
 *         exit, claimReward, claimRewardTo, **transfer** (the headline v2
 *         feature), notifyReward, time-warp, and Venice ops.
 */
contract sDIEMv2Handler is Test {
    sDIEMv2 public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;

    address[] public actors;
    address public operator;

    // Ghost — what SHOULD be true based on spec semantics, not code
    uint256 public ghost_totalDiemDeposited;       // Σ stake amounts ever
    uint256 public ghost_totalDiemWithdrawn;       // Σ completeWithdraw payouts
    uint256 public ghost_totalRewardsNotified;     // Σ reward inflows (after L-01 dust refund)
    uint256 public ghost_totalRewardsClaimed;      // Σ USDC paid to users via claim*

    // Track round-trip transfer earnings for the burn-then-mint preservation test
    mapping(address => uint256) public ghost_lastEarnedSnapshot;

    constructor(
        sDIEMv2 _staking,
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

        diemToken.setCooldownDuration(0); // instant unstake for invariant runs
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ── Actions ───────────────────────────────────────────────────────────

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = diemToken.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try staking.stake(amount) {
            ghost_totalDiemDeposited += amount;
        } catch {}
    }

    function requestWithdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        if (amount < staking.MIN_WITHDRAW()) return;

        vm.prank(actor);
        try staking.requestWithdraw(amount) {} catch {}
    }

    function completeWithdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        (uint256 pending, uint256 requestedAt) = staking.withdrawalRequests(actor);
        if (pending == 0) return;

        if (block.timestamp < requestedAt + staking.WITHDRAWAL_DELAY()) {
            vm.warp(requestedAt + staking.WITHDRAWAL_DELAY());
        }

        (,, uint256 venicePending) = diemToken.stakedInfos(address(staking));
        if (venicePending > 0) {
            try staking.claimFromVenice() {} catch {}
        }

        uint256 liquid = diemToken.balanceOf(address(staking));
        if (liquid < pending) return;

        vm.prank(actor);
        try staking.completeWithdraw() {
            ghost_totalDiemWithdrawn += pending;
        } catch {}
    }

    function cancelWithdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        (uint256 pending,) = staking.withdrawalRequests(actor);
        if (pending == 0) return;

        vm.prank(actor);
        try staking.cancelWithdraw() {} catch {}
    }

    function claimReward(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 earnedBefore = staking.earned(actor);
        uint256 usdcBefore = usdcToken.balanceOf(actor);

        vm.prank(actor);
        try staking.claimReward() {
            uint256 paid = usdcToken.balanceOf(actor) - usdcBefore;
            ghost_totalRewardsClaimed += paid;
            // Sanity: paid out should be <= what was earned
            // (rounding from rewardPerToken integer math can cause +/- 1 wei).
            assertLe(paid, earnedBefore + 1, "claim paid > earned");
        } catch {}
    }

    /// @notice The headline v2 capability: transfer sDIEM.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 bal = staking.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        // Spec invariant: transfer must preserve sum of earned across (from, to).
        uint256 earnedBefore = staking.earned(from) + staking.earned(to);

        vm.prank(from);
        try staking.transfer(to, amount) {
            uint256 earnedAfter = staking.earned(from) + staking.earned(to);
            // Rounding tolerance: rewardPerToken uses integer division
            // (delta * rate * 1e18) / supply. Each per-user accrual can lose
            // up to 1 wei, so a (from,to) pair tolerates 2 wei drift.
            assertApproxEqAbs(
                earnedAfter,
                earnedBefore,
                2,
                "transfer leaked or vaporized rewards"
            );
        } catch {}
    }

    function notifyReward(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000e6);
        usdcToken.mint(operator, amount);
        vm.startPrank(operator);
        usdcToken.approve(address(staking), amount);
        uint256 balBefore = usdcToken.balanceOf(address(staking));
        try staking.notifyRewardAmount(amount) {
            // Net inflow into the contract (L-01 dust may have been refunded).
            uint256 inflow = usdcToken.balanceOf(address(staking)) - balBefore;
            ghost_totalRewardsNotified += inflow;
        } catch {}
        vm.stopPrank();
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 48 hours);
        vm.warp(block.timestamp + secs);
    }

    function exit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 usdcBefore = usdcToken.balanceOf(actor);

        vm.prank(actor);
        try staking.exit() {
            uint256 paid = usdcToken.balanceOf(actor) - usdcBefore;
            ghost_totalRewardsClaimed += paid;
        } catch {}
    }

    function claimFromVenice() external {
        (,, uint256 pending) = diemToken.stakedInfos(address(staking));
        if (pending == 0) return;
        try staking.claimFromVenice() {} catch {}
    }

    function redeployExcess() external {
        try staking.redeployExcess() {} catch {}
    }
}

/**
 * @title sDIEMv2InvariantTest
 * @notice Spec-driven invariants for sDIEM v2.
 *
 *         The asserts below describe what MUST be true under the spec,
 *         independent of how the code happens to compute it.
 */
contract sDIEMv2InvariantTest is Test {
    sDIEMv2 public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;
    sDIEMv2Handler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address[] actors;

    function setUp() public {
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);

        staking = new sDIEMv2(address(diemToken), address(usdcToken), admin, operator);

        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            diemToken.mint(actor, 10_000e18);
            vm.prank(actor);
            diemToken.approve(address(staking), type(uint256).max);
        }

        handler = new sDIEMv2Handler(staking, diemToken, usdcToken, actors, operator);
        targetContract(address(handler));
    }

    // ── Invariant 1: ERC-20 supply consistency ──────────────────────────
    // Sum of all sDIEM balances equals totalSupply.

    function invariant_balanceSumEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.balanceOf(actors[i]);
        }
        assertEq(sum, staking.totalSupply(), "sum balanceOf != totalSupply");
    }

    // ── Invariant 2: totalStaked() view matches totalSupply() ───────────

    function invariant_totalStakedMatchesSupply() public view {
        assertEq(staking.totalStaked(), staking.totalSupply(), "totalStaked != totalSupply");
    }

    // ── Invariant 3: DIEM conservation across the entire system ─────────
    // Every DIEM is one of: actively staked (sDIEM totalSupply), queued for
    // withdrawal (totalPendingWithdrawals), or already withdrawn. The
    // staking contract's view of "DIEM held on behalf of users" must equal
    // what's accounted for in Venice + liquid.

    function invariant_diemConservation() public view {
        (uint256 veniceStaked,, uint256 venicePending) = diemToken.stakedInfos(address(staking));
        uint256 liquid = diemToken.balanceOf(address(staking));

        uint256 owed = staking.totalSupply() + staking.totalPendingWithdrawals();
        uint256 held = veniceStaked + venicePending + liquid;

        assertEq(held, owed, "Venice + liquid != supply + pending");
    }

    // ── Invariant 4: No over-distribution of rewards ────────────────────
    // Total USDC ever claimed by users cannot exceed total USDC ever
    // received by the contract (net of L-01 dust refunds).

    function invariant_noOverDistribution() public view {
        assertLe(
            handler.ghost_totalRewardsClaimed(),
            handler.ghost_totalRewardsNotified(),
            "claimed > notified - rewards minted from thin air"
        );
    }

    // ── Invariant 5: Reward solvency ────────────────────────────────────
    // The contract must hold at least enough USDC to cover all currently
    // unclaimed rewards. If this ever breaks, a staker calling claimReward
    // would brick.

    function invariant_rewardSolvency() public view {
        uint256 totalUnclaimed;
        for (uint256 i = 0; i < actors.length; i++) {
            totalUnclaimed += staking.earned(actors[i]);
        }
        // Allow tiny rounding (rewardPerToken integer-div drift per user).
        uint256 tolerance = actors.length;
        assertGe(
            usdcToken.balanceOf(address(staking)) + tolerance,
            totalUnclaimed,
            "USDC balance < total unclaimed rewards"
        );
    }

    // ── Invariant 6: rewardPerToken never decreases ─────────────────────
    // Synthetix accumulator is monotonic by construction. If it ever goes
    // backwards, something has corrupted the reward bookkeeping.

    uint256 private lastRewardPerToken;

    function invariant_rewardPerTokenMonotonic() public {
        uint256 current = staking.rewardPerToken();
        assertGe(current, lastRewardPerToken, "rewardPerToken regressed");
        lastRewardPerToken = current;
    }

    // ── Invariant 7: No phantom pending-not-initiated ───────────────────
    // The "not initiated" counter is a subset of total pending withdrawals.

    function invariant_pendingNotInitiatedLEPending() public view {
        assertLe(
            staking.totalPendingNotInitiated(),
            staking.totalPendingWithdrawals(),
            "notInitiated > totalPending - counter desync"
        );
    }

    // ── Invariant 8: Earned never overflows or goes negative ─────────────
    // earned() is computed as (balance * deltaR) / 1e18 + rewards. If
    // userRewardPerTokenPaid is ever > rewardPerToken (the Synthetix trap
    // when transfers don't checkpoint), this would underflow.

    function invariant_earnedNeverUnderflows() public view {
        // Just calling earned() for each actor — if any path can underflow,
        // this view reverts and the invariant fails.
        for (uint256 i = 0; i < actors.length; i++) {
            staking.earned(actors[i]);
        }
    }
}
