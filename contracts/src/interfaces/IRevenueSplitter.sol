// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRevenueSplitter
 * @notice Interface for the permissionless revenue distribution contract.
 *
 * Receives USDC revenue from Venice compute credit operations and splits it:
 *   - sDIEM portion: USDC transferred + notifyRewardAmount() called
 *   - csDIEM portion: USDC swapped to DIEM via DEX, then donated to csDIEM vault
 *
 * `distribute()` is fully permissionless — anyone can trigger it when
 * the contract holds USDC above the minimum threshold.
 */
interface IRevenueSplitter {
    // ── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when revenue is distributed to sDIEM and csDIEM.
    event RevenueDistributed(
        address indexed caller,
        uint256 totalUsdc,
        uint256 toSDiem,
        uint256 toCsDiem
    );

    /// @notice Emitted when USDC is swapped to DIEM for csDIEM donation.
    event SwappedAndDonated(uint256 usdcIn, uint256 diemOut);

    /// @notice Emitted when admin updates the split ratio.
    event SplitUpdated(uint256 oldSdiemBps, uint256 newSdiemBps);

    /// @notice Emitted when admin updates the swap router.
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /// @notice Emitted when admin updates the minimum distribution amount.
    event MinDistributionUpdated(uint256 oldMin, uint256 newMin);

    /// @notice Emitted when admin updates the max slippage.
    event MaxSlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    /// @notice Emitted when admin updates the oracle pool.
    event OraclePoolUpdated(address indexed oldPool, address indexed newPool);

    /// @notice Emitted when admin updates the TWAP window.
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);

    /// @notice Emitted when admin updates the tick spacing for CL swaps.
    event TickSpacingUpdated(int24 oldSpacing, int24 newSpacing);

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    // ── Views ───────────────────────────────────────────────────────────────

    /// @notice Basis points of USDC going to sDIEM (remainder goes to csDIEM).
    function sdiemBps() external view returns (uint256);

    /// @notice Minimum USDC balance required to trigger distribution.
    function minDistribution() external view returns (uint256);

    /// @notice Maximum slippage allowed on USDC→DIEM swap (in bps).
    function maxSlippageBps() external view returns (uint256);

    /// @notice The DEX router used for USDC→DIEM swaps.
    function swapRouter() external view returns (address);

    /// @notice Slipstream CL pool used for TWAP oracle queries.
    function oraclePool() external view returns (address);

    /// @notice TWAP window in seconds for CL oracle queries.
    function twapWindow() external view returns (uint32);

    /// @notice Tick spacing of the DIEM/USDC CL pool for swap routing.
    function tickSpacing() external view returns (int24);

    /// @notice Current USDC balance available for distribution.
    function pendingRevenue() external view returns (uint256);

    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function paused() external view returns (bool);

    // ── Permissionless ──────────────────────────────────────────────────────

    /// @notice Distribute all held USDC according to the split.
    ///         Anyone can call when balance >= minDistribution.
    function distribute() external;

    /// @notice Distribute a specific amount of USDC.
    /// @param amount USDC amount to distribute (must be <= balance).
    function distribute(uint256 amount) external;

    // ── Admin ───────────────────────────────────────────────────────────────

    /// @notice Set the sDIEM/csDIEM split ratio.
    /// @param newSdiemBps Basis points for sDIEM (0-10000). Remainder goes to csDIEM.
    function setSplit(uint256 newSdiemBps) external;

    /// @notice Set the DEX router for USDC→DIEM swaps.
    function setSwapRouter(address newRouter) external;

    /// @notice Set minimum USDC for permissionless distribution.
    function setMinDistribution(uint256 newMin) external;

    /// @notice Set maximum slippage for swaps (in bps).
    function setMaxSlippage(uint256 newSlippage) external;

    /// @notice Set the Slipstream CL pool used for TWAP oracle.
    function setOraclePool(address newPool) external;

    /// @notice Set the TWAP window in seconds.
    function setTwapWindow(uint32 newWindow) external;

    /// @notice Set the tick spacing for CL swaps.
    function setTickSpacing(int24 newSpacing) external;

    function pause() external;
    function unpause() external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;

    /// @notice Recover tokens accidentally sent to the contract.
    /// @dev Cannot recover USDC (use distribute instead).
    function recoverERC20(address token, address to, uint256 amount) external;
}
