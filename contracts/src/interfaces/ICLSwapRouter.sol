// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/**
 * @title ICLSwapRouter
 * @notice Minimal interface for Aerodrome Slipstream SwapRouter.
 * @dev Slipstream (CL pools) uses a Uniswap V3-style exactInputSingle()
 *      instead of the V2-style swapExactTokensForTokens().
 */
interface ICLSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @param params The parameters necessary for the swap, encoded as ExactInputSingleParams.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
