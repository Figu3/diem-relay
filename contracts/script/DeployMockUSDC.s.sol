// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @title DeployMockUSDC
 * @notice Deploys a mock USDC on testnet for testing DIEMVault.
 *
 * Usage:
 *   forge script script/DeployMockUSDC.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract DeployMockUSDC is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        MockERC20 usdc = new MockERC20("USD Coin (Mock)", "USDC", 6);

        // Mint 1M USDC to the deployer for testing
        usdc.mint(vm.addr(deployerKey), 1_000_000e6);

        vm.stopBroadcast();

        console.log("MockUSDC deployed at:", address(usdc));
        console.log("Minted 1,000,000 USDC to deployer");
    }
}
