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

    function test_distribute_splits20_80() public {
        usdc.mint(address(splitter), 1_000e6);

        vm.prank(anyone);
        splitter.distribute();

        assertEq(usdc.balanceOf(receiver), 200e6, "platform cut");
        assertEq(sdiem.totalNotified(), 800e6, "staker cut");
        assertEq(usdc.balanceOf(address(splitter)), 0, "no dust");
        assertEq(splitter.lastDistribution(), block.timestamp, "timestamp");
        assertEq(splitter.totalPlatformPaid(), 200e6);
        assertEq(splitter.totalStakerPaid(), 800e6);
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
        assertEq(splitter.totalPlatformPaid(), 400e6);
    }

    function test_distribute_firstCallHasNoCooldown() public {
        // lastDistribution == 0 initially, so first call should work
        usdc.mint(address(splitter), 1_000e6);
        splitter.distribute();
        assertGt(splitter.totalPlatformPaid(), 0);
    }

    function test_distribute_revertsBelowMinAmount() public {
        usdc.mint(address(splitter), 50e6); // default min is 100 USDC
        vm.expectRevert(bytes("RS: below min"));
        splitter.distribute();
    }

    function test_distribute_roundingDustGoesToStakers() public {
        // Use a balance that doesn't divide evenly by 10000
        // 1000.000001 USDC = 1_000_000_001
        usdc.mint(address(splitter), 1_000_000_001);
        splitter.distribute();

        // platformCut = (1_000_000_001 * 2000) / 10000 = 200_000_000 (truncated)
        // stakerCut  = 1_000_000_001 - 200_000_000 = 800_000_001 (gets the dust)
        assertEq(usdc.balanceOf(receiver), 200_000_000, "platform truncated");
        assertEq(sdiem.totalNotified(), 800_000_001, "staker gets dust");
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
        assertEq(usdc.balanceOf(receiver), 200e6);
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
    }

    function test_setCooldown_bounded() public {
        vm.prank(admin);
        splitter.setCooldown(12 hours);
        assertEq(splitter.cooldown(), 12 hours);

        vm.prank(admin);
        vm.expectRevert(bytes("RS: cooldown too high"));
        splitter.setCooldown(30 days);
    }
}
