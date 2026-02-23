// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DIEMVault} from "../src/DIEMVault.sol";

/**
 * @title DeployDIEMVault
 * @notice Deploys DIEMVault to target network.
 *
 * Usage:
 *   # Sepolia (with mock USDC)
 *   forge script script/DeployDIEMVault.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
 *
 * Env:
 *   DEPOSIT_TOKEN  — ERC20 token address (USDC or mock)
 *   ADMIN          — Admin address (defaults to deployer)
 */
contract DeployDIEMVault is Script {
    function run() external {
        address depositToken = vm.envAddress("DEPOSIT_TOKEN");
        address admin = vm.envOr("ADMIN", msg.sender);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        console.log("Deploying DIEMVault...");
        console.log("  depositToken:", depositToken);
        console.log("  admin:       ", admin);

        vm.startBroadcast(deployerKey);

        DIEMVault vault = new DIEMVault(depositToken, admin);

        vm.stopBroadcast();

        console.log("  DIEMVault deployed at:", address(vault));
        console.log("  minDeposit:  ", vault.minDeposit());
    }
}
