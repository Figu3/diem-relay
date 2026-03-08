// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ISwapRouter
 * @notice Minimal swap router interface for single-hop exact-input swaps.
 *         Compatible with Uniswap V3 / Aerodrome / any router exposing
 *         exactInputSingle().
 */
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
