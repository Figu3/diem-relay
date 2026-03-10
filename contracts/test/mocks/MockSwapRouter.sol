// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICLSwapRouter} from "../../src/interfaces/ICLSwapRouter.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @title MockSwapRouter
 * @notice Mock Aerodrome Slipstream CL router for testing RevenueSplitter.
 *         Simulates exactInputSingle by pulling tokenIn and minting tokenOut
 *         at a configurable exchange rate.
 */
contract MockSwapRouter is ICLSwapRouter {
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

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (failNextSwap) {
            failNextSwap = false;
            return 0;
        }

        // Pull tokenIn from caller
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Calculate DIEM output: amountIn (6 decimals) * exchangeRate / 1e6
        amountOut = (params.amountIn * exchangeRate) / 1e6;

        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: insufficient output");

        // Mint DIEM to recipient
        IMintable(diemToken).mint(params.recipient, amountOut);
    }
}
