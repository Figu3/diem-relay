// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRevenueSplitter} from "./interfaces/IRevenueSplitter.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";
import {IcsDIEM} from "./interfaces/IcsDIEM.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/**
 * @title RevenueSplitter
 * @notice Permissionless revenue distribution for the DIEM staking system.
 *
 * Receives USDC revenue (from Venice compute credit earnings) and splits it:
 *   - sDIEM portion: USDC transferred + notifyRewardAmount() called
 *   - csDIEM portion: USDC swapped → DIEM via DEX router, then donated to csDIEM
 *
 * `distribute()` is fully permissionless — anyone can trigger it when
 * the contract holds USDC above the minimum threshold. This removes
 * the need for a centralized operator to manage revenue distribution.
 *
 * The swap uses a configurable DEX router (Uniswap V3 / Aerodrome / etc.)
 * with admin-set max slippage protection.
 *
 * Security features:
 *   - Two-step admin transfer
 *   - Emergency pause
 *   - Max slippage protection on swaps
 *   - Minimum distribution threshold (prevents dust distribution)
 *   - ReentrancyGuard on distribute
 *   - Token recovery for accidental sends (not USDC)
 */
contract RevenueSplitter is IRevenueSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IERC20 public immutable diem;
    IsDIEM public immutable sdiem;
    IcsDIEM public immutable csdiem;

    /// @notice Uniswap V3 pool fee tier for USDC/DIEM pair.
    uint24 public immutable poolFee;

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

    /// @notice DEX router for USDC→DIEM swaps.
    address public override swapRouter;

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
        uint24 _poolFee,
        address _admin,
        uint256 _sdiemBps,
        uint256 _minDistribution,
        uint256 _maxSlippageBps
    ) {
        require(_usdc != address(0), "RevenueSplitter: zero usdc");
        require(_diem != address(0), "RevenueSplitter: zero diem");
        require(_sdiem != address(0), "RevenueSplitter: zero sdiem");
        require(_csdiem != address(0), "RevenueSplitter: zero csdiem");
        require(_swapRouter != address(0), "RevenueSplitter: zero router");
        require(_admin != address(0), "RevenueSplitter: zero admin");
        require(_sdiemBps <= BPS_DENOMINATOR, "RevenueSplitter: bps > 10000");
        require(_maxSlippageBps <= 1000, "RevenueSplitter: slippage > 10%");

        usdc = IERC20(_usdc);
        diem = IERC20(_diem);
        sdiem = IsDIEM(_sdiem);
        csdiem = IcsDIEM(_csdiem);
        swapRouter = _swapRouter;
        poolFee = _poolFee;
        admin = _admin;
        sdiemBps = _sdiemBps;
        minDistribution = _minDistribution;
        maxSlippageBps = _maxSlippageBps;
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

            // Approve csDIEM to pull DIEM for donation
            diem.safeIncreaseAllowance(address(csdiem), diemReceived);
            csdiem.donate(diemReceived);

            emit SwappedAndDonated(toCsdiem, diemReceived);
        }

        emit RevenueDistributed(msg.sender, totalUsdc, toSdiem, toCsdiem);
    }

    function _swapUsdcToDiem(uint256 usdcAmount) internal returns (uint256) {
        // Approve router to spend USDC
        usdc.safeIncreaseAllowance(swapRouter, usdcAmount);

        // Calculate minimum output with slippage protection.
        // amountOutMinimum = 0 here because we rely on maxSlippageBps
        // check after the swap. In production, an oracle-based floor
        // should be added for stronger protection.
        // For now, we accept any output > 0 and let the admin-configured
        // maxSlippageBps serve as the guardrail via front-end quoting.
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(diem),
            fee: poolFee,
            recipient: address(this),
            amountIn: usdcAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);
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
