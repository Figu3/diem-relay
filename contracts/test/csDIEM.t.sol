// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {csDIEM} from "../src/csDIEM.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {IcsDIEM} from "../src/interfaces/IcsDIEM.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

contract csDIEMTest is Test {
    csDIEM public vault;
    sDIEM public stakingVault;
    MockDIEMStaking public diem;
    ERC20Mock public usdc;
    MockSwapRouter public router;
    MockCLPool public oracle;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INITIAL_BALANCE = 1000e18;
    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint256 constant REWARD_AMOUNT = 10e6; // 10 USDC (6 decimals)

    function setUp() public {
        diem = new MockDIEMStaking();
        usdc = new ERC20Mock();
        router = new MockSwapRouter(address(diem));
        oracle = new MockCLPool();

        // Deploy sDIEM
        stakingVault = new sDIEM(address(diem), address(usdc), admin, operator);

        // Deploy csDIEM wrapping sDIEM
        vault = new csDIEM(
            IERC20(address(diem)),
            address(stakingVault),
            address(usdc),
            address(router),
            address(oracle),
            admin,
            50,     // maxSlippageBps (0.5%)
            1800,   // twapWindow (30 min)
            1,      // tickSpacing
            1e6     // minHarvest (1 USDC)
        );

        // The absolute price floor is now mandatory (Pashov #3) — set a low
        // sentinel value here so existing harvest tests hit the relative TWAP
        // ceiling, not this floor. Real deployments must set a meaningful value.
        vm.prank(admin);
        vault.setMinDiemPerUsdc(1);

        // Fund users
        diem.mint(alice, INITIAL_BALANCE);
        diem.mint(bob, INITIAL_BALANCE);

        // Approvals for csDIEM
        vm.prank(alice);
        diem.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        diem.approve(address(vault), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /// @dev Seed USDC rewards into sDIEM so csDIEM has something to harvest.
    function _seedRewards(uint256 usdcAmount) internal {
        usdc.mint(operator, usdcAmount);
        vm.startPrank(operator);
        usdc.approve(address(stakingVault), usdcAmount);
        stakingVault.notifyRewardAmount(usdcAmount);
        vm.stopPrank();
    }

    // ── Constructor ─────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(vault.name(), "Compounding Staked DIEM");
        assertEq(vault.symbol(), "csDIEM");
        assertEq(vault.decimals(), 24); // 18 + 6 offset
        assertEq(vault.asset(), address(diem));
        assertEq(address(vault.sdiem()), address(stakingVault));
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.admin(), admin);
        assertFalse(vault.paused());
        assertEq(vault.maxSlippageBps(), 50);
        assertEq(vault.twapWindow(), 1800);
        assertEq(vault.tickSpacing(), 1);
        assertEq(vault.minHarvest(), 1e6);
    }

    function test_constructor_revert_zeroSdiem() public {
        vm.expectRevert("csDIEM: zero sdiem");
        new csDIEM(IERC20(address(diem)), address(0), address(usdc), address(router), address(oracle), admin, 50, 1800, 1, 1e6);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert("csDIEM: zero admin");
        new csDIEM(IERC20(address(diem)), address(stakingVault), address(usdc), address(router), address(oracle), address(0), 50, 1800, 1, 1e6);
    }

    // ── Deposit (ERC-4626) ──────────────────────────────────────────────

    function test_deposit_stakesInSdiem() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);

        // DIEM should be forwarded to sDIEM → Venice
        assertEq(diem.balanceOf(address(vault)), 0); // No liquid in csDIEM
        assertEq(stakingVault.balanceOf(address(vault)), DEPOSIT_AMOUNT); // In sDIEM
    }

    function test_mint() public {
        uint256 sharesToMint = 50e24;
        uint256 assetsNeeded = vault.previewMint(sharesToMint);

        vm.prank(alice);
        uint256 assets = vault.mint(sharesToMint, alice);

        assertEq(assets, assetsNeeded);
        assertEq(vault.balanceOf(alice), sharesToMint);
    }

    // ── Standard withdraw/redeem DISABLED ────────────────────────────────

    function test_standardRedeem_reverts() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, shares, 0)
        );
        vault.redeem(shares, alice, alice);
    }

    function test_standardWithdraw_reverts() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, 10e18, 0)
        );
        vault.withdraw(10e18, alice, alice);
    }

    function test_maxWithdraw_returnsZero() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_returnsZero() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(vault.maxRedeem(alice), 0);
    }

    // ── Harvest ─────────────────────────────────────────────────────────

    function test_harvest_compoundsRewards() public {
        // 1. Alice deposits 100 DIEM
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        uint256 totalBefore = vault.totalAssets();

        // 2. Seed USDC rewards into sDIEM
        _seedRewards(REWARD_AMOUNT);

        // 3. Wait for rewards to accrue (full 24h period)
        vm.warp(block.timestamp + 24 hours);

        // 4. Verify pending harvest
        uint256 pending = vault.pendingHarvest();
        assertGt(pending, 0);

        // 5. Harvest — claims USDC, swaps to DIEM, restakes
        vault.harvest(block.timestamp + 300);

        // 6. totalAssets should have increased
        assertGt(vault.totalAssets(), totalBefore);

        // 7. No USDC left in csDIEM (swapped to DIEM and restaked)
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_harvest_emitsEvent() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        vm.expectEmit(true, false, false, false);
        emit IcsDIEM.Harvested(address(this), 0, 0); // Don't check exact amounts

        vault.harvest(block.timestamp + 300);
    }

    function test_harvest_revertsIfBelowMinimum() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // No rewards seeded
        vm.expectRevert("csDIEM: below min harvest");
        vault.harvest(block.timestamp + 300);
    }

    function test_harvest_revertsWhenPaused() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        vm.prank(admin);
        vault.pause();

        vm.expectRevert("csDIEM: paused");
        vault.harvest(block.timestamp + 300);
    }

    function test_harvest_anyoneCanCall() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);

        // Bob can harvest (permissionless)
        vm.prank(bob);
        vault.harvest(block.timestamp + 300);
    }

    function test_harvest_increasesSharePrice() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 priceBefore = vault.convertToAssets(1e24);

        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);
        vault.harvest(block.timestamp + 300);

        uint256 priceAfter = vault.convertToAssets(1e24);
        assertGt(priceAfter, priceBefore);
    }

    // ── Request Redeem ──────────────────────────────────────────────────

    function test_requestRedeem_updatesState() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = vault.requestRedeem(shares);

        assertGt(assets, 0);
        assertApproxEqAbs(assets, DEPOSIT_AMOUNT, 1);

        // Shares burned
        assertEq(vault.balanceOf(alice), 0);

        // Pending redemption tracked
        (uint256 pendingAssets,, uint256 requestedAt) = vault.redemptionRequests(alice);
        assertEq(pendingAssets, assets);
        assertEq(requestedAt, block.timestamp);
        assertEq(vault.totalPendingRedemptions(), assets);
    }

    function test_requestRedeem_emitsEvent() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        uint256 expectedAssets = vault.previewRedeem(shares);

        vm.expectEmit(true, false, false, true);
        emit IcsDIEM.RedemptionRequested(alice, shares, expectedAssets);

        vm.prank(alice);
        vault.requestRedeem(shares);
    }

    function test_requestRedeem_revertsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert("csDIEM: zero shares");
        vault.requestRedeem(0);
    }

    function test_requestRedeem_revertsInsufficientShares() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert("csDIEM: insufficient shares");
        vault.requestRedeem(shares + 1);
    }

    function test_requestRedeem_accumulates() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 totalShares = vault.balanceOf(alice);
        uint256 firstBatch = totalShares / 3;
        uint256 secondBatch = totalShares / 3;

        // First request
        vm.prank(alice);
        uint256 assets1 = vault.requestRedeem(firstBatch);

        vm.warp(block.timestamp + 12 hours);
        uint256 newRequestedAt = block.timestamp;

        // Second request — accumulates, resets timer (prevents delay bypass)
        vm.prank(alice);
        uint256 assets2 = vault.requestRedeem(secondBatch);

        (uint256 pendingAssets,, uint256 requestedAt) = vault.redemptionRequests(alice);
        assertEq(pendingAssets, assets1 + assets2);
        assertEq(requestedAt, newRequestedAt); // Timer RESET to enforce fresh 24h delay
    }

    function test_requestRedeem_allowedWhenPaused() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(admin);
        vault.pause();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares); // Must not revert

        (uint256 amount,,) = vault.redemptionRequests(alice);
        assertGt(amount, 0);
    }

    function test_requestRedeem_initiatesSdiemWithdrawal() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        // sDIEM withdrawal should be initiated
        (uint256 sdiemPending,) = stakingVault.withdrawalRequests(address(vault));
        assertGt(sdiemPending, 0);
    }

    function test_requestRedeem_doesNotInflateSharePrice() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);

        uint256 priceBefore = vault.convertToAssets(1e24);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        uint256 priceAfter = vault.convertToAssets(1e24);
        assertApproxEqAbs(priceAfter, priceBefore, 1);
    }

    // ── Complete Redeem ──────────────────────────────────────────────────

    function test_completeRedeem_success() public {
        // Use instant cooldown for clean test
        diem.setCooldownDuration(0);

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.requestRedeem(shares);

        vm.warp(block.timestamp + 24 hours);

        uint256 balBefore = diem.balanceOf(alice);
        vm.prank(alice);
        vault.completeRedeem();

        assertEq(diem.balanceOf(alice), balBefore + assets);
        (uint256 pendingAssets,,) = vault.redemptionRequests(alice);
        assertEq(pendingAssets, 0);
        assertEq(vault.totalPendingRedemptions(), 0);
    }

    function test_completeRedeem_emitsEvent() public {
        diem.setCooldownDuration(0);

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.requestRedeem(shares);

        vm.warp(block.timestamp + 24 hours);

        vm.expectEmit(true, false, false, true);
        emit IcsDIEM.RedemptionCompleted(alice, assets);

        vm.prank(alice);
        vault.completeRedeem();
    }

    function test_completeRedeem_revertsNoRequest() public {
        vm.prank(alice);
        vm.expectRevert("csDIEM: no pending redemption");
        vault.completeRedeem();
    }

    function test_completeRedeem_revertsDelayNotMet() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(alice);
        vm.expectRevert("csDIEM: delay not met");
        vault.completeRedeem();
    }

    // ── Cancel Redeem ───────────────────────────────────────────────────

    function test_cancelRedeem_reMintSharesSoleStaker() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(sharesBefore);

        assertEq(vault.balanceOf(alice), 0);

        vm.prank(alice);
        vault.cancelRedeem();

        // Sole staker: totalSupply was 0, so stored shares are used
        assertEq(vault.balanceOf(alice), sharesBefore);
        assertEq(vault.totalPendingRedemptions(), 0);
    }

    function test_cancelRedeem_fewerSharesAfterHarvest() public {
        diem.setCooldownDuration(0);

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // Bob also deposits so vault has stakers
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceSharesBefore);

        // Harvest increases share price
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);
        vault.harvest(block.timestamp + 300);

        vm.prank(alice);
        vault.cancelRedeem();

        // Fewer shares re-minted because share price increased (anti-arbitrage fix)
        uint256 sharesAfter = vault.balanceOf(alice);
        assertLt(sharesAfter, aliceSharesBefore);
    }

    function test_cancelRedeem_revertsNoRequest() public {
        vm.prank(alice);
        vm.expectRevert("csDIEM: no pending redemption");
        vault.cancelRedeem();
    }

    function test_cancelRedeem_emitsEvent() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.requestRedeem(shares);

        // Sole staker → totalSupply == 0 → stored shares used
        vm.expectEmit(true, false, false, true);
        emit IcsDIEM.RedemptionCancelled(alice, assets, shares);

        vm.prank(alice);
        vault.cancelRedeem();
    }

    // ── Concurrent Redemptions (partial sDIEM withdrawal) ───────────────

    function test_concurrentRedemptions_noDeadlock() public {
        // Alice and Bob both deposit and redeem at different times.
        // With the timer-reset fix, _tryWithdrawFromSdiem skips if
        // an sDIEM withdrawal is already pending. After Alice completes,
        // syncWithdrawals() initiates Bob's portion.
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);

        // Alice redeems — auto-initiates Venice unstake via sDIEM
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        // Bob redeems 1 hour later — sDIEM withdrawal already pending, skipped
        vm.warp(block.timestamp + 1 hours);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobShares);

        // Wait for 24h delay (from Bob's request time, which reset the timer)
        vm.warp(block.timestamp + 24 hours);

        // Alice completes — partial sDIEM withdrawal gives her portion
        uint256 aliceDiemBefore = diem.balanceOf(alice);
        vm.prank(alice);
        vault.completeRedeem();
        assertGt(diem.balanceOf(alice), aliceDiemBefore);

        // Sync to initiate sDIEM withdrawal for Bob's portion (now no pending)
        vault.syncWithdrawals();

        // Bob waits for second Venice cooldown
        vm.warp(block.timestamp + 24 hours);

        uint256 bobDiemBefore = diem.balanceOf(bob);
        vm.prank(bob);
        vault.completeRedeem();
        assertGt(diem.balanceOf(bob), bobDiemBefore);

        // All redemptions cleared
        assertEq(vault.totalPendingRedemptions(), 0);
    }

    // ── Redeploy Excess ─────────────────────────────────────────────────

    function test_redeployExcess_success() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // Simulate excess liquid DIEM in csDIEM
        uint256 excessAmount = 50e18;
        diem.mint(address(vault), excessAmount);

        uint256 liquid = diem.balanceOf(address(vault));
        assertEq(liquid, excessAmount);

        vm.expectEmit(true, false, false, true);
        emit IcsDIEM.ExcessRedeployed(bob, excessAmount);

        vm.prank(bob);
        vault.redeployExcess();

        assertEq(diem.balanceOf(address(vault)), 0);
    }

    function test_redeployExcess_revertsNoExcess() public {
        vm.expectRevert("csDIEM: no excess");
        vault.redeployExcess();
    }

    // ── Sync Withdrawals ────────────────────────────────────────────────

    function test_syncWithdrawals_initiatesSdiemWithdrawal() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // Manually track: first request should auto-initiate
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        // Already initiated by requestRedeem
        (uint256 sdiemPending,) = stakingVault.withdrawalRequests(address(vault));
        assertGt(sdiemPending, 0);
    }

    // ── Pause ───────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert("csDIEM: paused");
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    function test_pause_blocksMint() public {
        vm.prank(admin);
        vault.pause();

        vm.expectRevert("csDIEM: paused");
        vm.prank(alice);
        vault.mint(1e24, alice);
    }

    function test_pause_revert_notAdmin() public {
        vm.expectRevert("csDIEM: not admin");
        vm.prank(alice);
        vault.pause();
    }

    function test_unpause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    // ── Admin transfer (two-step) ──────────────────────────────────────

    function test_transferAdmin_twoStep() public {
        vm.prank(admin);
        vault.transferAdmin(alice);

        assertEq(vault.admin(), admin);
        assertEq(vault.pendingAdmin(), alice);

        vm.expectRevert("csDIEM: not pending admin");
        vm.prank(bob);
        vault.acceptAdmin();

        vm.prank(alice);
        vault.acceptAdmin();

        assertEq(vault.admin(), alice);
        assertEq(vault.pendingAdmin(), address(0));
    }

    function test_transferAdmin_revert_zeroAddress() public {
        vm.expectRevert("csDIEM: zero admin");
        vm.prank(admin);
        vault.transferAdmin(address(0));
    }

    function test_transferAdmin_revert_notAdmin() public {
        vm.expectRevert("csDIEM: not admin");
        vm.prank(alice);
        vault.transferAdmin(bob);
    }

    // ── Admin config setters ────────────────────────────────────────────

    function test_setSwapRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        vault.setSwapRouter(newRouter);
        assertEq(vault.swapRouter(), newRouter);
    }

    function test_setSwapRouter_revert_zero() public {
        vm.expectRevert("csDIEM: zero router");
        vm.prank(admin);
        vault.setSwapRouter(address(0));
    }

    function test_setMaxSlippage() public {
        vm.prank(admin);
        vault.setMaxSlippage(100);
        assertEq(vault.maxSlippageBps(), 100);
    }

    function test_setMaxSlippage_revert_tooHigh() public {
        vm.expectRevert("csDIEM: slippage > 10%");
        vm.prank(admin);
        vault.setMaxSlippage(1001);
    }

    function test_setMinHarvest() public {
        vm.prank(admin);
        vault.setMinHarvest(5e6);
        assertEq(vault.minHarvest(), 5e6);
    }

    // ── Token recovery ─────────────────────────────────────────────────

    function test_recoverERC20() public {
        ERC20Mock randomToken = new ERC20Mock();
        randomToken.mint(address(vault), 500e18);

        vm.prank(admin);
        vault.recoverERC20(address(randomToken), admin, 500e18);

        assertEq(randomToken.balanceOf(admin), 500e18);
    }

    function test_recoverERC20_revert_cannotRecoverDiem() public {
        vm.expectRevert("csDIEM: cannot recover DIEM");
        vm.prank(admin);
        vault.recoverERC20(address(diem), admin, 1e18);
    }

    function test_recoverERC20_revert_cannotRecoverUsdc() public {
        vm.expectRevert("csDIEM: cannot recover USDC");
        vm.prank(admin);
        vault.recoverERC20(address(usdc), admin, 1e6);
    }

    function test_recoverERC20_revert_notAdmin() public {
        vm.expectRevert("csDIEM: not admin");
        vm.prank(alice);
        vault.recoverERC20(address(diem), alice, 1e18);
    }

    // ── Share price monotonicity ────────────────────────────────────────

    function test_sharePriceNeverDecreases() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        uint256 priceBefore = vault.convertToAssets(1e24);

        // Harvest
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);
        vault.harvest(block.timestamp + 300);

        uint256 priceAfterHarvest = vault.convertToAssets(1e24);
        assertGe(priceAfterHarvest, priceBefore);

        // Partial requestRedeem
        uint256 halfShares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.requestRedeem(halfShares);

        uint256 priceAfterRedeem = vault.convertToAssets(1e24);
        assertGe(priceAfterRedeem + 1, priceAfterHarvest);
    }

    // ── Full async redemption flow ──────────────────────────────────────

    function test_fullAsyncRedemptionFlow() public {
        diem.setCooldownDuration(0);

        // 1. Alice deposits
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);

        // 2. Seed and harvest (share price up)
        _seedRewards(REWARD_AMOUNT);
        vm.warp(block.timestamp + 24 hours);
        vault.harvest(block.timestamp + 300);

        uint256 totalAfterHarvest = vault.totalAssets();
        assertGt(totalAfterHarvest, DEPOSIT_AMOUNT);

        // 3. Alice requests full redeem
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.requestRedeem(shares);
        assertApproxEqAbs(assets, totalAfterHarvest, 1);

        // 4. Wait for delay
        vm.warp(block.timestamp + 24 hours);

        // 5. Complete redemption
        uint256 diemBefore = diem.balanceOf(alice);
        vm.prank(alice);
        vault.completeRedeem();

        assertApproxEqAbs(diem.balanceOf(alice) - diemBefore, assets, 1);
        assertEq(vault.totalPendingRedemptions(), 0);
    }

    function test_multiUserRedemption() public {
        diem.setCooldownDuration(0);

        // Alice and Bob deposit
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);

        // Alice requests redeem — auto-initiates sDIEM withdrawal
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceAssets = vault.requestRedeem(aliceShares);

        // Bob requests redeem — sDIEM withdrawal already pending, skipped
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.requestRedeem(bobShares);

        assertEq(vault.totalPendingRedemptions(), aliceAssets + bobAssets);

        vm.warp(block.timestamp + 24 hours);

        // Alice completes (auto-claims from sDIEM)
        vm.prank(alice);
        vault.completeRedeem();

        // Sync to initiate withdrawal for Bob's portion
        vault.syncWithdrawals();

        // Wait for Bob's sDIEM withdrawal delay
        vm.warp(block.timestamp + 24 hours);

        // Bob completes
        vm.prank(bob);
        vault.completeRedeem();

        assertEq(vault.totalPendingRedemptions(), 0);
        assertApproxEqAbs(diem.balanceOf(alice), INITIAL_BALANCE, 1);
        assertApproxEqAbs(diem.balanceOf(bob), INITIAL_BALANCE, 1);
    }

    // ── Fuzz tests ─────────────────────────────────────────────────────

    function testFuzz_depositRedeemRoundTrip(uint256 amount) public {
        diem.setCooldownDuration(0);
        amount = bound(amount, 1e18, INITIAL_BALANCE);

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        uint256 assetsBack = vault.requestRedeem(shares);

        assertApproxEqAbs(assetsBack, amount, 1);
        assertLe(assetsBack, amount); // Never more than deposited

        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        vault.completeRedeem();

        assertApproxEqAbs(diem.balanceOf(alice), INITIAL_BALANCE, 1);
    }

    function testFuzz_harvestIncreasesSharePrice(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, INITIAL_BALANCE);
        uint256 rewardAmount = 10e6; // Fixed 10 USDC to keep test focused

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 priceBefore = vault.convertToAssets(1e24);

        _seedRewards(rewardAmount);
        vm.warp(block.timestamp + 24 hours);
        vault.harvest(block.timestamp + 300);

        uint256 priceAfter = vault.convertToAssets(1e24);
        assertGe(priceAfter, priceBefore);
    }
}
