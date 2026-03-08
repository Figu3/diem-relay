// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {sDIEM} from "../src/sDIEM.sol";

/**
 * @title DeploySDiem
 * @notice Deploys sDIEM to Base.
 *
 * Usage:
 *   DIEM=0xf4d97f2da56e8c3098f3a8d538db630a2606a024 \
 *   USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
 *   OPERATOR=0x... \
 *   forge script script/DeploySDiem.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Env:
 *   DIEM       — DIEM token address (has built-in staking)
 *   USDC       — USDC address on Base
 *   ADMIN      — Admin address (defaults to deployer)
 *   OPERATOR   — Operator address (manages Venice forward-staking + reward distribution)
 *   PRIVATE_KEY — Deployer private key
 */
contract DeploySDiem is Script {
    function run() external {
        address diem = vm.envOr("DIEM", address(0xF4d97F2da56e8c3098f3a8D538DB630A2606a024));
        address usdc = vm.envOr("USDC", address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913));
        address admin = vm.envOr("ADMIN", msg.sender);
        address operator = vm.envAddress("OPERATOR");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        console.log("Deploying sDIEM...");
        console.log("  diem:    ", diem);
        console.log("  usdc:    ", usdc);
        console.log("  admin:   ", admin);
        console.log("  operator:", operator);

        vm.startBroadcast(deployerKey);

        sDIEM staking = new sDIEM(diem, usdc, admin, operator);

        vm.stopBroadcast();

        console.log("");
        console.log("  sDIEM deployed at:", address(staking));
        console.log("");
        console.log("  Post-deploy checklist:");
        console.log("  1. Operator: call deployToVenice() to forward-stake buffer excess");
        console.log("  2. Operator: call notifyRewardAmount() with USDC to start rewards");
        console.log("  3. Verify on Basescan");
    }
}
