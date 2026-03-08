// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract sDIEMTest is Test {
    sDIEM public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DIEM_AMOUNT = 100e18;
    uint256 constant REWARD_AMOUNT = 100e6; // 100 USDC
    // Synthetix truncation dust: rewardRate = reward / 86400 truncates.
    // Max dust per period ≈ REWARDS_DURATION wei of reward token (~0.09 USDC).
    uint256 constant REWARD_DUST = 100_000; // 0.1 USDC tolerance

    function setUp() public {
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);

        staking = new sDIEM(
            address(diemToken),
            address(usdcToken),
            admin,
            operator
        );

        // Seed users with DIEM
        diemToken.mint(alice, 1000e18);
        diemToken.mint(bob, 1000e18);

        // Approve staking contract
        vm.prank(alice);
        diemToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        diemToken.approve(address(staking), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _seedRewards(uint256 amount) internal {
        usdcToken.mint(address(staking), amount);
        vm.prank(operator);
        staking.notifyRewardAmount(amount);
    }

    /// @dev Stake, request, warp 24h, claim from Venice, complete — full async flow.
    function _stakeAndWithdraw(address user, uint256 stakeAmount, uint256 withdrawAmount) internal {
        vm.prank(user);
        staking.stake(stakeAmount);

        vm.prank(user);
        staking.requestWithdraw(withdrawAmount);

        vm.warp(block.timestamp + 24 hours);

        // Claim from Venice to get liquid DIEM
        staking.claimFromVenice();

        vm.prank(user);
        staking.completeWithdraw();
    }

    // ── Constructor ─────────────────────────────────────────────────────

    function test_constructor_setsTokens() public view {
        assertEq(address(staking.diem()), address(diemToken));
        assertEq(address(staking.usdc()), address(usdcToken));
        assertEq(staking.admin(), admin);
        assertEq(staking.operator(), operator);
    }

    function test_constructor_revertsZeroDiem() public {
        vm.expectRevert("sDIEM: zero diem");
        new sDIEM(address(0), address(usdcToken), admin, operator);
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert("sDIEM: zero usdc");
        new sDIEM(address(diemToken), address(0), admin, operator);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("sDIEM: zero admin");
        new sDIEM(address(diemToken), address(usdcToken), address(0), operator);
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert("sDIEM: zero operator");
        new sDIEM(address(diemToken), address(usdcToken), admin, address(0));
    }

    // ── Staking ─────────────────────────────────────────────────────────

    function test_stake_updatesBalances() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        assertEq(staking.balanceOf(alice), DIEM_AMOUNT);
        assertEq(staking.totalStaked(), DIEM_AMOUNT);
        // DIEM forwarded to Venice — contract holds 0 liquid DIEM
        assertEq(diemToken.balanceOf(address(staking)), 0);
        // Verify Venice got it
        (uint256 staked,,) = diemToken.stakedInfos(address(staking));
        assertEq(staked, DIEM_AMOUNT);
    }

    function test_stake_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IsDIEM.Staked(alice, DIEM_AMOUNT);

        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);
    }

    function test_stake_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: zero amount");
        staking.stake(0);
    }

    function test_stake_revertsWhenPaused() public {
        vm.prank(admin);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert("sDIEM: paused");
        staking.stake(DIEM_AMOUNT);
    }

    // ── Request Withdraw ────────────────────────────────────────────────

    function test_requestWithdraw_updatesState() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Staked balance deducted
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);

        // Pending withdrawal tracked
        (uint256 amount, uint256 requestedAt) = staking.withdrawalRequests(alice);
        assertEq(amount, DIEM_AMOUNT);
        assertEq(requestedAt, block.timestamp);
        assertEq(staking.totalPendingWithdrawals(), DIEM_AMOUNT);
    }

    function test_requestWithdraw_emitsEvent() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit IsDIEM.WithdrawalRequested(alice, DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);
    }

    function test_requestWithdraw_revertsZeroAmount() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: zero amount");
        staking.requestWithdraw(0);
    }

    function test_requestWithdraw_revertsInsufficientBalance() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: insufficient balance");
        staking.requestWithdraw(DIEM_AMOUNT + 1);
    }

    function test_requestWithdraw_partialAmount() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT / 2);

        assertEq(staking.balanceOf(alice), DIEM_AMOUNT / 2);
        assertEq(staking.totalStaked(), DIEM_AMOUNT / 2);
        assertEq(staking.totalPendingWithdrawals(), DIEM_AMOUNT / 2);
    }

    function test_requestWithdraw_accumulates() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // First request
        vm.prank(alice);
        staking.requestWithdraw(30e18);

        // Second request — accumulates amount, resets timer
        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        staking.requestWithdraw(20e18);

        (uint256 amount, uint256 requestedAt) = staking.withdrawalRequests(alice);
        assertEq(amount, 50e18);
        assertEq(requestedAt, block.timestamp); // Timer reset
        assertEq(staking.totalPendingWithdrawals(), 50e18);
    }

    function test_requestWithdraw_allowedWhenPaused() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(admin);
        staking.pause();

        // Request withdraw must succeed even when paused — users can always initiate exit
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        (uint256 amount,) = staking.withdrawalRequests(alice);
        assertEq(amount, DIEM_AMOUNT);
    }

    function test_requestWithdraw_initiatesVeniceUnstake() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Venice should have pending unstake
        (uint256 staked,, uint256 pending) = diemToken.stakedInfos(address(staking));
        assertEq(staked, 0);
        assertEq(pending, DIEM_AMOUNT);
    }

    // ── Complete Withdraw ───────────────────────────────────────────────

    function test_completeWithdraw_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Warp past 24h delay
        vm.warp(block.timestamp + 24 hours);

        // Claim from Venice first (permissionless)
        staking.claimFromVenice();

        uint256 balBefore = diemToken.balanceOf(alice);

        vm.prank(alice);
        staking.completeWithdraw();

        assertEq(diemToken.balanceOf(alice), balBefore + DIEM_AMOUNT);
        (uint256 amount,) = staking.withdrawalRequests(alice);
        assertEq(amount, 0);
        assertEq(staking.totalPendingWithdrawals(), 0);
    }

    function test_completeWithdraw_emitsEvent() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        vm.warp(block.timestamp + 24 hours);
        staking.claimFromVenice();

        vm.expectEmit(true, false, false, true);
        emit IsDIEM.WithdrawalCompleted(alice, DIEM_AMOUNT);

        vm.prank(alice);
        staking.completeWithdraw();
    }

    function test_completeWithdraw_revertsNoRequest() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: no pending withdrawal");
        staking.completeWithdraw();
    }

    function test_completeWithdraw_revertsDelayNotMet() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Only 12 hours — not enough
        vm.warp(block.timestamp + 12 hours);

        vm.prank(alice);
        vm.expectRevert("sDIEM: withdrawal delay not met");
        staking.completeWithdraw();
    }

    function test_completeWithdraw_revertsInsufficientLiquidity() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        vm.warp(block.timestamp + 24 hours);

        // Don't call claimFromVenice — no liquid DIEM
        vm.prank(alice);
        vm.expectRevert("sDIEM: claim from Venice first");
        staking.completeWithdraw();
    }

    // ── Exit ────────────────────────────────────────────────────────────

    function test_exit_requestsWithdrawAndClaimsRewards() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        uint256 usdcBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.exit();

        // Staked balance is zero
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);

        // USDC rewards claimed immediately
        assertApproxEqAbs(
            usdcToken.balanceOf(alice) - usdcBefore,
            REWARD_AMOUNT,
            REWARD_DUST
        );

        // DIEM NOT transferred yet — user must completeWithdraw after delay
        (uint256 amount,) = staking.withdrawalRequests(alice);
        assertEq(amount, DIEM_AMOUNT);
        assertEq(staking.totalPendingWithdrawals(), DIEM_AMOUNT);
    }

    function test_exit_withNothingStaked_onlyClaimsRewards() public {
        // Alice stakes, earns rewards, then unstakes via requestWithdraw
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        // Request withdraw (but don't complete)
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Now exit with 0 staked — should still claim rewards
        uint256 usdcBefore = usdcToken.balanceOf(alice);
        vm.prank(alice);
        staking.exit();

        assertGt(usdcToken.balanceOf(alice), usdcBefore);
    }

    // ── Rewards ──────────────────────────────────────────────────────────

    function test_rewards_accrueProperly() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);

        // Fast-forward 24 hours (full period)
        vm.warp(block.timestamp + 24 hours);

        // Alice should have earned ~100 USDC (sole staker)
        uint256 earned = staking.earned(alice);
        assertApproxEqAbs(earned, REWARD_AMOUNT, REWARD_DUST);
    }

    function test_rewards_splitProRata() public {
        // Alice stakes 100 DIEM, Bob stakes 100 DIEM
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);
        vm.prank(bob);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);

        vm.warp(block.timestamp + 24 hours);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);

        // Each should get ~50 USDC
        assertApproxEqAbs(aliceEarned, REWARD_AMOUNT / 2, REWARD_DUST);
        assertApproxEqAbs(bobEarned, REWARD_AMOUNT / 2, REWARD_DUST);
    }

    function test_rewards_halfPeriod() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);

        // Only 12 hours elapsed
        vm.warp(block.timestamp + 12 hours);

        uint256 earned = staking.earned(alice);
        assertApproxEqAbs(earned, REWARD_AMOUNT / 2, REWARD_DUST);
    }

    function test_claimReward_transfersUsdc() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        uint256 balBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.claimReward();

        uint256 balAfter = usdcToken.balanceOf(alice);
        assertApproxEqAbs(balAfter - balBefore, REWARD_AMOUNT, REWARD_DUST);
        assertEq(staking.earned(alice), 0);
    }

    function test_claimReward_emitsEvent() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        uint256 expectedReward = staking.earned(alice);

        vm.expectEmit(true, false, false, true);
        emit IsDIEM.RewardPaid(alice, expectedReward);

        vm.prank(alice);
        staking.claimReward();
    }

    function test_claimReward_nothingToClaim() public {
        // Alice stakes but no rewards seeded
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        uint256 balBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.claimReward();

        // No USDC transferred
        assertEq(usdcToken.balanceOf(alice), balBefore);
    }

    // ── Permissionless Venice Management ─────────────────────────────────

    function test_claimFromVenice_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Request withdraw to trigger initiateUnstake
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Warp past cooldown
        vm.warp(block.timestamp + 24 hours);

        // Anyone can call claimFromVenice
        vm.expectEmit(true, false, false, true);
        emit IsDIEM.VeniceClaimed(bob, DIEM_AMOUNT);

        vm.prank(bob); // bob calls, not alice
        staking.claimFromVenice();

        // DIEM now liquid in the contract
        assertEq(diemToken.balanceOf(address(staking)), DIEM_AMOUNT);
    }

    function test_claimFromVenice_revertsNothingPending() public {
        vm.expectRevert("sDIEM: nothing pending on Venice");
        staking.claimFromVenice();
    }

    function test_redeployExcess_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Simulate excess liquid DIEM (e.g., someone accidentally sent DIEM to the contract)
        uint256 excessAmount = 50e18;
        diemToken.mint(address(staking), excessAmount);

        uint256 liquid = diemToken.balanceOf(address(staking));
        assertEq(liquid, excessAmount);
        assertEq(staking.totalPendingWithdrawals(), 0);

        vm.expectEmit(true, false, false, true);
        emit IsDIEM.ExcessRedeployed(bob, excessAmount);

        vm.prank(bob); // Anyone can call
        staking.redeployExcess();

        // DIEM back on Venice
        assertEq(diemToken.balanceOf(address(staking)), 0);
        (uint256 staked,,) = diemToken.stakedInfos(address(staking));
        assertEq(staked, DIEM_AMOUNT + excessAmount);
    }

    function test_redeployExcess_revertsNoExcess() public {
        vm.expectRevert("sDIEM: no excess to redeploy");
        staking.redeployExcess();
    }

    function test_redeployExcess_respectsPendingWithdrawals() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Alice requests withdraw — starts pending
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Warp, claim from Venice — liquid = 100 (all pending returned)
        vm.warp(block.timestamp + 24 hours);
        staking.claimFromVenice();

        // Simulate excess: mint extra DIEM on top of what's reserved for pending
        uint256 excessAmount = DIEM_AMOUNT;
        diemToken.mint(address(staking), excessAmount);

        // liquid = 200 (100 from Venice + 100 minted), totalPendingWithdrawals = 100
        uint256 liquid = diemToken.balanceOf(address(staking));
        assertEq(liquid, 2 * DIEM_AMOUNT);
        assertEq(staking.totalPendingWithdrawals(), DIEM_AMOUNT);

        staking.redeployExcess();

        // Only excess redeployed, pending withdrawal DIEM stays liquid
        assertEq(diemToken.balanceOf(address(staking)), DIEM_AMOUNT); // 100 reserved for alice
    }

    // ── Views ───────────────────────────────────────────────────────────

    function test_views_withdrawalRequests() public {
        // Initially empty
        (uint256 amount, uint256 requestedAt) = staking.withdrawalRequests(alice);
        assertEq(amount, 0);
        assertEq(requestedAt, 0);

        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        (amount, requestedAt) = staking.withdrawalRequests(alice);
        assertEq(amount, DIEM_AMOUNT);
        assertEq(requestedAt, block.timestamp);
    }

    function test_views_veniceCooldownEnd() public {
        // Initially 0
        assertEq(staking.veniceCooldownEnd(), 0);

        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // Cooldown should be block.timestamp + 24h
        assertEq(staking.veniceCooldownEnd(), block.timestamp + 24 hours);
    }

    function test_views_WITHDRAWAL_DELAY() public view {
        assertEq(staking.WITHDRAWAL_DELAY(), 24 hours);
    }

    // ── notifyRewardAmount ──────────────────────────────────────────────

    function test_notifyRewardAmount_setsPeriod() public {
        usdcToken.mint(address(staking), REWARD_AMOUNT);

        vm.prank(operator);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        assertEq(staking.periodFinish(), block.timestamp + 24 hours);
        assertGt(staking.rewardRate(), 0);
    }

    function test_notifyRewardAmount_extendsExistingPeriod() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // First reward
        usdcToken.mint(address(staking), REWARD_AMOUNT);
        vm.prank(operator);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Wait 12 hours (half period)
        vm.warp(block.timestamp + 12 hours);

        // Second reward — extends with leftover
        usdcToken.mint(address(staking), REWARD_AMOUNT);
        vm.prank(operator);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        assertEq(staking.periodFinish(), block.timestamp + 24 hours);
    }

    function test_notifyRewardAmount_revertsNotOperator() public {
        usdcToken.mint(address(staking), REWARD_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: not operator");
        staking.notifyRewardAmount(REWARD_AMOUNT);
    }

    function test_notifyRewardAmount_revertsZeroReward() public {
        vm.prank(operator);
        vm.expectRevert("sDIEM: zero reward");
        staking.notifyRewardAmount(0);
    }

    function test_notifyRewardAmount_revertsInsufficientBalance() public {
        // Don't mint USDC — contract has no balance
        vm.prank(operator);
        vm.expectRevert("sDIEM: reward too high");
        staking.notifyRewardAmount(REWARD_AMOUNT);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function test_pause_unpause() public {
        vm.prank(admin);
        staking.pause();
        assertTrue(staking.paused());

        vm.prank(admin);
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_pause_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: not admin");
        staking.pause();
    }

    function test_setOperator() public {
        address newOp = makeAddr("newOp");

        vm.expectEmit(true, true, false, false);
        emit IsDIEM.OperatorChanged(operator, newOp);

        vm.prank(admin);
        staking.setOperator(newOp);

        assertEq(staking.operator(), newOp);
    }

    function test_setOperator_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("sDIEM: zero operator");
        staking.setOperator(address(0));
    }

    function test_setOperator_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: not admin");
        staking.setOperator(makeAddr("newOp"));
    }

    // ── Two-step admin transfer ───────────────────────────────────────────

    function test_transferAdmin() public {
        vm.prank(admin);
        staking.transferAdmin(bob);
        assertEq(staking.pendingAdmin(), bob);
        assertEq(staking.admin(), admin); // Not changed yet

        vm.prank(bob);
        staking.acceptAdmin();
        assertEq(staking.admin(), bob);
        assertEq(staking.pendingAdmin(), address(0));
    }

    function test_transferAdmin_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("sDIEM: zero admin");
        staking.transferAdmin(address(0));
    }

    function test_acceptAdmin_revertsWrongCaller() public {
        vm.prank(admin);
        staking.transferAdmin(bob);

        vm.prank(alice);
        vm.expectRevert("sDIEM: not pending admin");
        staking.acceptAdmin();
    }

    // ── Token recovery ────────────────────────────────────────────────────

    function test_recoverERC20() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(staking), 100e18);

        vm.prank(admin);
        staking.recoverERC20(address(randomToken), admin, 100e18);

        assertEq(randomToken.balanceOf(admin), 100e18);
    }

    function test_recoverERC20_cannotRecoverDiem() public {
        vm.prank(admin);
        vm.expectRevert("sDIEM: cannot recover DIEM");
        staking.recoverERC20(address(diemToken), admin, 100e18);
    }

    function test_recoverERC20_cannotRecoverUsdc() public {
        vm.prank(admin);
        vm.expectRevert("sDIEM: cannot recover USDC");
        staking.recoverERC20(address(usdcToken), admin, 100e6);
    }

    function test_recoverERC20_revertsZeroTo() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(staking), 100e18);

        vm.prank(admin);
        vm.expectRevert("sDIEM: zero to");
        staking.recoverERC20(address(randomToken), address(0), 100e18);
    }

    // ── Full Async Withdrawal Flow ──────────────────────────────────────

    function test_fullAsyncWithdrawalFlow() public {
        // 1. Alice stakes
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // 2. Seed rewards while staked
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 12 hours);

        // 3. Alice requests full withdrawal
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);

        // 4. Wait for delay + cooldown
        vm.warp(block.timestamp + 24 hours);

        // 5. Anyone claims from Venice
        staking.claimFromVenice();

        // 6. Alice completes withdrawal
        uint256 diemBefore = diemToken.balanceOf(alice);
        vm.prank(alice);
        staking.completeWithdraw();

        assertEq(diemToken.balanceOf(alice), diemBefore + DIEM_AMOUNT);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalPendingWithdrawals(), 0);

        // 7. Alice claims USDC rewards
        uint256 usdcBefore = usdcToken.balanceOf(alice);
        vm.prank(alice);
        staking.claimReward();
        assertGt(usdcToken.balanceOf(alice), usdcBefore);
    }

    function test_multiUserAsyncWithdrawal() public {
        // Alice and Bob both stake
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);
        vm.prank(bob);
        staking.stake(DIEM_AMOUNT);

        // Both request withdrawal
        vm.prank(alice);
        staking.requestWithdraw(DIEM_AMOUNT);
        vm.prank(bob);
        staking.requestWithdraw(DIEM_AMOUNT);

        assertEq(staking.totalPendingWithdrawals(), DIEM_AMOUNT * 2);

        // Wait and claim
        vm.warp(block.timestamp + 24 hours);
        staking.claimFromVenice();

        // Both complete
        vm.prank(alice);
        staking.completeWithdraw();
        vm.prank(bob);
        staking.completeWithdraw();

        assertEq(staking.totalPendingWithdrawals(), 0);
        assertEq(diemToken.balanceOf(alice), 1000e18); // full balance restored
        assertEq(diemToken.balanceOf(bob), 1000e18);
    }

    // ── Fuzz tests ──────────────────────────────────────────────────────

    function testFuzz_requestCompleteWithdraw(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, 1000e18);

        vm.prank(alice);
        staking.stake(stakeAmount);

        assertEq(staking.balanceOf(alice), stakeAmount);
        assertEq(staking.totalStaked(), stakeAmount);

        vm.prank(alice);
        staking.requestWithdraw(stakeAmount);

        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalPendingWithdrawals(), stakeAmount);

        vm.warp(block.timestamp + 24 hours);
        staking.claimFromVenice();

        vm.prank(alice);
        staking.completeWithdraw();

        assertEq(diemToken.balanceOf(alice), 1000e18);
        assertEq(staking.totalPendingWithdrawals(), 0);
    }

    function testFuzz_rewardAccrual(uint256 rewardAmount, uint256 elapsed) public {
        rewardAmount = bound(rewardAmount, 1e6, 1_000_000e6); // 1 to 1M USDC
        elapsed = bound(elapsed, 1, 24 hours);

        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        usdcToken.mint(address(staking), rewardAmount);
        vm.prank(operator);
        staking.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + elapsed);

        uint256 earned = staking.earned(alice);

        // Mirror the contract's exact integer math to compute expected
        uint256 rate = rewardAmount / 24 hours;
        uint256 rptDelta = (elapsed * rate * 1e18) / DIEM_AMOUNT; // totalStaked = DIEM_AMOUNT
        uint256 expected = (DIEM_AMOUNT * rptDelta) / 1e18;       // balance = DIEM_AMOUNT

        // Only rounding error is from the two integer divisions above: at most 1 unit each
        assertApproxEqAbs(earned, expected, 2);
    }

    function testFuzz_multiStakerFairness(uint256 aliceStake, uint256 bobStake) public {
        aliceStake = bound(aliceStake, 1e18, 500e18);
        bobStake = bound(bobStake, 1e18, 500e18);

        vm.prank(alice);
        staking.stake(aliceStake);
        vm.prank(bob);
        staking.stake(bobStake);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);

        // Total earned should approximate total reward (Synthetix truncation dust)
        assertApproxEqAbs(aliceEarned + bobEarned, REWARD_AMOUNT, REWARD_DUST);

        // Pro-rata check: alice/bob earned ratio ~ aliceStake/bobStake
        // Use cross-multiplication to avoid division-by-zero: aliceEarned * bobStake ≈ bobEarned * aliceStake
        if (aliceEarned > 0 && bobEarned > 0) {
            uint256 lhs = aliceEarned * bobStake;
            uint256 rhs = bobEarned * aliceStake;
            // Tolerance: 0.1% of the larger side
            uint256 tolerance = (lhs > rhs ? lhs : rhs) / 1000;
            assertApproxEqAbs(lhs, rhs, tolerance + 1);
        }
    }
}
