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
 *   I2: totalPlatformPaid / (totalPlatformPaid + totalStakerPaid) <= MAX_PLATFORM_BPS/10000
 *       (20%) at all times — holds even if the admin retunes the split, because the
 *       setter is hard-capped. Stakers always keep >= 80%.
 *   I3: stakerCut per distribution >= (balanceAtCall * (10000 - platformBps)) / 10000.
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
        // Let the fuzzer act as admin so it can retune the split via
        // setPlatformBps — proves I2 (20% cap) holds even when the split moves.
        targetSender(admin);
    }

    // Invariant I2: platform share never exceeds the 20% hard cap, even if the
    // split is retuned mid-run (setter is bounded by MAX_PLATFORM_BPS).
    function invariant_platformShareCap() public view {
        uint256 total = splitter.totalPlatformPaid() + splitter.totalStakerPaid();
        if (total == 0) return;
        // platformPaid * 10000 <= total * MAX_PLATFORM_BPS (i.e. share <= 20%)
        assertLe(
            splitter.totalPlatformPaid() * 10_000,
            total * splitter.MAX_PLATFORM_BPS(),
            "I2: platform share > 20% cap"
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
