// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsDIEM} from "./IsDIEM.sol";

/**
 * @title IcsDIEM
 * @notice Interface for Compounding Staked DIEM — auto-compounding wrapper over sDIEM.
 *
 * ERC-4626 vault: deposit DIEM → receive csDIEM shares.
 * All deposited DIEM is staked in sDIEM (which forward-stakes on Venice).
 * USDC rewards accrued in sDIEM are harvested, swapped to DIEM, and
 * restaked — compounding yield into a monotonically increasing share price.
 *
 * Composable with Pendle, Morpho, Silo, and any protocol accepting
 * yield-bearing ERC-4626 tokens.
 *
 * Redemptions require a 24h delay (matching sDIEM's withdrawal delay).
 * Standard ERC-4626 withdraw()/redeem() are disabled — use
 * requestRedeem()/completeRedeem() instead.
 */
interface IcsDIEM is IERC4626 {
    // ── Structs ─────────────────────────────────────────────────────────────

    struct RedemptionRequest {
        uint256 assets; // DIEM amount owed
        uint256 shares; // cumulative shares burned (for cancel re-mint)
        uint256 requestedAt;
    }

    // ── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when harvest converts USDC rewards into compounded DIEM.
    event Harvested(address indexed caller, uint256 usdcAmount, uint256 diemReceived);

    /// @notice Emitted when a user requests share redemption.
    event RedemptionRequested(address indexed user, uint256 shares, uint256 assets);

    /// @notice Emitted when a user completes redemption after delay.
    event RedemptionCompleted(address indexed user, uint256 assets);

    /// @notice Emitted when a user cancels a pending redemption.
    event RedemptionCancelled(address indexed user, uint256 assets, uint256 sharesMinted);

    /// @notice Emitted when excess liquid DIEM is restaked into sDIEM.
    event ExcessRedeployed(address indexed caller, uint256 amount);

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

    function sdiem() external view returns (IsDIEM);
    function usdc() external view returns (IERC20);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Total DIEM currently pending redemption across all users.
    function totalPendingRedemptions() external view returns (uint256);

    /// @notice Redemption request for a specific user.
    function redemptionRequests(address account) external view returns (uint256 assets, uint256 shares, uint256 requestedAt);

    /// @notice Check if a user can complete their redemption right now.
    function canCompleteRedeem(address account) external view returns (bool);

    /// @notice Unclaimed USDC rewards accrued in sDIEM, available for harvest.
    function pendingHarvest() external view returns (uint256);

    /// @notice Delay before redemptions can be completed.
    function WITHDRAWAL_DELAY() external view returns (uint256);

    // ── Harvest config ──────────────────────────────────────────────────────

    function swapRouter() external view returns (address);
    function oraclePool() external view returns (address);
    function twapWindow() external view returns (uint32);
    function tickSpacing() external view returns (int24);
    function maxSlippageBps() external view returns (uint256);
    function minDiemPerUsdc() external view returns (uint256);
    function minHarvest() external view returns (uint256);

    // ── Harvest (permissionless) ────────────────────────────────────────────

    /// @notice Claim USDC from sDIEM, swap to DIEM, restake. Anyone can call.
    function harvest() external;

    // ── Async Redemption ────────────────────────────────────────────────────

    /// @notice Request redemption of shares. Burns shares, starts 24h delay.
    /// @param shares Number of csDIEM shares to redeem.
    /// @return assets DIEM amount that will be claimable after delay.
    function requestRedeem(uint256 shares) external returns (uint256 assets);

    /// @notice Complete redemption after 24h delay.
    function completeRedeem() external;

    /// @notice Cancel pending redemption. Re-mints shares at current exchange rate.
    function cancelRedeem() external;

    // ── Permissionless ──────────────────────────────────────────────────────

    /// @notice Restake excess liquid DIEM (above pending redemptions) into sDIEM.
    function redeployExcess() external;

    /// @notice Ensure sDIEM withdrawal is initiated for pending redemptions. Anyone can call.
    function syncWithdrawals() external;

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
    /// @dev Cannot recover DIEM or USDC.
    function recoverERC20(address token, address to, uint256 amount) external;
}
