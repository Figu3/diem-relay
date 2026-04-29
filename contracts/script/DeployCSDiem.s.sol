// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {csDIEM} from "../src/csDIEM.sol";

/**
 * @title DeployCSDiem
 * @notice Deploys csDIEM (auto-compounding wrapper over sDIEM) to Base.
 *
 * Usage:
 *   DIEM=0xf4d97f2da56e8c3098f3a8d538db630a2606a024 \
 *   SDIEM=0x... \
 *   USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
 *   SWAP_ROUTER=0x... \
 *   ORACLE_POOL=0x... \
 *   forge script script/DeployCSDiem.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Env:
 *   DIEM         — DIEM token address
 *   SDIEM        — sDIEM contract address (base staking layer)
 *   USDC         — USDC address on Base
 *   SWAP_ROUTER  — Slipstream CL swap router
 *   ORACLE_POOL  — DIEM/USDC CL pool for TWAP oracle
 *   ADMIN        — Admin address (defaults to deployer)
 *   PRIVATE_KEY  — Deployer private key
 */
contract DeployCSDiem is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address diem = vm.envOr("DIEM", address(0xF4d97F2da56e8c3098f3a8D538DB630A2606a024));
        address sdiem = vm.envAddress("SDIEM");
        address usdcAddr = vm.envOr("USDC", address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address oraclePool = vm.envAddress("ORACLE_POOL");
        address admin = vm.envOr("ADMIN", deployer);

        uint256 maxSlippageBps = vm.envOr("MAX_SLIPPAGE_BPS", uint256(50));
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));
        int24 tickSpacingVal = int24(int256(vm.envOr("TICK_SPACING", uint256(1))));
        uint256 minHarvest = vm.envOr("MIN_HARVEST", uint256(1e6));

        console.log("Deploying csDIEM (auto-compounding wrapper over sDIEM)...");
        console.log("  diem:       ", diem);
        console.log("  sdiem:      ", sdiem);
        console.log("  usdc:       ", usdcAddr);
        console.log("  swapRouter: ", swapRouter);
        console.log("  oraclePool: ", oraclePool);
        console.log("  admin:      ", admin);

        vm.startBroadcast(deployerKey);

        csDIEM vault = new csDIEM(
            IERC20(diem),
            sdiem,
            usdcAddr,
            swapRouter,
            oraclePool,
            admin,
            maxSlippageBps,
            twapWindow,
            tickSpacingVal,
            minHarvest
        );

        vm.stopBroadcast();

        console.log("");
        console.log("  csDIEM deployed at:", address(vault));
        console.log("  decimals:          ", vault.decimals());
        console.log("");
        console.log("  Post-deploy checklist:");
        console.log("  1. Verify on Basescan");
        console.log("  2. Verify admin:  cast call", address(vault), "admin()");
        console.log("  3. Test harvest flow with small amount");
    }
}
