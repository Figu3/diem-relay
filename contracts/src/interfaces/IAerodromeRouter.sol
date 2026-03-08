// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IAerodromeRouter
 * @notice Minimal interface for Aerodrome Router swap execution.
 *         Uses Route[] structs instead of Uniswap V3's fee-tier model.
 */
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Swap exact input tokens along a route.
    /// @param amountIn     Amount of input token to swap.
    /// @param amountOutMin Minimum output to accept (sandwich protection).
    /// @param routes       Swap path — for single-hop: one Route element.
    /// @param to           Recipient of output tokens.
    /// @param deadline     Unix timestamp after which the swap reverts.
    /// @return amounts     Array of amounts at each hop (length = routes.length + 1).
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
