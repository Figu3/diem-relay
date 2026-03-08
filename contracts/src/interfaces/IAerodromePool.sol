// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IAerodromePool
 * @notice Minimal interface for Aerodrome volatile/stable pool TWAP oracle.
 *         Used to query time-weighted average prices for sandwich protection.
 *
 *         `quote()` returns the TWAP output for a given input over
 *         `granularity * periodSize` seconds. Default periodSize = 1800s,
 *         so granularity=4 ≈ 2-hour TWAP window.
 */
interface IAerodromePool {
    /// @notice Get the time-weighted average price quote.
    /// @param tokenIn  Address of the input token.
    /// @param amountIn Amount of input token.
    /// @param granularity Number of observation periods to use.
    /// @return amountOut Expected output amount based on TWAP.
    function quote(address tokenIn, uint256 amountIn, uint256 granularity)
        external
        view
        returns (uint256 amountOut);

    /// @notice Duration (in seconds) of each observation period.
    function periodSize() external view returns (uint256);

    /// @notice Number of stored observations.
    function observationLength() external view returns (uint256);
}
