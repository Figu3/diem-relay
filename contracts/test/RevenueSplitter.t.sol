// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IRevenueSplitter} from "../src/interfaces/IRevenueSplitter.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {csDIEM} from "../src/csDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";

contract RevenueSplitterTest is Test {
    RevenueSplitter public splitter;
    sDIEM public sdiem;
    csDIEM public csdiem;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;
    MockSwapRouter public router;
    MockAerodromePool public oraclePool;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INITIAL_SDIEM_BPS = 5000; // 50/50 split
    uint256 constant MIN_DISTRIBUTION = 100e6; // 100 USDC
    uint256 constant MAX_SLIPPAGE = 100; // 1%
    address constant AERO_FACTORY = address(0xAE40);
    uint256 constant TWAP_GRANULARITY = 4;

    function setUp() public {
        // Deploy mocks
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);
        router = new MockSwapRouter(address(diemToken));
        oraclePool = new MockAerodromePool();

        // Deploy staking contracts
        sdiem = new sDIEM(address(diemToken), address(usdcToken), admin, operator);
        csdiem = new csDIEM(IERC20(address(diemToken)), admin, operator);

        // Deploy splitter — it needs to be the operator on sDIEM to call notifyRewardAmount
        splitter = new RevenueSplitter(
            address(usdcToken),
            address(diemToken),
            address(sdiem),
            address(csdiem),
            address(router),
            address(oraclePool),
            AERO_FACTORY,
            admin,
            INITIAL_SDIEM_BPS,
            MIN_DISTRIBUTION,
            MAX_SLIPPAGE,
            TWAP_GRANULARITY
        );

        // Set splitter as operator on sDIEM so it can call notifyRewardAmount
        vm.prank(admin);
        sdiem.setOperator(address(splitter));

        // Seed stakers so rewards can be distributed
        diemToken.mint(alice, 10_000e18);
        vm.startPrank(alice);
        diemToken.approve(address(sdiem), type(uint256).max);
        diemToken.approve(address(csdiem), type(uint256).max);
        sdiem.stake(5_000e18);
        csdiem.deposit(5_000e18, alice);
        vm.stopPrank();

        // Instant cooldown for testing
        diemToken.setCooldownDuration(0);
    }

    // ── Constructor tests ───────────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(address(splitter.usdc()), address(usdcToken));
        assertEq(address(splitter.diem()), address(diemToken));
        assertEq(address(splitter.sdiem()), address(sdiem));
        assertEq(address(splitter.csdiem()), address(csdiem));
        assertEq(splitter.swapRouter(), address(router));
        assertEq(splitter.oraclePool(), address(oraclePool));
        assertEq(splitter.aeroFactory(), AERO_FACTORY);
        assertEq(splitter.twapGranularity(), TWAP_GRANULARITY);
        assertEq(splitter.admin(), admin);
        assertEq(splitter.sdiemBps(), INITIAL_SDIEM_BPS);
        assertEq(splitter.minDistribution(), MIN_DISTRIBUTION);
        assertEq(splitter.maxSlippageBps(), MAX_SLIPPAGE);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert("RevenueSplitter: zero usdc");
        new RevenueSplitter(address(0), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero diem");
        new RevenueSplitter(address(usdcToken), address(0), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero sdiem");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(0), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero csdiem");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(0), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero router");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(0), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero oracle pool");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(0), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero factory");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), address(0), admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);

        vm.expectRevert("RevenueSplitter: zero admin");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, address(0), 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);
    }

    function test_constructor_revertsOnZeroGranularity() public {
        vm.expectRevert("RevenueSplitter: zero granularity");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, MAX_SLIPPAGE, 0);
    }

    function test_constructor_revertsOnInvalidBps() public {
        vm.expectRevert("RevenueSplitter: bps > 10000");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 10001, MIN_DISTRIBUTION, MAX_SLIPPAGE, TWAP_GRANULARITY);
    }

    function test_constructor_revertsOnExcessiveSlippage() public {
        vm.expectRevert("RevenueSplitter: slippage > 10%");
        new RevenueSplitter(address(usdcToken), address(diemToken), address(sdiem), address(csdiem), address(router), address(oraclePool), AERO_FACTORY, admin, 5000, MIN_DISTRIBUTION, 1001, TWAP_GRANULARITY);
    }

    // ── Distribute tests ────────────────────────────────────────────────

    function test_distribute_splitsCorrectly() public {
        uint256 amount = 1000e6; // 1000 USDC
        usdcToken.mint(address(splitter), amount);

        uint256 sdiemUsdcBefore = usdcToken.balanceOf(address(sdiem));

        vm.prank(bob); // Anyone can call
        splitter.distribute();

        // sDIEM should have received 500 USDC
        assertEq(usdcToken.balanceOf(address(sdiem)), sdiemUsdcBefore + 500e6);

        // csDIEM should have received DIEM donation (500 USDC → 500 DIEM at 1:1 rate)
        // The donated DIEM is forwarded to Venice by csDIEM.donate()
    }

    function test_distribute_withAmount() public {
        uint256 total = 2000e6;
        usdcToken.mint(address(splitter), total);

        uint256 sdiemUsdcBefore = usdcToken.balanceOf(address(sdiem));

        vm.prank(bob);
        splitter.distribute(1000e6); // Only distribute half

        assertEq(usdcToken.balanceOf(address(sdiem)), sdiemUsdcBefore + 500e6);
        assertEq(usdcToken.balanceOf(address(splitter)), 1000e6); // Remaining
    }

    function test_distribute_allToSdiem() public {
        vm.prank(admin);
        splitter.setSplit(10000); // 100% to sDIEM

        uint256 amount = 1000e6;
        usdcToken.mint(address(splitter), amount);

        uint256 sdiemUsdcBefore = usdcToken.balanceOf(address(sdiem));

        splitter.distribute();

        assertEq(usdcToken.balanceOf(address(sdiem)), sdiemUsdcBefore + amount);
    }

    function test_distribute_allToCsdiem() public {
        vm.prank(admin);
        splitter.setSplit(0); // 0% to sDIEM = 100% to csDIEM

        uint256 amount = 1000e6;
        usdcToken.mint(address(splitter), amount);

        // All USDC should be swapped to DIEM and donated
        splitter.distribute();

        // Splitter should have 0 USDC left
        assertEq(usdcToken.balanceOf(address(splitter)), 0);
    }

    function test_distribute_revertsWhenBelowMinimum() public {
        usdcToken.mint(address(splitter), 50e6); // Below 100 USDC min

        vm.expectRevert("RevenueSplitter: below minimum");
        splitter.distribute();
    }

    function test_distribute_withAmount_revertsWhenBelowMinimum() public {
        usdcToken.mint(address(splitter), 200e6);

        vm.expectRevert("RevenueSplitter: below minimum");
        splitter.distribute(50e6);
    }

    function test_distribute_revertsWhenInsufficientBalance() public {
        usdcToken.mint(address(splitter), 100e6);

        vm.expectRevert("RevenueSplitter: insufficient balance");
        splitter.distribute(200e6);
    }

    function test_distribute_revertsWhenZeroAmount() public {
        vm.expectRevert("RevenueSplitter: zero amount");
        splitter.distribute(0);
    }

    function test_distribute_revertsWhenPaused() public {
        usdcToken.mint(address(splitter), 1000e6);

        vm.prank(admin);
        splitter.pause();

        vm.expectRevert("RevenueSplitter: paused");
        splitter.distribute();
    }

    function test_distribute_revertsWhenSwapFails() public {
        vm.prank(admin);
        splitter.setSplit(0); // 100% to csDIEM (forces swap)

        usdcToken.mint(address(splitter), 1000e6);
        router.setFailNextSwap(true);

        vm.expectRevert("RevenueSplitter: swap returned zero");
        splitter.distribute();
    }

    function test_distribute_emitsEvents() public {
        uint256 amount = 1000e6;
        usdcToken.mint(address(splitter), amount);

        vm.expectEmit(true, false, false, true);
        emit IRevenueSplitter.SwappedAndDonated(500e6, 500e18);

        vm.expectEmit(true, false, false, true);
        emit IRevenueSplitter.RevenueDistributed(address(this), amount, 500e6, 500e6);

        splitter.distribute();
    }

    function test_distribute_withDifferentExchangeRate() public {
        // 1 USDC = 0.5 DIEM (DIEM is more expensive)
        router.setExchangeRate(0.5e18);
        oraclePool.setTwapRate(0.5e18);

        uint256 amount = 1000e6;
        usdcToken.mint(address(splitter), amount);

        splitter.distribute();

        // Verify splitter is empty
        assertEq(usdcToken.balanceOf(address(splitter)), 0);
    }

    function test_pendingRevenue() public {
        assertEq(splitter.pendingRevenue(), 0);

        usdcToken.mint(address(splitter), 500e6);
        assertEq(splitter.pendingRevenue(), 500e6);
    }

    // ── Admin tests ─────────────────────────────────────────────────────

    function test_setSplit() public {
        vm.prank(admin);
        splitter.setSplit(7000);
        assertEq(splitter.sdiemBps(), 7000);
    }

    function test_setSplit_revertsOverMax() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: bps > 10000");
        splitter.setSplit(10001);
    }

    function test_setSplit_revertsNonAdmin() public {
        vm.prank(bob);
        vm.expectRevert("RevenueSplitter: not admin");
        splitter.setSplit(7000);
    }

    function test_setSwapRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        splitter.setSwapRouter(newRouter);
        assertEq(splitter.swapRouter(), newRouter);
    }

    function test_setSwapRouter_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: zero router");
        splitter.setSwapRouter(address(0));
    }

    function test_setMinDistribution() public {
        vm.prank(admin);
        splitter.setMinDistribution(500e6);
        assertEq(splitter.minDistribution(), 500e6);
    }

    function test_setMaxSlippage() public {
        vm.prank(admin);
        splitter.setMaxSlippage(200);
        assertEq(splitter.maxSlippageBps(), 200);
    }

    function test_setMaxSlippage_revertsOverMax() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: slippage > 10%");
        splitter.setMaxSlippage(1001);
    }

    function test_setOraclePool() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        splitter.setOraclePool(newPool);
        assertEq(splitter.oraclePool(), newPool);
    }

    function test_setOraclePool_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: zero oracle pool");
        splitter.setOraclePool(address(0));
    }

    function test_setTwapGranularity() public {
        vm.prank(admin);
        splitter.setTwapGranularity(8);
        assertEq(splitter.twapGranularity(), 8);
    }

    function test_setTwapGranularity_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: zero granularity");
        splitter.setTwapGranularity(0);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        splitter.pause();
        assertTrue(splitter.paused());

        vm.prank(admin);
        splitter.unpause();
        assertFalse(splitter.paused());
    }

    // ── Two-step admin transfer ─────────────────────────────────────────

    function test_transferAdmin() public {
        vm.prank(admin);
        splitter.transferAdmin(bob);
        assertEq(splitter.pendingAdmin(), bob);
        assertEq(splitter.admin(), admin); // Not changed yet

        vm.prank(bob);
        splitter.acceptAdmin();
        assertEq(splitter.admin(), bob);
        assertEq(splitter.pendingAdmin(), address(0));
    }

    function test_transferAdmin_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: zero admin");
        splitter.transferAdmin(address(0));
    }

    function test_acceptAdmin_revertsWrongCaller() public {
        vm.prank(admin);
        splitter.transferAdmin(bob);

        vm.prank(alice);
        vm.expectRevert("RevenueSplitter: not pending admin");
        splitter.acceptAdmin();
    }

    // ── Token recovery ──────────────────────────────────────────────────

    function test_recoverERC20() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(splitter), 100e18);

        vm.prank(admin);
        splitter.recoverERC20(address(randomToken), admin, 100e18);

        assertEq(randomToken.balanceOf(admin), 100e18);
    }

    function test_recoverERC20_cannotRecoverUsdc() public {
        usdcToken.mint(address(splitter), 100e6);

        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: cannot recover USDC");
        splitter.recoverERC20(address(usdcToken), admin, 100e6);
    }

    function test_recoverERC20_revertsZeroTo() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(splitter), 100e18);

        vm.prank(admin);
        vm.expectRevert("RevenueSplitter: zero to");
        splitter.recoverERC20(address(randomToken), address(0), 100e18);
    }

    // ── Integration: full flow ──────────────────────────────────────────

    function test_fullFlow_multipleDistributions() public {
        // Day 1: 1000 USDC revenue
        usdcToken.mint(address(splitter), 1000e6);
        splitter.distribute();

        // Warp past reward period
        vm.warp(block.timestamp + 24 hours + 1);

        // Day 2: 2000 USDC revenue
        usdcToken.mint(address(splitter), 2000e6);
        splitter.distribute();

        // Alice should have earned USDC from sDIEM
        uint256 earned = sdiem.earned(alice);
        assertGt(earned, 0, "Alice should have earned rewards");
    }
}
