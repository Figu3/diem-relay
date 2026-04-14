// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSDiem} from "./mocks/MockSDiem.sol";

/**
 * Invariant tests for RevenueSplitter.
 *
 * Properties:
 *   I1: After distribute(), USDC balance drops by exactly platformCut + stakerCut.
 *   I2: totalPlatformPaid / (totalPlatformPaid + totalStakerPaid) <= 2000/10000 at all times.
 *   I3: stakerCut per distribution >= (balanceAtCall * 8000) / 10000 (stakers never get less).
 *   I4: rescueToken can never remove USDC from the contract.
 */
contract RevenueSplitterInvariantTest is Test {
    RevenueSplitter internal splitter;
    MockERC20 internal usdc;
    MockSDiem internal sdiem;

    address internal admin = address(0xA11CE);
    address internal receiver = address(0xB0B);

    uint256 internal initialUsdcSnapshot;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        sdiem = new MockSDiem(usdc);
        splitter = new RevenueSplitter(usdc, IsDIEM(address(sdiem)), admin, receiver);

        // Hand operator role to splitter on mock sdiem
        sdiem.setOperator(address(splitter));

        // Seed contract with revenue
        usdc.mint(address(splitter), 10_000e6);

        targetContract(address(splitter));
    }

    // Invariant I2: platform share never exceeds 20%
    function invariant_platformShareCap() public view {
        uint256 total = splitter.totalPlatformPaid() + splitter.totalStakerPaid();
        if (total == 0) return;
        // platformPaid * 10000 <= total * 2000 (i.e. share <= 20%)
        assertLe(
            splitter.totalPlatformPaid() * 10_000,
            total * 2_000,
            "I2: platform share > 20%"
        );
    }

    // Invariant I4: USDC never drainable by admin
    function invariant_usdcNotRescuable() public {
        // Direct call must revert even if admin tries
        vm.prank(admin);
        vm.expectRevert();
        splitter.rescueToken(address(usdc), admin, 1);
    }
}
