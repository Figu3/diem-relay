// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {sDIEMv2} from "../src/sDIEMv2.sol";
import {csDIEMv2} from "../src/csDIEMv2.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

/**
 * @title sDIEM ↔ csDIEM v2 integration
 * @notice End-to-end roundtrip: deposit DIEM (via zap) → harvest cycle →
 *         standard 4626 redeem to sDIEM → sDIEM → DIEM unstake.
 *
 *         This is the path Pendle/Morpho/Spectra/Silo will follow when they
 *         integrate. Each step uses the canonical interface.
 */
contract DiemV2IntegrationTest is Test {
    sDIEMv2 public s;
    csDIEMv2 public cs;
    MockDIEMStaking public diem;
    MockERC20 public usdc;
    MockSwapRouter public router;
    MockCLPool public oracle;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    function setUp() public {
        diem = new MockDIEMStaking();
        usdc = new MockERC20("USDC", "USDC", 6);
        router = new MockSwapRouter(address(diem));
        oracle = new MockCLPool();
        oracle.setMeanTick(276324);

        s = new sDIEMv2(address(diem), address(usdc), admin, operator);
        cs = new csDIEMv2(
            s,
            address(diem),
            address(usdc),
            address(router),
            address(oracle),
            admin,
            50,
            1800,
            1,
            1e6,
            5e17
        );

        diem.mint(alice, 1_000e18);
        vm.startPrank(alice);
        diem.approve(address(s), type(uint256).max);
        diem.approve(address(cs), type(uint256).max);
        s.approve(address(cs), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Full roundtrip via the zap and standard 4626 redeem.
    function test_zapDepositHarvestRedeem() public {
        // 1. Alice zaps 100 DIEM into csDIEM v2.
        vm.prank(alice);
        uint256 shares = cs.depositDIEM(100e18, alice);
        assertGt(shares, 0);
        assertEq(s.balanceOf(address(cs)), 100e18, "vault holds sDIEM 1:1");

        uint256 priceBefore = cs.convertToAssets(1e24);

        // 2. Operator notifies USDC rewards on sDIEM, time passes, harvest.
        usdc.mint(operator, 100e6);
        vm.startPrank(operator);
        usdc.approve(address(s), 100e6);
        s.notifyRewardAmount(100e6);
        vm.stopPrank();
        vm.warp(block.timestamp + 24 hours);

        cs.harvest(block.timestamp + 300);

        uint256 priceAfter = cs.convertToAssets(1e24);
        assertGt(priceAfter, priceBefore, "harvest didn't compound");

        // 3. Alice redeems shares synchronously (the v2 composability win).
        uint256 sdiemBefore = s.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = cs.redeem(shares, alice, alice);
        assertGt(assets, 100e18, "alice should redeem MORE sDIEM than she deposited (compounded)");
        assertEq(s.balanceOf(alice) - sdiemBefore, assets);

        // 4. Alice unstakes sDIEM → DIEM (standard sDIEM v2 flow, 24h delay).
        diem.setCooldownDuration(0);
        vm.prank(alice);
        s.requestWithdraw(assets);
        vm.warp(block.timestamp + 24 hours);
        uint256 diemBefore = diem.balanceOf(alice);
        vm.prank(alice);
        s.completeWithdraw();
        assertGt(diem.balanceOf(alice) - diemBefore, 100e18, "alice didn't receive more DIEM than deposited");
    }

    /// @notice Path where the user holds sDIEM already (the lender path).
    function test_canonicalDepositRedeem() public {
        // Lender wraps sDIEM into csDIEM v2 — the integration story.
        vm.prank(alice);
        s.stake(100e18);
        assertEq(s.balanceOf(alice), 100e18);

        vm.prank(alice);
        uint256 shares = cs.deposit(100e18, alice);
        assertEq(cs.balanceOf(alice), shares);
        assertEq(s.balanceOf(alice), 0, "alice's sDIEM not consumed");
        assertEq(s.balanceOf(address(cs)), 100e18);

        // maxRedeem is the real share count (was 0 in v1).
        assertEq(cs.maxRedeem(alice), shares);

        // Redeem returns sDIEM 1:1 (no harvest yet → no compounding).
        vm.prank(alice);
        uint256 assets = cs.redeem(shares, alice, alice);
        assertEq(assets, 100e18);
        assertEq(s.balanceOf(alice), 100e18);
    }

    /// @notice After redeeming csDIEM v2, the user holds sDIEM v2 — which is
    ///         a fully transferable ERC-20. Verify that path works.
    function test_redeemThenTransferSdiem() public {
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        cs.depositDIEM(100e18, alice);
        uint256 shares = cs.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = cs.redeem(shares, alice, alice);

        // Now alice holds sDIEM and can transfer it (the v2 unlock).
        vm.prank(alice);
        s.transfer(recipient, assets / 2);
        assertEq(s.balanceOf(recipient), assets / 2);
        assertEq(s.balanceOf(alice), assets - assets / 2);
    }
}
