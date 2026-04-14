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
}
