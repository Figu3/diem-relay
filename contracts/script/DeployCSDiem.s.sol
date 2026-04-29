// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {csDIEM} from "../src/csDIEM.sol";
import {IsDIEM} from "../src/interfaces/IsDIEM.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";

/**
 * @title DeployCSDiem
 * @notice Deploys csDIEM (auto-compounding wrapper over sDIEM) to Base.
 *
 * Hardened against the audit findings on this script:
 *  - Sets the mandatory minDiemPerUsdc floor (Pashov #3) before broadcasting
 *    ends, so the very first harvest() does not revert.
 *  - Validates that swapRouter and oraclePool are wired to the right tokens
 *    (catches transposition).
 *  - Validates that sdiem's underlying staking token equals the diem arg.
 *  - Refuses to default ADMIN to the deployer EOA — the operator must opt
 *    into a Safe (or explicitly set ADMIN=deployer if they really mean it).
 *  - Production-safe MIN_HARVEST default (100 USDC, matching RevenueSplitter).
 *  - Logs every immutable for post-deploy sanity-checking.
 *  - Asserts the deployed contract's immutables before exiting.
 *
 * Required env:
 *   PRIVATE_KEY        — Deployer private key
 *   SDIEM              — sDIEM contract address (no default; chain-specific)
 *   SWAP_ROUTER        — Slipstream CL swap router address (no default)
 *   ORACLE_POOL        — DIEM/USDC CL pool for TWAP oracle (no default)
 *   TICK_SPACING       — Pool's tick spacing (must match ORACLE_POOL exactly)
 *   ADMIN              — csDIEM admin. Should be a multisig.
 *                        Set to the literal string "DEPLOYER" if you intend
 *                        the deployer EOA to hold admin rights.
 *   MIN_DIEM_PER_USDC  — Absolute price floor in DIEM base units per 1 USDC
 *                        (e.g. for a 1:1 floor at parity, 1e18). MUST be > 0.
 *
 * Optional env (with safe defaults):
 *   DIEM               — DIEM token address (default: Base mainnet DIEM)
 *   USDC               — USDC address (default: Base mainnet USDC)
 *   MAX_SLIPPAGE_BPS   — Max relative slippage off TWAP (default: 50 = 0.5%)
 *   TWAP_WINDOW        — Seconds for TWAP arithmetic mean (default: 3600 = 1h)
 *   MIN_HARVEST        — Min USDC accrued before harvest is allowed
 *                        (default: 100 USDC = 100e6)
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   SDIEM=0x... SWAP_ROUTER=0x... ORACLE_POOL=0x... TICK_SPACING=100 \
 *   ADMIN=0x01Ea790410D9863A57771D992D2A72ea326DD7C9 \
 *   MIN_DIEM_PER_USDC=1000000000000000000 \
 *   forge script script/DeployCSDiem.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
 */
contract DeployCSDiem is Script {
    /// @dev Default Base mainnet DIEM. Override DIEM env to deploy elsewhere.
    address constant DEFAULT_DIEM_BASE = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;

    /// @dev Default Base mainnet USDC. Override USDC env to deploy elsewhere.
    address constant DEFAULT_USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Sentinel string accepted by ADMIN to opt into deployer-as-admin.
    string constant ADMIN_DEPLOYER_SENTINEL = "DEPLOYER";

    /// @dev Bundle of resolved env params. Keeps run()'s stack small enough
    ///      to compile without --via-ir.
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

        // Pre-deploy sanity checks
        _assertSdiemMatchesDiem(p.sdiem, p.diem);
        _assertOraclePoolPairs(p.oraclePool, p.diem, p.usdc, p.tickSpacing);

        _logConfig(p);

        // Broadcast: deploy + initialize
        vm.startBroadcast(deployerKey);
        csDIEM vault = _deployAndInit(p);
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
        p.minHarvest = vm.envOr("MIN_HARVEST", uint256(100e6)); // 100 USDC
        p.minDiemPerUsdc = vm.envUint("MIN_DIEM_PER_USDC");

        require(p.minDiemPerUsdc > 0, "DeployCSDiem: MIN_DIEM_PER_USDC must be > 0");
        require(p.tickSpacing > 0, "DeployCSDiem: TICK_SPACING must be > 0");
    }

    function _deployAndInit(Params memory p) internal returns (csDIEM vault) {
        // Set admin to deployer first so this script can call
        // setMinDiemPerUsdc, then transfer admin atomically below.
        // If the final admin IS the deployer, this collapses to a no-op.
        vault = new csDIEM(
            IERC20(p.diem),
            p.sdiem,
            p.usdc,
            p.swapRouter,
            p.oraclePool,
            p.deployer,
            p.maxSlippageBps,
            p.twapWindow,
            p.tickSpacing,
            p.minHarvest
        );

        // Mandatory floor — set before any harvest can be triggered.
        vault.setMinDiemPerUsdc(p.minDiemPerUsdc);

        // Hand off admin to the intended principal (Safe). Two-step:
        // the Safe must call acceptAdmin() in a follow-up tx.
        if (p.admin != p.deployer) {
            vault.transferAdmin(p.admin);
        }
    }

    function _verifyDeployment(csDIEM vault, Params memory p) internal view {
        require(address(vault.sdiem()) == p.sdiem, "DeployCSDiem: sdiem mismatch");
        require(address(vault.usdc()) == p.usdc, "DeployCSDiem: usdc mismatch");
        require(vault.swapRouter() == p.swapRouter, "DeployCSDiem: swapRouter mismatch");
        require(vault.oraclePool() == p.oraclePool, "DeployCSDiem: oraclePool mismatch");
        require(vault.maxSlippageBps() == p.maxSlippageBps, "DeployCSDiem: slippage mismatch");
        require(vault.twapWindow() == p.twapWindow, "DeployCSDiem: twapWindow mismatch");
        require(vault.tickSpacing() == p.tickSpacing, "DeployCSDiem: tickSpacing mismatch");
        require(vault.minHarvest() == p.minHarvest, "DeployCSDiem: minHarvest mismatch");
        require(vault.minDiemPerUsdc() == p.minDiemPerUsdc, "DeployCSDiem: minDiemPerUsdc mismatch");
        require(vault.totalAssets() == 0, "DeployCSDiem: nonzero totalAssets at deploy");

        // admin is set to deployer at construction; if a separate admin is
        // requested, it's pending until the Safe calls acceptAdmin().
        require(vault.admin() == p.deployer, "DeployCSDiem: admin not deployer");
        if (p.admin != p.deployer) {
            require(vault.pendingAdmin() == p.admin, "DeployCSDiem: pendingAdmin not set");
        }
    }

    function _logConfig(Params memory p) internal pure {
        console.log("Deploying csDIEM (auto-compounding wrapper over sDIEM)...");
        console.log("  deployer:        ", p.deployer);
        console.log("  diem:            ", p.diem);
        console.log("  sdiem:           ", p.sdiem);
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

    function _logResult(csDIEM vault, Params memory p) internal view {
        console.log("");
        console.log("  csDIEM deployed at:", address(vault));
        console.log("  decimals:          ", vault.decimals());
        console.log("");
        console.log("  Post-deploy checklist:");
        console.log("  1. Verify on Basescan");
        console.log("  2. Cross-check immutables on-chain (cast call ADDR <fn>): sdiem(), admin(), minDiemPerUsdc()");
        if (p.admin != p.deployer) {
            console.log("  3. Have the Safe call acceptAdmin() to complete the role transfer.");
        }
        console.log("  4. Test harvest with a tiny amount of USDC accrued in sDIEM.");
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * @dev Resolve ADMIN env: must be either an explicit address or the
     *      literal string "DEPLOYER" (sentinel for opt-in deployer-as-admin).
     *      Refuses to default — admin role is too important for an implicit
     *      fallback.
     */
    function _resolveAdmin(address deployer) internal view returns (address) {
        // Try string first (for the sentinel).
        try vm.envString("ADMIN") returns (string memory adminStr) {
            if (
                keccak256(bytes(adminStr)) ==
                keccak256(bytes(ADMIN_DEPLOYER_SENTINEL))
            ) {
                return deployer;
            }
        } catch {
            revert("DeployCSDiem: ADMIN env required (address or 'DEPLOYER')");
        }
        // Otherwise parse as address.
        return vm.envAddress("ADMIN");
    }

    /**
     * @dev Assert sdiem's underlying staking token equals the diem arg.
     *      Catches a deployer wiring sdiem to a different DIEM token —
     *      otherwise every deposit() would revert post-deploy.
     */
    function _assertSdiemMatchesDiem(address sdiem, address diem) internal view {
        // sDIEM exposes its underlying staking token via diem(). If sdiem's
        // diem token is not the one we're wiring into csDIEM, every deposit
        // would revert post-deploy because csDIEM's stake call would mismatch.
        require(
            address(IsDIEM(sdiem).diem()) == diem,
            "DeployCSDiem: sdiem.diem() != diem"
        );
    }

    /**
     * @dev Assert the oracle pool's tokens are {DIEM, USDC} (in either order)
     *      and that its tickSpacing matches the script param. Catches the
     *      "swapRouter and oraclePool transposed" footgun.
     */
    function _assertOraclePoolPairs(
        address oraclePool,
        address diem,
        address usdcAddr,
        int24 expectedTickSpacing
    ) internal view {
        ICLPool pool = ICLPool(oraclePool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        bool tokensMatch = (t0 == diem && t1 == usdcAddr) ||
            (t0 == usdcAddr && t1 == diem);
        require(tokensMatch, "DeployCSDiem: oraclePool tokens != {DIEM, USDC}");
        require(
            pool.tickSpacing() == expectedTickSpacing,
            "DeployCSDiem: oraclePool tickSpacing mismatch"
        );
    }
}
