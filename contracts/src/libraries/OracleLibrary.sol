// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ICLPool} from "../interfaces/ICLPool.sol";
import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";

/**
 * @title OracleLibrary
 * @notice Provides functions to integrate with Uniswap V3 / Aerodrome Slipstream
 *         TWAP oracle. Adapted from Uniswap V3 OracleLibrary.
 * @dev Uses observe() on CL pools to compute time-weighted average prices,
 *      which are manipulation-resistant over the specified window.
 */
library OracleLibrary {
    /// @notice Fetches the time-weighted average tick from a CL pool.
    /// @param pool Address of the Slipstream CL pool.
    /// @param twapWindow Number of seconds in the past to use for the TWAP.
    /// @return arithmeticMeanTick The arithmetic mean tick over the window.
    function consult(address pool, uint32 twapWindow) internal view returns (int24 arithmeticMeanTick) {
        require(twapWindow != 0, "OracleLibrary: zero window");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow; // from (further back)
        secondsAgos[1] = 0;          // to (now)

        (int56[] memory tickCumulatives,) = ICLPool(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        // Integer division truncates toward zero; we want floor division.
        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapWindow)));
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(twapWindow)) != 0)) {
            arithmeticMeanTick--;
        }
    }

    /// @notice Given a tick and a token pair, returns the equivalent amount of token1
    ///         for a given amount of token0.
    /// @dev Uses the sqrt price at the given tick to compute the output amount.
    ///      Handles both cases: baseToken is token0 or token1.
    /// @param tick The tick representing the price.
    /// @param baseAmount Amount of base token.
    /// @param baseToken Address of the base token (the one you're pricing).
    /// @param quoteToken Address of the quote token (the one you want the value in).
    /// @return quoteAmount Amount of quote token equivalent to baseAmount of baseToken.
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
