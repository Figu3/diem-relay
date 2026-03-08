// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAerodromePool} from "../../src/interfaces/IAerodromePool.sol";

/**
 * @title MockAerodromePool
 * @notice Mock Aerodrome pool for TWAP oracle queries in tests.
 *         Returns a configurable price quote.
 */
contract MockAerodromePool is IAerodromePool {
    /// @notice TWAP rate: quote returns amountIn * twapRate / 1e6.
    /// Default: 1 USDC = 1 DIEM (rate = 1e18).
    uint256 public twapRate = 1e18;

    function setTwapRate(uint256 _rate) external {
        twapRate = _rate;
    }

    function quote(address, uint256 amountIn, uint256)
        external
        view
        override
        returns (uint256 amountOut)
    {
        amountOut = (amountIn * twapRate) / 1e6;
    }

    function periodSize() external pure override returns (uint256) {
        return 1800;
    }

    function observationLength() external pure override returns (uint256) {
        return 8;
    }
}
