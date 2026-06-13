// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IRevenueSplitter} from "../src/interfaces/IRevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSDiem} from "./mocks/MockSDiem.sol";

contract RevenueSplitterTest is Test {
    RevenueSplitter internal splitter;
    MockERC20 internal usdc;
    MockSDiem internal sdiem;

    address internal admin = address(0xA11CE);
    address internal receiver = address(0xB0B);
    address internal anyone = address(0xCAFE);

    function setUp() public {
        // Warp past default cooldown so first distribute() isn't gated by
        // Foundry's default block.timestamp == 1.
        vm.warp(365 days);
        usdc = new MockERC20("USDC", "USDC", 6);
        sdiem = new MockSDiem(usdc);
        splitter = new RevenueSplitter(usdc, IsDIEM(address(sdiem)), admin, receiver);
        sdiem.setOperator(address(splitter));
    }

    function test_distribute_splits10_90() public {
        usdc.mint(address(splitter), 1_000e6);

        vm.prank(anyone);
        splitter.distribute();

        assertEq(usdc.balanceOf(receiver), 100e6, "platform cut");
        assertEq(sdiem.totalNotified(), 900e6, "staker cut");
        assertEq(usdc.balanceOf(address(splitter)), 0, "no dust");
        assertEq(splitter.lastDistribution(), block.timestamp, "timestamp");
        assertEq(splitter.totalPlatformPaid(), 100e6);
        assertEq(splitter.totalStakerPaid(), 900e6);
    }

    function test_distribute_revertsDuringCooldown() public {
        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();

        // Second distribution immediately → revert
        usdc.mint(address(splitter), 1_000e6);
        vm.expectRevert(bytes("RS: cooldown"));
        splitter.distribute();

        // Warp past cooldown → succeeds
        vm.warp(block.timestamp + 23 hours);
        splitter.distribute();
        assertEq(splitter.totalPlatformPaid(), 200e6); // 2 × 1000 USDC × 10%
    }

    function test_distribute_firstCallHasNoCooldown() public {
        // lastDistribution == 0 initially, so first call should work
        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();
        assertGt(splitter.totalPlatformPaid(), 0);
    }

    function test_distribute_revertsBelowMinAmount() public {
        usdc.mint(address(splitter), 50_000); // 0.05 USDC, default min is 0.1 USDC
        vm.expectRevert(bytes("RS: below min"));
        splitter.distribute();
    }

    function test_distribute_atFloorSucceeds() public {
        usdc.mint(address(splitter), 100_000); // exactly 0.1 USDC floor
        splitter.distribute();
        assertEq(usdc.balanceOf(receiver), 10_000, "platform 10% of 0.1 USDC");
        assertEq(sdiem.totalNotified(), 90_000, "staker 90% of 0.1 USDC");
    }

    function test_distribute_roundingDustGoesToStakers() public {
        // Use a balance that doesn't divide evenly by 10000
        // 1000.000001 USDC = 1_000_000_001
        usdc.mint(address(splitter), 1_000_000_001);
        splitter.distribute();

        // platformCut = (1_000_000_001 * 1000) / 10000 = 100_000_000 (truncated)
        // stakerCut  = 1_000_000_001 - 100_000_000 = 900_000_001 (gets the dust)
        assertEq(usdc.balanceOf(receiver), 100_000_000, "platform truncated");
        assertEq(sdiem.totalNotified(), 900_000_001, "staker gets dust");
    }

    function test_pause_blocksDistribute() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.prank(admin);
        splitter.pause();

        vm.expectRevert(bytes("RS: paused"));
        splitter.distribute();
    }

    function test_unpause_restoresDistribute() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.startPrank(admin);
        splitter.pause();
        splitter.unpause();
        vm.stopPrank();

        splitter.distribute();
        assertEq(usdc.balanceOf(receiver), 100e6);
    }

    function test_pause_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.pause();
    }

    function test_setPlatformReceiver_worksForAdmin() public {
        address newReceiver = address(0xFEED);
        vm.prank(admin);
        splitter.setPlatformReceiver(newReceiver);
        assertEq(splitter.platformReceiver(), newReceiver);
    }

    function test_setPlatformReceiver_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.setPlatformReceiver(address(0xFEED));
    }

    function test_setPlatformReceiver_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("RS: zero receiver"));
        splitter.setPlatformReceiver(address(0));
    }

    function test_setMinAmount_bounded() public {
        vm.prank(admin);
        splitter.setMinAmount(500e6);
        assertEq(splitter.minAmount(), 500e6);

        vm.prank(admin);
        vm.expectRevert(bytes("RS: min too high"));
        splitter.setMinAmount(20_000e6); // exceeds MIN_AMOUNT_CAP

        vm.prank(admin);
        vm.expectRevert(bytes("RS: min zero"));
        splitter.setMinAmount(0); // zero blocked to prevent no-op cooldown reset grief
    }

    function test_setCooldown_bounded() public {
        vm.prank(admin);
        splitter.setCooldown(12 hours);
        assertEq(splitter.cooldown(), 12 hours);

        vm.prank(admin);
        vm.expectRevert(bytes("RS: cooldown too high"));
        splitter.setCooldown(30 days);
    }

    function test_defaultPlatformBps_is10pct() public view {
        assertEq(splitter.platformBps(), 1_000);
    }

    function test_setPlatformBps_changesSplit() public {
        vm.prank(admin);
        splitter.setPlatformBps(2_000); // raise to 20% (at cap)
        assertEq(splitter.platformBps(), 2_000);

        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();
        assertEq(usdc.balanceOf(receiver), 200e6, "20% after raise");
        assertEq(sdiem.totalNotified(), 800e6, "80% to stakers");
    }

    function test_setPlatformBps_revertsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(bytes("RS: bps too high"));
        splitter.setPlatformBps(2_001); // one bp over the 20% cap
    }

    function test_setPlatformBps_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.setPlatformBps(1_500);
    }

    function test_setPlatformBps_allowsZero() public {
        vm.prank(admin);
        splitter.setPlatformBps(0); // 100% to stakers is allowed
        assertEq(splitter.platformBps(), 0);

        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();
        assertEq(usdc.balanceOf(receiver), 0, "no platform cut");
        assertEq(sdiem.totalNotified(), 1_000e6, "all to stakers");
    }

    function test_rescueToken_rescuesRandomToken() public {
        MockERC20 rando = new MockERC20("RND", "RND", 18);
        rando.mint(address(splitter), 1 ether);

        vm.prank(admin);
        splitter.rescueToken(address(rando), admin, 1 ether);

        assertEq(rando.balanceOf(admin), 1 ether);
        assertEq(rando.balanceOf(address(splitter)), 0);
    }

    function test_rescueToken_revertsForUSDC() public {
        usdc.mint(address(splitter), 1_000e6);
        vm.prank(admin);
        vm.expectRevert(bytes("RS: cannot rescue USDC"));
        splitter.rescueToken(address(usdc), admin, 1_000e6);
    }

    function test_rescueToken_revertsForNonAdmin() public {
        MockERC20 rando = new MockERC20("RND", "RND", 18);
        rando.mint(address(splitter), 1 ether);
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.rescueToken(address(rando), anyone, 1 ether);
    }

    function test_transferAdmin_twoStep() public {
        address newAdmin = address(0xD00D);

        vm.prank(admin);
        splitter.transferAdmin(newAdmin);
        assertEq(splitter.pendingAdmin(), newAdmin);
        assertEq(splitter.admin(), admin, "still old admin");

        vm.prank(newAdmin);
        splitter.acceptAdmin();
        assertEq(splitter.admin(), newAdmin);
        assertEq(splitter.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_revertsForNonPending() public {
        vm.prank(admin);
        splitter.transferAdmin(address(0xD00D));

        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not pending admin"));
        splitter.acceptAdmin();
    }

    function test_transferAdmin_revertsForNonAdmin() public {
        vm.prank(anyone);
        vm.expectRevert(bytes("RS: not admin"));
        splitter.transferAdmin(anyone);
    }

    function testFuzz_distribute_conservation(uint256 amount) public {
        amount = bound(amount, 100e6, 1e18); // min to ~1 trillion USDC
        usdc.mint(address(splitter), amount);
        splitter.distribute();

        uint256 platform = usdc.balanceOf(receiver);
        uint256 staker = sdiem.totalNotified();
        assertEq(platform + staker, amount, "conservation");
        assertEq(usdc.balanceOf(address(splitter)), 0, "no residual");
    }
}
