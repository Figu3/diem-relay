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
        assertEq(diemToken.balanceOf(address(staking)), DIEM_AMOUNT);
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

    // ── Withdrawing ─────────────────────────────────────────────────────

    function test_withdraw_updatesBalances() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.withdraw(DIEM_AMOUNT);

        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(diemToken.balanceOf(alice), 1000e18); // full balance restored
    }

    function test_withdraw_partialAmount() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        staking.withdraw(DIEM_AMOUNT / 2);

        assertEq(staking.balanceOf(alice), DIEM_AMOUNT / 2);
        assertEq(staking.totalStaked(), DIEM_AMOUNT / 2);
    }

    function test_withdraw_revertsZeroAmount() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: zero amount");
        staking.withdraw(0);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: insufficient balance");
        staking.withdraw(DIEM_AMOUNT + 1);
    }

    function test_withdraw_allowedWhenPaused() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(admin);
        staking.pause();

        // Withdraw must succeed even when paused — users can always get funds out
        vm.prank(alice);
        staking.withdraw(DIEM_AMOUNT);
        assertEq(diemToken.balanceOf(alice), 1000e18); // back to initial mint
        assertEq(staking.totalStaked(), 0);
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

    // ── Exit ────────────────────────────────────────────────────────────

    function test_exit_withdrawsAndClaims() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        uint256 diemBefore = diemToken.balanceOf(alice);
        uint256 usdcBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(staking.balanceOf(alice), 0);
        assertEq(diemToken.balanceOf(alice), diemBefore + DIEM_AMOUNT);
        assertApproxEqAbs(
            usdcToken.balanceOf(alice) - usdcBefore,
            REWARD_AMOUNT,
            REWARD_DUST
        );
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

    // ── Venice forward-staking ──────────────────────────────────────────

    function test_deployToVenice_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Deploy 90% to Venice, leaving 10% buffer
        uint256 deployAmount = 90e18;
        vm.expectEmit(false, false, false, true);
        emit IsDIEM.DeployedToVenice(deployAmount);

        vm.prank(operator);
        staking.deployToVenice(deployAmount);

        assertEq(staking.liquidBuffer(), 10e18);
        assertEq(staking.forwardStaked(), 90e18);
        assertEq(staking.pendingUnstake(), 0);
        // totalStaked unchanged
        assertEq(staking.totalStaked(), DIEM_AMOUNT);
    }

    function test_deployToVenice_revertsZero() public {
        vm.prank(operator);
        vm.expectRevert("sDIEM: zero amount");
        staking.deployToVenice(0);
    }

    function test_deployToVenice_revertsNotOperator() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(alice);
        vm.expectRevert("sDIEM: not operator");
        staking.deployToVenice(10e18);
    }

    function test_deployToVenice_revertsInsufficientBuffer() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(operator);
        vm.expectRevert("sDIEM: insufficient buffer");
        staking.deployToVenice(DIEM_AMOUNT + 1);
    }

    function test_deployToVenice_revertsBufferFloor() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Buffer floor = 5% of totalStaked = 5e18
        // Deploying 96e18 would leave only 4e18 buffer (below 5e18 floor)
        vm.prank(operator);
        vm.expectRevert("sDIEM: would breach buffer floor");
        staking.deployToVenice(96e18);
    }

    function test_deployToVenice_maxDeployRespectsFloor() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Max deploy = 100 - 5% = 95e18
        vm.prank(operator);
        staking.deployToVenice(95e18);

        assertEq(staking.liquidBuffer(), 5e18);
        assertEq(staking.forwardStaked(), 95e18);
    }

    function test_initiateBufferReplenish_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(operator);
        staking.deployToVenice(90e18);

        vm.expectEmit(false, false, false, true);
        emit IsDIEM.BufferReplenishInitiated(50e18);

        vm.prank(operator);
        staking.initiateBufferReplenish(50e18);

        assertEq(staking.forwardStaked(), 40e18);
        assertEq(staking.pendingUnstake(), 50e18);
    }

    function test_initiateBufferReplenish_revertsZero() public {
        vm.prank(operator);
        vm.expectRevert("sDIEM: zero amount");
        staking.initiateBufferReplenish(0);
    }

    function test_initiateBufferReplenish_revertsNotOperator() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: not operator");
        staking.initiateBufferReplenish(10e18);
    }

    function test_completeBufferReplenish_success() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(operator);
        staking.deployToVenice(90e18);

        vm.prank(operator);
        staking.initiateBufferReplenish(50e18);

        // Warp past 24h cooldown
        vm.warp(block.timestamp + 24 hours);

        vm.prank(operator);
        staking.completeBufferReplenish();

        // Buffer replenished: 10 + 50 = 60
        assertEq(staking.liquidBuffer(), 60e18);
        assertEq(staking.forwardStaked(), 40e18);
        assertEq(staking.pendingUnstake(), 0);
    }

    function test_completeBufferReplenish_revertsDuringCooldown() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(operator);
        staking.deployToVenice(90e18);

        vm.prank(operator);
        staking.initiateBufferReplenish(50e18);

        // Don't warp — cooldown still active
        vm.prank(operator);
        vm.expectRevert("MockDIEM: cooldown active");
        staking.completeBufferReplenish();
    }

    function test_completeBufferReplenish_revertsNotOperator() public {
        vm.prank(alice);
        vm.expectRevert("sDIEM: not operator");
        staking.completeBufferReplenish();
    }

    function test_withdraw_revertsBufferInsufficient() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // Deploy 90 to Venice, leaving only 10 in buffer
        vm.prank(operator);
        staking.deployToVenice(90e18);

        // Alice tries to withdraw 20 but only 10 in buffer
        vm.prank(alice);
        vm.expectRevert("sDIEM: buffer insufficient");
        staking.withdraw(20e18);
    }

    function test_withdraw_succedsWithinBuffer() public {
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        vm.prank(operator);
        staking.deployToVenice(90e18);

        // Alice can withdraw up to buffer amount (10)
        vm.prank(alice);
        staking.withdraw(10e18);

        assertEq(staking.balanceOf(alice), 90e18);
        assertEq(staking.totalStaked(), 90e18);
    }

    function test_views_liquidBuffer_forwardStaked_pendingUnstake() public {
        // Initial: all zero
        assertEq(staking.liquidBuffer(), 0);
        assertEq(staking.forwardStaked(), 0);
        assertEq(staking.pendingUnstake(), 0);

        // After staking
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);
        assertEq(staking.liquidBuffer(), DIEM_AMOUNT);

        // After deploying
        vm.prank(operator);
        staking.deployToVenice(80e18);
        assertEq(staking.liquidBuffer(), 20e18);
        assertEq(staking.forwardStaked(), 80e18);

        // After initiating replenish
        vm.prank(operator);
        staking.initiateBufferReplenish(30e18);
        assertEq(staking.forwardStaked(), 50e18);
        assertEq(staking.pendingUnstake(), 30e18);

        // After completing replenish
        vm.warp(block.timestamp + 24 hours);
        vm.prank(operator);
        staking.completeBufferReplenish();
        assertEq(staking.liquidBuffer(), 50e18);
        assertEq(staking.forwardStaked(), 50e18);
        assertEq(staking.pendingUnstake(), 0);
    }

    function test_fullVeniceFlow() public {
        // 1. Alice stakes
        vm.prank(alice);
        staking.stake(DIEM_AMOUNT);

        // 2. Operator deploys to Venice
        vm.prank(operator);
        staking.deployToVenice(90e18);

        // 3. Seed rewards while staked on Venice
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 12 hours);

        // 4. Operator initiates buffer replenish
        vm.prank(operator);
        staking.initiateBufferReplenish(90e18);

        // 5. Wait for cooldown
        vm.warp(block.timestamp + 24 hours);

        // 6. Complete replenish
        vm.prank(operator);
        staking.completeBufferReplenish();

        // 7. Alice exits with all funds + rewards
        uint256 diemBefore = diemToken.balanceOf(alice);
        uint256 usdcBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(diemToken.balanceOf(alice), diemBefore + DIEM_AMOUNT);
        assertGt(usdcToken.balanceOf(alice), usdcBefore); // earned some USDC
        assertEq(staking.totalStaked(), 0);
    }

    // ── Fuzz tests ──────────────────────────────────────────────────────

    function testFuzz_stakeWithdraw(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, 1000e18);

        vm.prank(alice);
        staking.stake(stakeAmount);

        assertEq(staking.balanceOf(alice), stakeAmount);
        assertEq(staking.totalStaked(), stakeAmount);

        vm.prank(alice);
        staking.withdraw(stakeAmount);

        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(diemToken.balanceOf(alice), 1000e18);
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

    function testFuzz_deployToVenice(uint256 stakeAmount, uint256 deployAmount) public {
        stakeAmount = bound(stakeAmount, 10e18, 1000e18);

        vm.prank(alice);
        staking.stake(stakeAmount);

        // Max deployable respecting 5% buffer floor
        uint256 floor = (stakeAmount * 500) / 10000;
        uint256 maxDeploy = stakeAmount - floor;
        deployAmount = bound(deployAmount, 1, maxDeploy);

        vm.prank(operator);
        staking.deployToVenice(deployAmount);

        // Conservation: liquidBuffer + forwardStaked == totalStaked
        assertEq(
            staking.liquidBuffer() + staking.forwardStaked(),
            staking.totalStaked()
        );
    }
}
