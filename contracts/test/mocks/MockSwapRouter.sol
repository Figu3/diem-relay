// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAerodromeRouter} from "../../src/interfaces/IAerodromeRouter.sol";

/**
 * @title MockSwapRouter
 * @notice Mock Aerodrome router for testing RevenueSplitter.
 *         Simulates swapExactTokensForTokens by pulling tokenIn and minting tokenOut
 *         at a configurable exchange rate.
 */
contract MockSwapRouter is IAerodromeRouter {
    /// @notice Exchange rate: 1 USDC (1e6) = exchangeRate DIEM (in 1e18).
    /// Default: 1 USDC = 1 DIEM (rate = 1e18)
    uint256 public exchangeRate = 1e18;

    /// @notice DIEM token (will be minted on swap).
    address public diemToken;

    /// @notice If true, next swap will return 0 (simulate failure).
    bool public failNextSwap;

    constructor(address _diemToken) {
        diemToken = _diemToken;
    }

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    function setFailNextSwap(bool _fail) external {
        failNextSwap = _fail;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 /* deadline */
    ) external override returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        if (failNextSwap) {
            failNextSwap = false;
            amounts[1] = 0;
            return amounts;
        }

        // Pull tokenIn from caller
        IERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);

        // Calculate DIEM output: amountIn (6 decimals) * exchangeRate / 1e6
        uint256 amountOut = (amountIn * exchangeRate) / 1e6;

        require(amountOut >= amountOutMin, "MockSwapRouter: insufficient output");

        // Mint DIEM to recipient
        IMintable(diemToken).mint(to, amountOut);

        amounts[1] = amountOut;
    }
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}
