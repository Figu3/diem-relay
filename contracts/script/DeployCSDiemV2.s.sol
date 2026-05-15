// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {csDIEMv2} from "../src/csDIEMv2.sol";
import {IsDIEMv2} from "../src/interfaces/IsDIEMv2.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";

/**
 * @title DeployCSDiemV2
 * @notice Deploys csDIEM v2 (canonical ERC-4626 wrapper over sDIEM v2) to Base.
 *
 * Unlike csDIEM v1's deploy script, the minDiemPerUsdc floor is a constructor
 * arg in v2 (mandatory). No post-deploy "set the floor" step is needed.
 *
 * Required env:
 *   PRIVATE_KEY        — Deployer private key
 *   SDIEM              — sDIEM v2 contract address (the asset)
 *   SWAP_ROUTER        — Slipstream CL swap router
 *   ORACLE_POOL        — DIEM/USDC CL pool for TWAP
 *   TICK_SPACING       — Pool's tick spacing (must match ORACLE_POOL exactly)
 *   ADMIN              — csDIEM admin. Multisig recommended. Set to literal
 *                        string "DEPLOYER" to opt into deployer-as-admin.
 *   MIN_DIEM_PER_USDC  — Absolute price floor in DIEM base units per 1 USDC
 *                        (e.g. 1e18 for 1:1; tighter values are safer).
 *
 * Optional env (with safe defaults):
 *   DIEM             — DIEM token  (default: Base mainnet DIEM)
 *   USDC             — USDC token  (default: Base mainnet USDC)
 *   MAX_SLIPPAGE_BPS — Max slippage off TWAP   (default: 50 = 0.5%)
 *   TWAP_WINDOW      — TWAP arithmetic window  (default: 3600 = 1h)
 *   MIN_HARVEST      — Min USDC accrual to harvest (default: 100e6 = 100 USDC)
 *
 * Usage:
 *   PRIVATE_KEY=0x... SDIEM=0x... SWAP_ROUTER=0x... ORACLE_POOL=0x... \
 *   TICK_SPACING=100 ADMIN=0x01Ea790410D9863A57771D992D2A72ea326DD7C9 \
 *   MIN_DIEM_PER_USDC=500000000000000000 \
 *   forge script script/DeployCSDiemV2.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 * Verify (manual):
 *   forge verify-contract <ADDR> csDIEMv2 \
 *     --chain base --watch \
 *     --constructor-args $(cast abi-encode \
 *       "constructor(address,address,address,address,address,address,uint256,uint32,int24,uint256,uint256)" \
 *       <SDIEM> <DIEM> <USDC> <SWAP_ROUTER> <ORACLE_POOL> <ADMIN> <MAX_SLIPPAGE_BPS> \
 *       <TWAP_WINDOW> <TICK_SPACING> <MIN_HARVEST> <MIN_DIEM_PER_USDC>)
 */
contract DeployCSDiemV2 is Script {
    address constant DEFAULT_DIEM_BASE = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address constant DEFAULT_USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    string constant ADMIN_DEPLOYER_SENTINEL = "DEPLOYER";

    struct Params {
        address deployer;
        address diem;
        address sdiem;
        address usdc;
        address swapRouter;
        address oraclePool;
        address admin;
        uint256 maxSlippageBps;
        uint32 twapWindow;
        int24 tickSpacing;
        uint256 minHarvest;
        uint256 minDiemPerUsdc;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        Params memory p = _loadParams(vm.addr(deployerKey));

        _assertSdiemMatchesDiem(p.sdiem, p.diem);
        _assertOraclePoolPairs(p.oraclePool, p.diem, p.usdc, p.tickSpacing);

        _logConfig(p);

        vm.startBroadcast(deployerKey);
        csDIEMv2 vault = _deployAndInit(p);
        vm.stopBroadcast();

        _verifyDeployment(vault, p);
        _logResult(vault, p);
    }

    function _loadParams(address deployer) internal view returns (Params memory p) {
        p.deployer = deployer;
        p.diem = vm.envOr("DIEM", DEFAULT_DIEM_BASE);
        p.sdiem = vm.envAddress("SDIEM");
        p.usdc = vm.envOr("USDC", DEFAULT_USDC_BASE);
        p.swapRouter = vm.envAddress("SWAP_ROUTER");
        p.oraclePool = vm.envAddress("ORACLE_POOL");
        p.admin = _resolveAdmin(deployer);
        p.maxSlippageBps = vm.envOr("MAX_SLIPPAGE_BPS", uint256(50));
        p.twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(3600)));
        p.tickSpacing = int24(int256(vm.envUint("TICK_SPACING")));
        p.minHarvest = vm.envOr("MIN_HARVEST", uint256(100e6));
        p.minDiemPerUsdc = vm.envUint("MIN_DIEM_PER_USDC");

        require(p.minDiemPerUsdc > 0, "DeployCSDiemV2: MIN_DIEM_PER_USDC must be > 0");
        require(p.tickSpacing > 0, "DeployCSDiemV2: TICK_SPACING must be > 0");
    }

    function _deployAndInit(Params memory p) internal returns (csDIEMv2 vault) {
        // The floor is a constructor arg now, so we deploy directly with
        // the intended admin. No need for the v1 deployer-then-transfer dance.
        vault = new csDIEMv2(
            IsDIEMv2(p.sdiem),
            p.diem,
            p.usdc,
            p.swapRouter,
            p.oraclePool,
            p.admin,
            p.maxSlippageBps,
            p.twapWindow,
            p.tickSpacing,
            p.minHarvest,
            p.minDiemPerUsdc
        );
    }

    function _verifyDeployment(csDIEMv2 vault, Params memory p) internal view {
        require(address(vault.sdiem()) == p.sdiem, "DeployCSDiemV2: sdiem mismatch");
        require(address(vault.asset()) == p.sdiem, "DeployCSDiemV2: asset mismatch");
        require(address(vault.diem()) == p.diem, "DeployCSDiemV2: diem mismatch");
        require(address(vault.usdc()) == p.usdc, "DeployCSDiemV2: usdc mismatch");
        require(vault.swapRouter() == p.swapRouter, "DeployCSDiemV2: swapRouter mismatch");
        require(vault.oraclePool() == p.oraclePool, "DeployCSDiemV2: oraclePool mismatch");
        require(vault.maxSlippageBps() == p.maxSlippageBps, "DeployCSDiemV2: slippage mismatch");
        require(vault.twapWindow() == p.twapWindow, "DeployCSDiemV2: twapWindow mismatch");
        require(vault.tickSpacing() == p.tickSpacing, "DeployCSDiemV2: tickSpacing mismatch");
        require(vault.minHarvest() == p.minHarvest, "DeployCSDiemV2: minHarvest mismatch");
        require(vault.minDiemPerUsdc() == p.minDiemPerUsdc, "DeployCSDiemV2: minDiemPerUsdc mismatch");
        require(vault.totalAssets() == 0, "DeployCSDiemV2: nonzero totalAssets at deploy");
        require(vault.admin() == p.admin, "DeployCSDiemV2: admin mismatch");
    }

    function _logConfig(Params memory p) internal pure {
        console.log("Deploying csDIEM v2 (canonical 4626 over sDIEM v2)...");
        console.log("  deployer:        ", p.deployer);
        console.log("  diem:            ", p.diem);
        console.log("  sdiem (asset):   ", p.sdiem);
        console.log("  usdc:            ", p.usdc);
        console.log("  swapRouter:      ", p.swapRouter);
        console.log("  oraclePool:      ", p.oraclePool);
        console.log("  admin:           ", p.admin);
        console.log("  maxSlippageBps:  ", p.maxSlippageBps);
        console.log("  twapWindow (s):  ", uint256(p.twapWindow));
        console.log("  tickSpacing:     ", uint256(int256(p.tickSpacing)));
        console.log("  minHarvest:      ", p.minHarvest);
        console.log("  minDiemPerUsdc:  ", p.minDiemPerUsdc);
        if (p.admin == p.deployer) {
            console.log("  WARNING: admin == deployer EOA. Hand off to a Safe ASAP.");
        }
    }

    function _logResult(csDIEMv2 vault, Params memory p) internal view {
        console.log("");
        console.log("  csDIEM v2 deployed at:", address(vault));
        console.log("  decimals:             ", vault.decimals());
        console.log("");
        console.log("  Post-deploy checklist:");
        console.log("  1. Verify on Basescan (or rerun: forge verify-contract).");
        console.log("  2. Cross-check immutables: cast call <ADDR> sdiem(), asset(), minDiemPerUsdc()");
        console.log("  3. Test deposit() with a tiny amount of sDIEM to sanity-check share minting.");
        console.log("  4. Test depositDIEM() with a tiny amount of DIEM to sanity-check the zap.");
        console.log("  5. Once USDC accrues in sDIEM, test harvest(block.timestamp + 300).");
        if (p.admin == p.deployer) {
            console.log("  6. Transfer admin to a Safe via transferAdmin then acceptAdmin.");
        }
    }

    function _resolveAdmin(address deployer) internal view returns (address) {
        try vm.envString("ADMIN") returns (string memory adminStr) {
            if (keccak256(bytes(adminStr)) == keccak256(bytes(ADMIN_DEPLOYER_SENTINEL))) {
                return deployer;
            }
        } catch {
            revert("DeployCSDiemV2: ADMIN env required (address or 'DEPLOYER')");
        }
        return vm.envAddress("ADMIN");
    }

    function _assertSdiemMatchesDiem(address sdiem, address diem) internal view {
        require(
            address(IsDIEMv2(sdiem).diem()) == diem,
            "DeployCSDiemV2: sdiem.diem() != diem"
        );
    }

    function _assertOraclePoolPairs(
        address oraclePool,
        address diem,
        address usdcAddr,
        int24 expectedTickSpacing
    ) internal view {
        ICLPool pool = ICLPool(oraclePool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        bool tokensMatch =
            (t0 == diem && t1 == usdcAddr) ||
            (t0 == usdcAddr && t1 == diem);
        require(tokensMatch, "DeployCSDiemV2: oraclePool tokens != {DIEM, USDC}");
        require(
            pool.tickSpacing() == expectedTickSpacing,
            "DeployCSDiemV2: oraclePool tickSpacing mismatch"
        );
    }
}
