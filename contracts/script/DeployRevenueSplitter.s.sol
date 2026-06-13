// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";

/**
 * @title DeployRevenueSplitter
 * @notice Deploys RevenueSplitter to Base.
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   forge script script/DeployRevenueSplitter.s.sol \
 *     --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Env (all default to Base mainnet values):
 *   USDC            - defaults to 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   SDIEM           - defaults to sDIEM v2 0x8065228a8156590A8BFca30678394e9db91f80Ee
 *   ADMIN           - defaults to 2/2 Safe 0x01Ea...D7C9
 *   PLATFORM_RECV   - defaults to 2/2 Safe 0x01Ea...D7C9
 *   PRIVATE_KEY     - deployer key (required)
 *
 * Post-deploy:
 *   1. Safe signs: sDIEM.setOperator(splitter)   // moves operator off the old splitter
 *   2. atd updates cheaptokens.ai checkout to pay splitter address
 *   3. Once balance >= 0.1 USDC, anyone can call distribute()
 */
contract DeployRevenueSplitter is Script {
    address constant DEFAULT_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // sDIEM v2 — v3 splitter feeds the v2 staking contract, NOT v1 (0xdbF0...4be2)
    address constant DEFAULT_SDIEM = 0x8065228a8156590A8BFca30678394e9db91f80Ee;
    address constant DEFAULT_SAFE = 0x01Ea790410D9863A57771D992D2A72ea326DD7C9;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envOr("USDC", DEFAULT_USDC);
        address sdiem = vm.envOr("SDIEM", DEFAULT_SDIEM);
        address admin = vm.envOr("ADMIN", DEFAULT_SAFE);
        address receiver = vm.envOr("PLATFORM_RECV", DEFAULT_SAFE);

        console.log("Deploying RevenueSplitter");
        console.log("  deployer:  ", deployer);
        console.log("  USDC:      ", usdc);
        console.log("  sDIEM:     ", sdiem);
        console.log("  admin:     ", admin);
        console.log("  receiver:  ", receiver);

        vm.startBroadcast(deployerKey);
        RevenueSplitter splitter = new RevenueSplitter(
            IERC20(usdc),
            IsDIEM(sdiem),
            admin,
            receiver
        );
        vm.stopBroadcast();

        console.log("");
        console.log("  RevenueSplitter deployed at:", address(splitter));
        console.log("");
        console.log("  Next steps:");
        console.log("   1. Safe: call sDIEM.setOperator(splitter)");
        console.log("   2. atd: route cheaptokens.ai payments here");
        console.log("   3. Anyone: call distribute() once bal >= 0.1 USDC");
    }
}
