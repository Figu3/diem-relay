// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {sDIEMv2} from "../src/sDIEMv2.sol";

/**
 * @title DeploySDiemV2
 * @notice Deploys sDIEM v2 (ERC-20 + EIP-2612 + Synthetix rewards) to Base.
 *
 * Required env:
 *   PRIVATE_KEY — Deployer private key
 *
 * Optional env (with defaults):
 *   DIEM       — DIEM token address (default: Base mainnet DIEM)
 *   USDC       — USDC address      (default: Base mainnet USDC)
 *   ADMIN      — Admin address     (default: deployer)
 *   OPERATOR   — Operator address  (default: deployer)
 *
 * Usage:
 *   PRIVATE_KEY=0x... ADMIN=0x... OPERATOR=0x... \
 *   forge script script/DeploySDiemV2.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Verify (post-deploy, if --verify failed):
 *   forge verify-contract <ADDR> sDIEMv2 \
 *     --chain base --watch \
 *     --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
 *       <DIEM> <USDC> <ADMIN> <OPERATOR>)
 */
contract DeploySDiemV2 is Script {
    address constant DEFAULT_DIEM_BASE = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant DEFAULT_USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address diem = vm.envOr("DIEM", DEFAULT_DIEM_BASE);
        address usdc = vm.envOr("USDC", DEFAULT_USDC_BASE);
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address admin = vm.envOr("ADMIN", deployer);
        address operator = vm.envOr("OPERATOR", deployer);

        console.log("Deploying sDIEM v2...");
        console.log("  diem:    ", diem);
        console.log("  usdc:    ", usdc);
        console.log("  admin:   ", admin);
        console.log("  operator:", operator);
        if (admin == deployer) {
            console.log("  WARNING: admin == deployer EOA. Hand off to a Safe ASAP.");
        }

        vm.startBroadcast(deployerKey);
        sDIEMv2 staking = new sDIEMv2(diem, usdc, admin, operator);
        vm.stopBroadcast();

        // Post-deploy assertions
        require(address(staking.diem()) == diem, "sdiem.diem() mismatch");
        require(address(staking.usdc()) == usdc, "sdiem.usdc() mismatch");
        require(staking.admin() == admin, "sdiem.admin() mismatch");
        require(staking.operator() == operator, "sdiem.operator() mismatch");
        require(staking.totalSupply() == 0, "sdiem.totalSupply() != 0");
        require(
            keccak256(bytes(staking.symbol())) == keccak256(bytes("sDIEM")),
            "sdiem.symbol() mismatch"
        );

        console.log("");
        console.log("  sDIEM v2 deployed at:", address(staking));
        console.log("");
        console.log("  Post-deploy checklist:");
        console.log("  1. Verify on Basescan (or rerun: forge verify-contract).");
        console.log("  2. Operator: deposit a tiny stake from the admin Safe to sanity-check Venice forwarding.");
        console.log("  3. Operator: call notifyRewardAmount(<USDC>) to seed the first reward period.");
        console.log("  4. Cross-check immutables: cast call <ADDR> diem(), usdc(), admin(), operator()");
    }
}
