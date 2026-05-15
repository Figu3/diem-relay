// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEMv2} from "../src/sDIEMv2.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title sDIEMv2 unit tests
 * @notice Focuses on the v2 deltas: ERC-20 transferability, EIP-2612 permit,
 *         the reward-checkpoint hook on transfers, and queue-survives-transfer
 *         semantics. Plus regressions for the v1 audit fixes.
 */
contract sDIEMv2Test is Test {
    sDIEMv2 public staking;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);
        staking = new sDIEMv2(address(diemToken), address(usdcToken), admin, operator);

        diemToken.mint(alice, 1_000e18);
        diemToken.mint(bob, 1_000e18);
        vm.prank(alice);
        diemToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        diemToken.approve(address(staking), type(uint256).max);
    }

    // ── ERC-20 metadata ─────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(staking.name(), "Staked DIEM");
        assertEq(staking.symbol(), "sDIEM");
        assertEq(staking.decimals(), 18);
    }

    // ── stake mints 1:1 ─────────────────────────────────────────────────

    function test_stakeMintsOneToOne() public {
        vm.prank(alice);
        staking.stake(100e18);
        assertEq(staking.balanceOf(alice), 100e18);
        assertEq(staking.totalSupply(), 100e18);
        assertEq(staking.totalStaked(), 100e18);
    }

    // ── Transfer happy path ─────────────────────────────────────────────

    function test_transferMovesBalance() public {
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(alice);
        staking.transfer(bob, 40e18);

        assertEq(staking.balanceOf(alice), 60e18);
        assertEq(staking.balanceOf(bob), 40e18);
        assertEq(staking.totalSupply(), 100e18);
    }

    // ── The headline: transfer preserves earned (Synthetix trap absent) ─

    function test_transferPreservesEarned_freshRecipient() public {
        // Alice stakes, rewards accrue, then she transfers to fresh Bob.
        vm.prank(alice);
        staking.stake(100e18);

        _notifyReward(100e6);
        vm.warp(block.timestamp + 12 hours);

        uint256 aliceEarnedBefore = staking.earned(alice);
        uint256 bobEarnedBefore = staking.earned(bob); // should be 0
        assertEq(bobEarnedBefore, 0, "bob earned > 0 pre-transfer");
        assertGt(aliceEarnedBefore, 0, "alice didn't earn");

        vm.prank(alice);
        staking.transfer(bob, 50e18);

        // Immediately after transfer: alice keeps her accrued, bob has 0
        // accrued for the period he didn't hold sDIEM.
        assertApproxEqAbs(staking.earned(alice), aliceEarnedBefore, 1, "alice's earned changed");
        assertApproxEqAbs(staking.earned(bob), 0, 1, "bob phantom-earned after transfer");

        // Future earnings split 50/50 from now.
        vm.warp(block.timestamp + 6 hours);
        uint256 aliceLater = staking.earned(alice);
        uint256 bobLater = staking.earned(bob);
        assertGt(bobLater, 0, "bob didn't accrue post-transfer");
        // Same balance after transfer → similar accrual rate (within rounding)
        uint256 deltaAlice = aliceLater - aliceEarnedBefore;
        assertApproxEqAbs(deltaAlice, bobLater, 1, "post-transfer accrual asymmetric");
    }

    function test_transferToExistingHolderPreservesBoth() public {
        // Both Alice and Bob stake. Rewards accrue. Alice transfers to Bob.
        vm.prank(alice);
        staking.stake(60e18);
        vm.prank(bob);
        staking.stake(40e18);

        _notifyReward(100e6);
        vm.warp(block.timestamp + 12 hours);

        uint256 aliceBefore = staking.earned(alice);
        uint256 bobBefore = staking.earned(bob);
        assertGt(aliceBefore, bobBefore, "alice should out-earn bob 60:40");

        vm.prank(alice);
        staking.transfer(bob, 20e18);

        // Both retain their pre-transfer accruals.
        assertApproxEqAbs(staking.earned(alice), aliceBefore, 1, "alice lost accrued");
        assertApproxEqAbs(staking.earned(bob), bobBefore, 1, "bob over-credited");
    }

    function test_burnThenMintPreservesRewards() public {
        // Alice stakes, rewards accrue, transfers all to Bob, Bob transfers back.
        // Alice's claimable reward must be >= her pre-transfer accrual.
        vm.prank(alice);
        staking.stake(100e18);

        _notifyReward(100e6);
        vm.warp(block.timestamp + 12 hours);

        uint256 aliceEarnedBefore = staking.earned(alice);

        vm.prank(alice);
        staking.transfer(bob, 100e18);

        vm.prank(bob);
        staking.transfer(alice, 100e18);

        // Round-trip should preserve Alice's accrued (within tiny rounding).
        assertApproxEqAbs(staking.earned(alice), aliceEarnedBefore, 2, "round-trip leaked");
    }

    // ── Withdrawal queue does NOT move with sDIEM transfer ──────────────

    function test_queueStaysWithOriginalRequester() public {
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(alice);
        staking.requestWithdraw(40e18);

        // Alice has 60 sDIEM left + 40 queued.
        assertEq(staking.balanceOf(alice), 60e18);
        (uint256 aliceQueued,) = staking.withdrawalRequests(alice);
        assertEq(aliceQueued, 40e18);

        // Alice transfers her 60 sDIEM to Bob.
        vm.prank(alice);
        staking.transfer(bob, 60e18);

        // Bob receives 60 sDIEM with NO queue baggage.
        assertEq(staking.balanceOf(bob), 60e18);
        (uint256 bobQueued,) = staking.withdrawalRequests(bob);
        assertEq(bobQueued, 0, "queue transferred to Bob");

        // Alice has 0 sDIEM but still 40 queued.
        assertEq(staking.balanceOf(alice), 0);
        (aliceQueued,) = staking.withdrawalRequests(alice);
        assertEq(aliceQueued, 40e18, "alice's queue evaporated");
    }

    // ── EIP-2612 permit ─────────────────────────────────────────────────

    function test_permitGrantsAllowance() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        address spender = makeAddr("spender");

        // Owner stakes some DIEM to have an sDIEM balance.
        diemToken.mint(owner, 100e18);
        vm.prank(owner);
        diemToken.approve(address(staking), type(uint256).max);
        vm.prank(owner);
        staking.stake(100e18);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = staking.nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                50e18,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", staking.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        staking.permit(owner, spender, 50e18, deadline, v, r, s);
        assertEq(staking.allowance(owner, spender), 50e18);
        assertEq(staking.nonces(owner), nonce + 1);
    }

    // ── Withdrawal lifecycle ────────────────────────────────────────────

    function test_requestAndCompleteWithdraw() public {
        diemToken.setCooldownDuration(0);
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(alice);
        staking.requestWithdraw(40e18);

        vm.warp(block.timestamp + 24 hours);

        uint256 diemBefore = diemToken.balanceOf(alice);
        vm.prank(alice);
        staking.completeWithdraw();
        assertEq(diemToken.balanceOf(alice) - diemBefore, 40e18, "didn't get 40 DIEM");
    }

    function test_completeWithdrawRevertsBeforeDelay() public {
        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(alice);
        staking.requestWithdraw(10e18);

        vm.warp(block.timestamp + 23 hours); // 1h short
        vm.prank(alice);
        vm.expectRevert(bytes("sDIEMv2: withdrawal delay not met"));
        staking.completeWithdraw();
    }

    function test_cancelWithdrawReMints() public {
        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(alice);
        staking.requestWithdraw(40e18);

        assertEq(staking.balanceOf(alice), 60e18);

        vm.prank(alice);
        staking.cancelWithdraw();

        assertEq(staking.balanceOf(alice), 100e18, "cancel didn't re-mint");
        (uint256 pending,) = staking.withdrawalRequests(alice);
        assertEq(pending, 0, "queue not cleared");
    }

    function test_minWithdrawEnforced() public {
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(alice);
        vm.expectRevert(bytes("sDIEMv2: below minimum withdraw"));
        staking.requestWithdraw(0.5e18);
    }

    // ── Claim path ──────────────────────────────────────────────────────

    function test_claimRewardPaysOut() public {
        vm.prank(alice);
        staking.stake(100e18);

        _notifyReward(100e6);
        vm.warp(block.timestamp + 24 hours);

        uint256 earned = staking.earned(alice);
        assertGt(earned, 0, "alice didn't accrue");
        uint256 balBefore = usdcToken.balanceOf(alice);

        vm.prank(alice);
        staking.claimReward();

        assertGt(usdcToken.balanceOf(alice) - balBefore, 0, "got no USDC");
        assertEq(staking.earned(alice), 0, "earned not cleared");
    }

    // ── Exit always allowed (even when paused) ──────────────────────────

    function test_exitWorksEvenWhenPaused() public {
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(admin);
        staking.pause();

        // Stake is blocked
        vm.prank(bob);
        vm.expectRevert(bytes("sDIEMv2: paused"));
        staking.stake(10e18);

        // Exit still works
        vm.prank(alice);
        staking.exit();
        assertEq(staking.balanceOf(alice), 0);
        (uint256 pending,) = staking.withdrawalRequests(alice);
        assertEq(pending, 100e18);
    }

    // ── Two-step admin ──────────────────────────────────────────────────

    function test_twoStepAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        staking.transferAdmin(newAdmin);
        assertEq(staking.admin(), admin, "admin changed before accept");
        assertEq(staking.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        staking.acceptAdmin();
        assertEq(staking.admin(), newAdmin);
        assertEq(staking.pendingAdmin(), address(0));
    }

    // ── Recovery blacklist ──────────────────────────────────────────────

    function test_recoverDIEMBlocked() public {
        vm.prank(admin);
        vm.expectRevert(bytes("sDIEMv2: cannot recover DIEM"));
        staking.recoverERC20(address(diemToken), admin, 0);
    }

    function test_recoverUSDCBlocked() public {
        vm.prank(admin);
        vm.expectRevert(bytes("sDIEMv2: cannot recover USDC"));
        staking.recoverERC20(address(usdcToken), admin, 0);
    }

    function test_recoverArbitraryWorks() public {
        MockERC20 stranger = new MockERC20("STR", "STR", 18);
        stranger.mint(address(staking), 50e18);

        vm.prank(admin);
        staking.recoverERC20(address(stranger), admin, 50e18);
        assertEq(stranger.balanceOf(admin), 50e18);
    }

    // ── L-01: dust refund ───────────────────────────────────────────────

    function test_notifyRewardRefundsDust() public {
        vm.prank(alice);
        staking.stake(100e18);

        // Amount that doesn't divide cleanly into 24h.
        uint256 odd = 86_401; // 86400+1, leaves 1 wei dust
        usdcToken.mint(operator, odd);
        vm.startPrank(operator);
        usdcToken.approve(address(staking), odd);
        uint256 opBefore = usdcToken.balanceOf(operator);
        staking.notifyRewardAmount(odd);
        // L-01: at least some dust came back (rounding).
        // (Exact refund is rate * 24h vs `odd`.)
        uint256 spent = opBefore - usdcToken.balanceOf(operator);
        assertLt(spent, odd, "no dust refunded");
        vm.stopPrank();
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function _notifyReward(uint256 amount) internal {
        usdcToken.mint(operator, amount);
        vm.startPrank(operator);
        usdcToken.approve(address(staking), amount);
        staking.notifyRewardAmount(amount);
        vm.stopPrank();
    }
}
