// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/**
 * @title ICLPool
 * @notice Minimal interface for Aerodrome Slipstream (concentrated liquidity) pools.
 * @dev Used for TWAP oracle queries via observe().
 */
interface ICLPool {
    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgos`
    ///         from the current block timestamp.
    /// @param secondsAgos Array of seconds in the past from which to return observations.
    ///        secondsAgos[0] = most recent, secondsAgos[1] = further back.
    /// @return tickCumulatives Cumulative tick values for each secondsAgos.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per in-range liquidity
    ///         (not used for TWAP price, but required by the interface).
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice The currently in range liquidity available to the pool.
    function liquidity() external view returns (uint128);

    /// @notice The 0th storage slot in the pool stores many values, and is exposed
    ///         as a single accessor to save gas when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value.
    /// @return tick The current tick of the pool.
    /// @return observationIndex The index of the last oracle observation that was written.
    /// @return observationCardinality The current maximum number of observations stored.
    /// @return observationCardinalityNext The next maximum number of observations.
    /// @return unlocked Whether the pool is currently locked to reentrancy.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @notice The first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);

    /// @notice The pool tick spacing.
    function tickSpacing() external view returns (int24);
}
