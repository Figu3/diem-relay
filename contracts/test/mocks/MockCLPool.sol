// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICLPool} from "../../src/interfaces/ICLPool.sol";

/**
 * @title MockCLPool
 * @notice Mock Slipstream CL pool for TWAP oracle queries in tests.
 *
 *         The OracleLibrary is compiled into RevenueSplitter as an internal library,
 *         so we can't mock it directly. Instead, this mock returns tick cumulatives
 *         that OracleLibrary.consult() will interpret as our desired meanTick.
 *
 *         consult() computes: arithmeticMeanTick = (tickCum[1] - tickCum[0]) / twapWindow
 *         So we return: tickCum[0] = 0, tickCum[1] = meanTick * secondsAgos[0]
 *         This ensures consult() returns exactly meanTick.
 *
 *         Tick value guide (for 1 USDC = X DIEM, assuming USDC < DIEM by address):
 *           tick  276324  → 1 USDC ≈ 1e12 DIEM (accounts for 6→18 decimal diff)
 *           tick -276324  → inverse (if DIEM < USDC by address)
 */
contract MockCLPool is ICLPool {
    /// @notice The arithmetic mean tick that consult() will return.
    int24 public meanTick = 276324;

    function setMeanTick(int24 _tick) external {
        meanTick = _tick;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        // OracleLibrary.consult() calls observe([twapWindow, 0])
        // and computes: (tickCum[1] - tickCum[0]) / twapWindow
        // We set tickCum[0] (the older observation) to 0 and
        // tickCum[1] (the newer observation = secondsAgos=0) to meanTick * window.
        //
        // Note: secondsAgos[0] is the older one (further back), secondsAgos[1] = 0 (now).
        // So tickCumulatives[0] = old, tickCumulatives[1] = now.
        // delta = tickCum[1] - tickCum[0] = meanTick * window - 0
        // result = delta / window = meanTick ✓
        tickCumulatives[0] = 0;
        if (secondsAgos.length > 1) {
            tickCumulatives[1] = int56(meanTick) * int56(uint56(secondsAgos[0]));
        }
    }

    // ── Unused but required by ICLPool ────────────────────────────────

    function liquidity() external pure override returns (uint128) {
        return 1e18;
    }

    function slot0()
        external
        pure
        override
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        )
    {
        return (0, 0, 0, 0, 0, true);
    }

    function token0() external pure override returns (address) {
        return address(0);
    }

    function token1() external pure override returns (address) {
        return address(0);
    }

    function tickSpacing() external pure override returns (int24) {
        return 1;
    }
}
