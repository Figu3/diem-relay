// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsDIEMv2} from "./IsDIEMv2.sol";

/**
 * @title IcsDIEMv2
 * @notice Compounding Staked DIEM v2 — canonical ERC-4626 wrapper over sDIEM v2.
 *
 * `asset() == sDIEM v2`. Mental model: wstETH over stETH.
 *
 *   deposit(sDIEMv2) → mint csDIEMv2 shares
 *   redeem(csDIEMv2) → burn shares, return sDIEMv2 (synchronous, standard 4626)
 *
 * harvest() claims USDC rewards from sDIEM v2, swaps USDC → DIEM via Slipstream
 * (TWAP-protected, Pashov-audited), then sdiem.stake(diem). Vault's sDIEM
 * balance grows → totalAssets() grows → share price ticks up monotonically.
 *
 * Includes a depositDIEM(uint256, address) zap for users holding raw DIEM —
 * the vault stakes into sDIEM internally and mints shares against the result.
 *
 * Composable with Pendle, Morpho/MetaMorpho, Spectra, Silo, and anything
 * expecting standard ERC-4626 semantics.
 */
interface IcsDIEMv2 is IERC4626 {
    // ── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when harvest converts USDC rewards into compounded DIEM.
    event Harvested(address indexed caller, uint256 usdcAmount, uint256 diemStaked);

    /// @notice Emitted when a user zap-deposits raw DIEM (vault stakes internally).
    event DepositZap(
        address indexed caller,
        address indexed receiver,
        uint256 diemIn,
        uint256 sdiemReceived,
        uint256 shares
    );

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);
    event OraclePoolUpdated(address indexed oldPool, address indexed newPool);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event TickSpacingUpdated(int24 oldSpacing, int24 newSpacing);
    event MinDiemPerUsdcUpdated(uint256 oldMin, uint256 newMin);
    event MinHarvestUpdated(uint256 oldMin, uint256 newMin);

    // ── Views ───────────────────────────────────────────────────────────────

    function sdiem() external view returns (IsDIEMv2);
    function diem() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Unclaimed USDC rewards accrued in sDIEM v2, available for harvest.
    function pendingHarvest() external view returns (uint256);

    // ── Harvest config ──────────────────────────────────────────────────────

    function swapRouter() external view returns (address);
    function oraclePool() external view returns (address);
    function twapWindow() external view returns (uint32);
    function tickSpacing() external view returns (int24);
    function maxSlippageBps() external view returns (uint256);
    function minDiemPerUsdc() external view returns (uint256);
    function minHarvest() external view returns (uint256);

    // ── Harvest (permissionless) ────────────────────────────────────────────

    /**
     * @notice Claim USDC from sDIEM v2, swap to DIEM, stake into sDIEM v2.
     * @param deadline Unix timestamp by which the underlying swap must execute.
     *        Caller-supplied at submission time (Pashov #1).
     */
    function harvest(uint256 deadline) external;

    // ── Zap deposit ─────────────────────────────────────────────────────────

    /**
     * @notice Deposit raw DIEM. Vault stakes it into sDIEM v2 internally
     *         and mints csDIEM v2 shares against the resulting sDIEM.
     * @param diemAmount Amount of DIEM to deposit (18 decimals).
     * @param receiver Recipient of the minted csDIEM v2 shares.
     * @return shares csDIEM v2 shares minted.
     */
    function depositDIEM(uint256 diemAmount, address receiver) external returns (uint256 shares);

    // ── Admin ───────────────────────────────────────────────────────────────

    function pause() external;
    function unpause() external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function setSwapRouter(address newRouter) external;
    function setMaxSlippage(uint256 newSlippage) external;
    function setOraclePool(address newPool) external;
    function setTwapWindow(uint32 newWindow) external;
    function setTickSpacing(int24 newSpacing) external;
    function setMinDiemPerUsdc(uint256 newMin) external;
    function setMinHarvest(uint256 newMin) external;

    /// @notice Recover tokens accidentally sent to the vault.
    /// @dev Cannot recover DIEM (harvest intermediate), USDC (harvest intermediate),
    ///      or sDIEM v2 (asset()).
    function recoverERC20(address token, address to, uint256 amount) external;
}
