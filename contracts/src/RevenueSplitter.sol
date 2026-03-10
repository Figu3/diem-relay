// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRevenueSplitter} from "./interfaces/IRevenueSplitter.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";
import {IcsDIEM} from "./interfaces/IcsDIEM.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {ICLSwapRouter} from "./interfaces/ICLSwapRouter.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/**
 * @title RevenueSplitter
 * @notice Permissionless revenue distribution for the DIEM staking system.
 *
 * Receives USDC revenue (from Venice compute credit earnings) and splits it:
 *   - sDIEM portion: USDC transferred + notifyRewardAmount() called
 *   - csDIEM portion: USDC swapped → DIEM via Aerodrome Slipstream (CL), then donated to csDIEM
 *
 * `distribute()` is fully permissionless — anyone can trigger it when
 * the contract holds USDC above the minimum threshold. This removes
 * the need for a centralized operator to manage revenue distribution.
 *
 * Anti-sandwich protection:
 *   Uses Slipstream CL pool's on-chain TWAP oracle (observe()) to compute a fair
 *   price floor. `amountOutMin = twapQuote * (1 - maxSlippageBps / 10000)`
 *   Default twapWindow = 1800 seconds (30-minute TWAP).
 *
 * Security features:
 *   - Two-step admin transfer
 *   - Emergency pause
 *   - TWAP-based slippage protection (anti-sandwich)
 *   - Minimum distribution threshold (prevents dust distribution)
 *   - ReentrancyGuard on distribute
 *   - Token recovery for accidental sends (not USDC)
 */
contract RevenueSplitter is IRevenueSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 private constant MIN_TWAP_WINDOW = 300; // 5 minutes minimum

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IERC20 public immutable diem;
    IsDIEM public immutable sdiem;
    IcsDIEM public immutable csdiem;

    // ── State — roles ───────────────────────────────────────────────────

    address public override admin;
    address public override pendingAdmin;
    bool public override paused;

    // ── State — config ──────────────────────────────────────────────────

    /// @notice Basis points of USDC going to sDIEM. Remainder goes to csDIEM.
    uint256 public override sdiemBps;

    /// @notice Minimum USDC balance to trigger permissionless distribution.
    uint256 public override minDistribution;

    /// @notice Maximum slippage for USDC→DIEM swap (in bps).
    uint256 public override maxSlippageBps;

    /// @notice Slipstream CL swap router for USDC→DIEM swaps.
    address public override swapRouter;

    /// @notice Slipstream CL pool used for TWAP oracle queries.
    address public override oraclePool;

    /// @notice TWAP window in seconds for CL oracle queries.
    /// Default 1800 = 30-minute TWAP.
    uint32 public override twapWindow;

    /// @notice Tick spacing of the DIEM/USDC CL pool.
    int24 public override tickSpacing;

    /// @notice Absolute minimum DIEM output per USDC (18 decimals).
    /// Acts as a circuit breaker if TWAP is stale or manipulated.
    /// 0 = disabled. e.g. 0.5e18 means at least 0.5 DIEM per USDC.
    uint256 public override minDiemPerUsdc;

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "RevenueSplitter: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "RevenueSplitter: paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(
        address _usdc,
        address _diem,
        address _sdiem,
        address _csdiem,
        address _swapRouter,
        address _oraclePool,
        address _admin,
        uint256 _sdiemBps,
        uint256 _minDistribution,
        uint256 _maxSlippageBps,
        uint32 _twapWindow,
        int24 _tickSpacing
    ) {
        require(_usdc != address(0), "RevenueSplitter: zero usdc");
        require(_diem != address(0), "RevenueSplitter: zero diem");
        require(_sdiem != address(0), "RevenueSplitter: zero sdiem");
        require(_csdiem != address(0), "RevenueSplitter: zero csdiem");
        require(_swapRouter != address(0), "RevenueSplitter: zero router");
        require(_oraclePool != address(0), "RevenueSplitter: zero oracle pool");
        require(_admin != address(0), "RevenueSplitter: zero admin");
        require(_sdiemBps <= BPS_DENOMINATOR, "RevenueSplitter: bps > 10000");
        require(_maxSlippageBps <= 1000, "RevenueSplitter: slippage > 10%");
        require(_twapWindow >= MIN_TWAP_WINDOW, "RevenueSplitter: twap window too short");
        require(_tickSpacing > 0, "RevenueSplitter: zero tick spacing");

        usdc = IERC20(_usdc);
        diem = IERC20(_diem);
        sdiem = IsDIEM(_sdiem);
        csdiem = IcsDIEM(_csdiem);
        swapRouter = _swapRouter;
        oraclePool = _oraclePool;
        admin = _admin;
        sdiemBps = _sdiemBps;
        minDistribution = _minDistribution;
        maxSlippageBps = _maxSlippageBps;
        twapWindow = _twapWindow;
        tickSpacing = _tickSpacing;
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @inheritdoc IRevenueSplitter
    function pendingRevenue() external view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ── Permissionless — distribute ─────────────────────────────────────

    /// @inheritdoc IRevenueSplitter
    function distribute() external override nonReentrant whenNotPaused {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance >= minDistribution, "RevenueSplitter: below minimum");

        _distribute(balance);
    }

    /// @inheritdoc IRevenueSplitter
    function distribute(uint256 amount) external override nonReentrant whenNotPaused {
        require(amount > 0, "RevenueSplitter: zero amount");
        uint256 balance = usdc.balanceOf(address(this));
        require(amount <= balance, "RevenueSplitter: insufficient balance");
        require(amount >= minDistribution, "RevenueSplitter: below minimum");

        _distribute(amount);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _distribute(uint256 totalUsdc) internal {
        uint256 toSdiem = (totalUsdc * sdiemBps) / BPS_DENOMINATOR;
        uint256 toCsdiem = totalUsdc - toSdiem;

        // 1. sDIEM — transfer USDC and notify reward
        if (toSdiem > 0) {
            usdc.safeTransfer(address(sdiem), toSdiem);
            sdiem.notifyRewardAmount(toSdiem);
        }

        // 2. csDIEM — swap USDC → DIEM, then donate
        if (toCsdiem > 0) {
            uint256 diemReceived = _swapUsdcToDiem(toCsdiem);

            // Approve csDIEM to pull DIEM for donation (forceApprove to prevent residual)
            diem.forceApprove(address(csdiem), diemReceived);
            csdiem.donate(diemReceived);
            diem.forceApprove(address(csdiem), 0);

            emit SwappedAndDonated(toCsdiem, diemReceived);
        }

        emit RevenueDistributed(msg.sender, totalUsdc, toSdiem, toCsdiem);
    }

    function _swapUsdcToDiem(uint256 usdcAmount) internal returns (uint256) {
        // 1. Query CL TWAP oracle for fair price
        int24 arithmeticMeanTick = OracleLibrary.consult(oraclePool, twapWindow);
        uint256 twapOut = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(usdcAmount),
            address(usdc),
            address(diem)
        );

        // 2. Apply slippage tolerance: amountOutMin = twapOut * (1 - maxSlippageBps / 10000)
        uint256 amountOutMin = (twapOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        // 3. Circuit breaker: enforce absolute minimum DIEM-per-USDC floor
        //    Prevents swapping at deeply unfavorable rates if TWAP itself is stale/manipulated
        if (minDiemPerUsdc > 0) {
            uint256 absoluteMin = (usdcAmount * minDiemPerUsdc) / 1e6; // USDC is 6 decimals
            require(amountOutMin >= absoluteMin, "RevenueSplitter: price below floor");
        }

        // 4. Approve router to spend USDC (forceApprove to prevent residual accumulation)
        usdc.forceApprove(swapRouter, usdcAmount);

        // 5. Execute swap via Slipstream exactInputSingle
        //    deadline = block.timestamp + 5 min to prevent indefinite mempool holding
        uint256 amountOut = ICLSwapRouter(swapRouter).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(diem),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: usdcAmount,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        // 6. Revoke residual allowance
        usdc.forceApprove(swapRouter, 0);

        require(amountOut > 0, "RevenueSplitter: swap returned zero");
        return amountOut;
    }

    // ── Admin ──────────────────────────────────────────────────────────

    /// @inheritdoc IRevenueSplitter
    function setSplit(uint256 newSdiemBps) external override onlyAdmin {
        require(newSdiemBps <= BPS_DENOMINATOR, "RevenueSplitter: bps > 10000");
        uint256 old = sdiemBps;
        sdiemBps = newSdiemBps;
        emit SplitUpdated(old, newSdiemBps);
    }

    /// @inheritdoc IRevenueSplitter
    function setSwapRouter(address newRouter) external override onlyAdmin {
        require(newRouter != address(0), "RevenueSplitter: zero router");
        address old = swapRouter;
        swapRouter = newRouter;
        emit SwapRouterUpdated(old, newRouter);
    }

    /// @inheritdoc IRevenueSplitter
    function setMinDistribution(uint256 newMin) external override onlyAdmin {
        uint256 old = minDistribution;
        minDistribution = newMin;
        emit MinDistributionUpdated(old, newMin);
    }

    /// @inheritdoc IRevenueSplitter
    function setMaxSlippage(uint256 newSlippage) external override onlyAdmin {
        require(newSlippage <= 1000, "RevenueSplitter: slippage > 10%");
        uint256 old = maxSlippageBps;
        maxSlippageBps = newSlippage;
        emit MaxSlippageUpdated(old, newSlippage);
    }

    /// @inheritdoc IRevenueSplitter
    function setOraclePool(address newPool) external override onlyAdmin {
        require(newPool != address(0), "RevenueSplitter: zero oracle pool");
        address old = oraclePool;
        oraclePool = newPool;
        emit OraclePoolUpdated(old, newPool);
    }

    /// @inheritdoc IRevenueSplitter
    function setTwapWindow(uint32 newWindow) external override onlyAdmin {
        require(newWindow >= MIN_TWAP_WINDOW, "RevenueSplitter: twap window too short");
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit TwapWindowUpdated(old, newWindow);
    }

    /// @inheritdoc IRevenueSplitter
    function setTickSpacing(int24 newSpacing) external override onlyAdmin {
        require(newSpacing > 0, "RevenueSplitter: zero tick spacing");
        int24 old = tickSpacing;
        tickSpacing = newSpacing;
        emit TickSpacingUpdated(old, newSpacing);
    }

    /// @inheritdoc IRevenueSplitter
    function setMinDiemPerUsdc(uint256 newMin) external override onlyAdmin {
        uint256 old = minDiemPerUsdc;
        minDiemPerUsdc = newMin;
        emit MinDiemPerUsdcUpdated(old, newMin);
    }

    /// @inheritdoc IRevenueSplitter
    function pause() external override onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IRevenueSplitter
    function unpause() external override onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IRevenueSplitter
    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "RevenueSplitter: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @inheritdoc IRevenueSplitter
    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "RevenueSplitter: not pending admin");
        address oldAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, msg.sender);
    }

    /// @inheritdoc IRevenueSplitter
    function recoverERC20(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin {
        require(token != address(usdc), "RevenueSplitter: cannot recover USDC");
        require(to != address(0), "RevenueSplitter: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }
}
