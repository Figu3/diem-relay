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
 *   SDIEM           - defaults to 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2
 *   ADMIN           - defaults to 2/2 Safe 0x01Ea...D7C9
 *   PLATFORM_RECV   - defaults to 2/2 Safe 0x01Ea...D7C9
 *   PRIVATE_KEY     - deployer key (required)
 *
 * Post-deploy:
 *   1. Safe signs: sDIEM.setOperator(splitter)
 *   2. atd updates cheaptokens.ai checkout to pay splitter address
 *   3. Once balance >= 100 USDC, anyone can call distribute()
 */
contract DeployRevenueSplitter is Script {
    address constant DEFAULT_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant DEFAULT_SDIEM = 0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2;
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
        console.log("   3. Anyone: call distribute() once bal >= 100 USDC");
    }
}
