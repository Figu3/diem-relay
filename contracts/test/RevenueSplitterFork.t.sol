// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";

/**
 * Fork integration test.
 *
 * Runs against Base mainnet using a recent block. Verifies the full v3 flow:
 *   - Deploy splitter with real USDC and real sDIEM v2.
 *   - Admin Safe switches sDIEM v2 operator to the new splitter.
 *   - USDC transferred to splitter.
 *   - distribute() sends 10% to Safe, 90% to sDIEM v2 (rewardRate increases).
 */
contract RevenueSplitterForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // sDIEM v2 — the live staking contract the v3 splitter feeds.
    address constant SDIEM = 0x8065228a8156590A8BFca30678394e9db91f80Ee;
    address constant SAFE = 0x01Ea790410D9863A57771D992D2A72ea326DD7C9;

    RevenueSplitter internal splitter;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc);

        splitter = new RevenueSplitter(
            IERC20(USDC),
            IsDIEM(SDIEM),
            SAFE, // admin
            SAFE  // platformReceiver
        );

        // Impersonate Safe to set splitter as sDIEM operator
        vm.prank(SAFE);
        IsDIEM(SDIEM).setOperator(address(splitter));

        // If sDIEM is paused at the forked block, have the Safe unpause it.
        if (IsDIEM(SDIEM).paused()) {
            vm.prank(SAFE);
            IsDIEM(SDIEM).unpause();
        }
    }

    function test_fork_distributeEndToEnd() public {
        // Seed splitter with USDC from a whale / forced mint via deal
        uint256 revenue = 1_000e6;
        deal(USDC, address(splitter), revenue);

        uint256 safeBalBefore = IERC20(USDC).balanceOf(SAFE);
        uint256 sdiemBalBefore = IERC20(USDC).balanceOf(SDIEM);

        splitter.distribute();

        assertEq(
            IERC20(USDC).balanceOf(SAFE) - safeBalBefore,
            100e6,
            "Safe got 10%"
        );

        // Real sDIEM refunds rounding dust to the operator (splitter). The
        // delta on sDIEM is stakerCut minus that dust. Assert the invariant
        // that matters: sDIEM balance grew by approximately 90% and nothing
        // was lost (dust, if any, remains on the splitter for the next round).
        uint256 sdiemDelta = IERC20(USDC).balanceOf(SDIEM) - sdiemBalBefore;
        uint256 safeDelta = IERC20(USDC).balanceOf(SAFE) - safeBalBefore;
        uint256 splitterResidual = IERC20(USDC).balanceOf(address(splitter));

        assertEq(sdiemDelta + safeDelta + splitterResidual, revenue, "conservation");
        assertApproxEqAbs(sdiemDelta, 900e6, 1e6, "sDIEM got ~90%");
        assertGt(IsDIEM(SDIEM).rewardRate(), 0, "rewardRate set");
    }

    function test_fork_distributeAtFloor() public {
        // The 0.1 USDC default floor must clear on real sDIEM v2.
        uint256 revenue = 100_000; // 0.1 USDC
        deal(USDC, address(splitter), revenue);

        uint256 safeBalBefore = IERC20(USDC).balanceOf(SAFE);
        splitter.distribute();

        assertEq(IERC20(USDC).balanceOf(SAFE) - safeBalBefore, 10_000, "Safe got 10% of floor");
        assertGt(IsDIEM(SDIEM).rewardRate(), 0, "rewardRate set");
    }
}
