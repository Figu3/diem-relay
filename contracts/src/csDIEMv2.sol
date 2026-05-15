// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IcsDIEMv2} from "./interfaces/IcsDIEMv2.sol";
import {IsDIEMv2} from "./interfaces/IsDIEMv2.sol";
import {ICLSwapRouter} from "./interfaces/ICLSwapRouter.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/**
 * @title csDIEM v2 — Compounding Staked DIEM
 * @notice Canonical ERC-4626 wrapper over sDIEM v2.
 *
 * `asset()` is sDIEM v2 (NOT raw DIEM). Mental model: wstETH over stETH.
 *
 *   deposit(sDIEMv2) → mint csDIEMv2 shares
 *   redeem(csDIEMv2) → burn shares, return sDIEMv2 (synchronous)
 *
 * Share price ticks up on every harvest:
 *   1. claim USDC rewards accrued in sDIEM v2
 *   2. swap USDC → DIEM via Slipstream CL (TWAP + slippage + price-floor protected)
 *   3. sdiem.stake(diem) — vault's sDIEM balance grows → totalAssets grows
 *
 * For users holding raw DIEM there is a `depositDIEM` zap that stakes
 * internally and mints shares against the resulting sDIEM in one tx.
 *
 * The Pashov audit findings are preserved verbatim from csDIEM v1:
 *   #1 caller-supplied harvest deadline
 *   #3 mandatory minDiemPerUsdc floor (no zero default)
 *   #4 uint128 bound on OracleLibrary input
 *
 * Standard ERC-4626 semantics: maxDeposit/maxMint/maxWithdraw/maxRedeem all
 * return real values. Composable with Pendle SY, Morpho/MetaMorpho, Spectra,
 * Silo, and any integrator expecting canonical 4626.
 */
contract csDIEMv2 is ERC4626, IcsDIEMv2, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 private constant MIN_TWAP_WINDOW = 1800; // 30 minutes

    // ── Immutables ──────────────────────────────────────────────────────

    IsDIEMv2 public immutable override sdiem;
    IERC20 public immutable override diem;
    IERC20 public immutable override usdc;

    // ── State — roles ───────────────────────────────────────────────────

    address public override admin;
    address public override pendingAdmin;
    bool public override paused;

    // ── State — harvest config ──────────────────────────────────────────

    address public override swapRouter;
    address public override oraclePool;
    uint32 public override twapWindow;
    int24 public override tickSpacing;
    uint256 public override maxSlippageBps;
    uint256 public override minDiemPerUsdc;
    uint256 public override minHarvest;

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "csDIEMv2: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "csDIEMv2: paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(
        IsDIEMv2 _sdiem,
        address _diem,
        address _usdc,
        address _swapRouter,
        address _oraclePool,
        address _admin,
        uint256 _maxSlippageBps,
        uint32 _twapWindow,
        int24 _tickSpacing,
        uint256 _minHarvest,
        uint256 _minDiemPerUsdc
    )
        ERC20("Compounding Staked DIEM", "csDIEM")
        ERC4626(IERC20(address(_sdiem)))
    {
        require(address(_sdiem) != address(0), "csDIEMv2: zero sdiem");
        require(_diem != address(0), "csDIEMv2: zero diem");
        require(_usdc != address(0), "csDIEMv2: zero usdc");
        require(_swapRouter != address(0), "csDIEMv2: zero router");
        require(_oraclePool != address(0), "csDIEMv2: zero oracle");
        require(_admin != address(0), "csDIEMv2: zero admin");
        require(_maxSlippageBps <= 1000, "csDIEMv2: slippage > 10%");
        require(_twapWindow >= MIN_TWAP_WINDOW, "csDIEMv2: twap too short");
        require(_tickSpacing > 0, "csDIEMv2: zero tick spacing");
        require(_minDiemPerUsdc > 0, "csDIEMv2: zero floor");

        sdiem = _sdiem;
        diem = IERC20(_diem);
        usdc = IERC20(_usdc);
        swapRouter = _swapRouter;
        oraclePool = _oraclePool;
        admin = _admin;
        maxSlippageBps = _maxSlippageBps;
        twapWindow = _twapWindow;
        tickSpacing = _tickSpacing;
        minHarvest = _minHarvest;
        minDiemPerUsdc = _minDiemPerUsdc;

        // Permanent approval for the harvest path: sDIEM v2 pulls DIEM via
        // safeTransferFrom in stake(). asset() is sDIEM, NOT DIEM, so this
        // doesn't conflict with any 4626 flow.
        IERC20(_diem).approve(address(_sdiem), type(uint256).max);
    }

    // ── ERC-4626 overrides ─────────────────────────────────────────────

    /// @notice Total sDIEM v2 held by the vault. One line — no bookkeeping.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return sdiem.balanceOf(address(this));
    }

    /// @dev Gate deposits behind pause. No internal staking — the user
    ///      arrives with sDIEM already in hand.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev `_withdraw` is intentionally NOT overridden. Standard OZ
    ///      synchronous redeem applies; maxRedeem/maxWithdraw return real
    ///      values; redemptions are always allowed (even when paused).

    /// @dev 1e6 offset for inflation-attack protection (matches csDIEM v1).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ── Views ───────────────────────────────────────────────────────────

    function pendingHarvest() external view override returns (uint256) {
        return sdiem.earned(address(this));
    }

    // ── Harvest (permissionless) ────────────────────────────────────────

    /**
     * @notice Claim USDC from sDIEM v2, swap to DIEM, stake into sDIEM v2.
     * @param deadline Unix timestamp by which the swap must execute. The
     *      caller MUST compute this at submission time (e.g. now+300s) —
     *      a deadline derived inside the contract from block.timestamp is
     *      always satisfied and provides no mempool-delay protection.
     *      Pashov #1.
     */
    function harvest(uint256 deadline) external override nonReentrant whenNotPaused {
        require(deadline >= block.timestamp, "csDIEMv2: expired deadline");

        sdiem.claimReward();
        uint256 usdcBal = usdc.balanceOf(address(this));
        require(usdcBal >= minHarvest, "csDIEMv2: below min harvest");

        uint256 diemReceived = _swapUsdcToDiem(usdcBal, deadline);

        // Stake DIEM into sDIEM v2 — vault's sDIEM balance grows.
        sdiem.stake(diemReceived);

        emit Harvested(msg.sender, usdcBal, diemReceived);
    }

    // ── Zap ────────────────────────────────────────────────────────────

    /**
     * @notice Deposit raw DIEM. Vault stakes into sDIEM v2 and mints csDIEM
     *         v2 shares against the resulting sDIEM.
     * @dev Shares are computed against the pre-stake totals via the same
     *      formula OZ ERC-4626 uses internally, preserving inflation-attack
     *      protection (virtual shares offset).
     */
    function depositDIEM(uint256 diemAmount, address receiver)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(diemAmount > 0, "csDIEMv2: zero diem");
        require(receiver != address(0), "csDIEMv2: zero receiver");

        // Snapshot totals BEFORE staking.
        uint256 supplyBefore = totalSupply();
        uint256 assetsBefore = totalAssets();

        // Pull DIEM and stake into sDIEM v2; vault receives sDIEM.
        diem.safeTransferFrom(msg.sender, address(this), diemAmount);
        sdiem.stake(diemAmount);
        uint256 sdiemReceived = totalAssets() - assetsBefore;
        require(sdiemReceived > 0, "csDIEMv2: zero sdiem received");

        // Replicate OZ _convertToShares using the BEFORE snapshot. This is
        // exactly what super._deposit would compute given a transferFrom
        // delta of `sdiemReceived` against `(supplyBefore, assetsBefore)`.
        shares = Math.mulDiv(
            sdiemReceived,
            supplyBefore + 10 ** _decimalsOffset(),
            assetsBefore + 1,
            Math.Rounding.Floor
        );
        require(shares > 0, "csDIEMv2: zero shares");

        _mint(receiver, shares);

        emit DepositZap(msg.sender, receiver, diemAmount, sdiemReceived, shares);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _swapUsdcToDiem(uint256 usdcAmount, uint256 deadline) internal returns (uint256) {
        // Pashov #4: bound OracleLibrary input to uint128 to prevent silent
        // truncation. USDC supply makes overflow implausible today but the
        // explicit guard removes the footgun.
        require(usdcAmount <= type(uint128).max, "csDIEMv2: usdc amount > uint128");

        int24 arithmeticMeanTick = OracleLibrary.consult(oraclePool, twapWindow);
        uint256 twapOut = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(usdcAmount),
            address(usdc),
            address(diem)
        );

        uint256 amountOutMin = (twapOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        // Pashov #3: mandatory floor (no zero-default escape hatch).
        require(minDiemPerUsdc > 0, "csDIEMv2: floor unset");
        uint256 absoluteMin = (usdcAmount * minDiemPerUsdc) / 1e6;
        require(amountOutMin >= absoluteMin, "csDIEMv2: price below floor");

        usdc.forceApprove(swapRouter, usdcAmount);

        uint256 amountOut = ICLSwapRouter(swapRouter).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(diem),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: deadline,
                amountIn: usdcAmount,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        usdc.forceApprove(swapRouter, 0);

        require(amountOut > 0, "csDIEMv2: swap returned zero");
        return amountOut;
    }

    // ── Admin ──────────────────────────────────────────────────────────

    function pause() external override onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "csDIEMv2: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "csDIEMv2: not pending admin");
        address oldAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, msg.sender);
    }

    function setSwapRouter(address newRouter) external override onlyAdmin {
        require(newRouter != address(0), "csDIEMv2: zero router");
        address old = swapRouter;
        swapRouter = newRouter;
        emit SwapRouterUpdated(old, newRouter);
    }

    function setMaxSlippage(uint256 newSlippage) external override onlyAdmin {
        require(newSlippage <= 1000, "csDIEMv2: slippage > 10%");
        uint256 old = maxSlippageBps;
        maxSlippageBps = newSlippage;
        emit MaxSlippageUpdated(old, newSlippage);
    }

    function setOraclePool(address newPool) external override onlyAdmin {
        require(newPool != address(0), "csDIEMv2: zero oracle");
        address old = oraclePool;
        oraclePool = newPool;
        emit OraclePoolUpdated(old, newPool);
    }

    function setTwapWindow(uint32 newWindow) external override onlyAdmin {
        require(newWindow >= MIN_TWAP_WINDOW, "csDIEMv2: twap too short");
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit TwapWindowUpdated(old, newWindow);
    }

    function setTickSpacing(int24 newSpacing) external override onlyAdmin {
        require(newSpacing > 0, "csDIEMv2: zero tick spacing");
        int24 old = tickSpacing;
        tickSpacing = newSpacing;
        emit TickSpacingUpdated(old, newSpacing);
    }

    function setMinDiemPerUsdc(uint256 newMin) external override onlyAdmin {
        require(newMin > 0, "csDIEMv2: zero floor");
        uint256 old = minDiemPerUsdc;
        minDiemPerUsdc = newMin;
        emit MinDiemPerUsdcUpdated(old, newMin);
    }

    function setMinHarvest(uint256 newMin) external override onlyAdmin {
        uint256 old = minHarvest;
        minHarvest = newMin;
        emit MinHarvestUpdated(old, newMin);
    }

    /// @notice Recover tokens accidentally sent to the vault.
    /// @dev Blocks asset() (sDIEM v2), DIEM (harvest path), and USDC (harvest path).
    function recoverERC20(address token, address to, uint256 amount) external override onlyAdmin {
        require(token != asset(), "csDIEMv2: cannot recover sDIEM");
        require(token != address(diem), "csDIEMv2: cannot recover DIEM");
        require(token != address(usdc), "csDIEMv2: cannot recover USDC");
        require(to != address(0), "csDIEMv2: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }
}
