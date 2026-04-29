// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20, IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IcsDIEM} from "./interfaces/IcsDIEM.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";
import {ICLSwapRouter} from "./interfaces/ICLSwapRouter.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/**
 * @title csDIEM — Compounding Staked DIEM
 * @notice ERC-4626 auto-compounding wrapper over sDIEM.
 *
 * Deposit DIEM → staked in sDIEM → earns USDC rewards.
 * `harvest()` claims USDC, swaps to DIEM via Slipstream, restakes.
 * Share price increases monotonically as harvested DIEM compounds.
 *
 * sDIEM is the base layer (stake DIEM, earn USDC).
 * csDIEM is the composability layer — ERC-4626 with increasing exchange rate.
 * NOTE: Standard withdraw()/redeem() are disabled (return 0 via maxWithdraw/
 * maxRedeem). Integrations expecting standard ERC-4626 withdrawal flow
 * (Pendle, Morpho, Silo) must use the async requestRedeem/completeRedeem path.
 *
 * Redemptions use a request/complete pattern with a 24h delay,
 * matching sDIEM's withdrawal delay (which matches Venice's cooldown).
 * Standard ERC-4626 withdraw()/redeem() are disabled.
 *
 * Security features:
 *   - OZ ERC-4626 with virtual shares/assets (inflation attack mitigation)
 *   - TWAP-protected USDC→DIEM swaps (anti-sandwich)
 *   - Two-step admin transfer
 *   - Emergency pause (deposits + harvest gated; redemptions always allowed)
 *   - ReentrancyGuard on all mutative functions
 *   - Token recovery for accidental sends (not DIEM/USDC)
 */
contract csDIEM is ERC4626, IcsDIEM, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant override WITHDRAWAL_DELAY = 24 hours;
    uint256 public constant MIN_REDEEM_ASSETS = 1e18; // 1 DIEM minimum
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint32 private constant MIN_TWAP_WINDOW = 1800; // 30 minutes minimum
    uint256 private constant SDIEM_MIN_WITHDRAW = 1e18; // sDIEM's minimum

    // ── Immutables ──────────────────────────────────────────────────────

    IsDIEM public immutable override sdiem;
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

    // ── State — redemptions ─────────────────────────────────────────────

    uint256 public override totalPendingRedemptions;
    mapping(address => RedemptionRequest) private _redemptionRequests;

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "csDIEM: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "csDIEM: paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(
        IERC20 _diem,
        address _sdiem,
        address _usdc,
        address _swapRouter,
        address _oraclePool,
        address _admin,
        uint256 _maxSlippageBps,
        uint32 _twapWindow,
        int24 _tickSpacing,
        uint256 _minHarvest
    )
        ERC20("Compounding Staked DIEM", "csDIEM")
        ERC4626(_diem)
    {
        require(_sdiem != address(0), "csDIEM: zero sdiem");
        require(_usdc != address(0), "csDIEM: zero usdc");
        require(_swapRouter != address(0), "csDIEM: zero router");
        require(_oraclePool != address(0), "csDIEM: zero oracle");
        require(_admin != address(0), "csDIEM: zero admin");
        require(_maxSlippageBps <= 1000, "csDIEM: slippage > 10%");
        require(_twapWindow >= MIN_TWAP_WINDOW, "csDIEM: twap too short");
        require(_tickSpacing > 0, "csDIEM: zero tick spacing");

        sdiem = IsDIEM(_sdiem);
        usdc = IERC20(_usdc);
        swapRouter = _swapRouter;
        oraclePool = _oraclePool;
        admin = _admin;
        maxSlippageBps = _maxSlippageBps;
        twapWindow = _twapWindow;
        tickSpacing = _tickSpacing;
        minHarvest = _minHarvest;

        // Permanent approval: sDIEM pulls DIEM via safeTransferFrom in stake()
        _diem.approve(_sdiem, type(uint256).max);
    }

    // ── ERC-4626 overrides ─────────────────────────────────────────────

    /**
     * @notice Total DIEM assets under management.
     * @dev sdiemBalance + sdiemPendingWithdrawal + liquidDiem - totalPendingRedemptions
     *
     *      sdiemBalance: DIEM actively staked in sDIEM (earning rewards)
     *      sdiemPendingWithdrawal: DIEM in sDIEM's 24h withdrawal queue
     *      liquidDiem: DIEM sitting in this contract (from completed sDIEM withdrawals)
     *      totalPendingRedemptions: DIEM owed to redeemers (already burned shares)
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 sdiemBal = sdiem.balanceOf(address(this));
        (uint256 sdiemPending,) = sdiem.withdrawalRequests(address(this));
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 gross = sdiemBal + sdiemPending + liquid;
        return gross > totalPendingRedemptions ? gross - totalPendingRedemptions : 0;
    }

    /// @dev Gate deposits behind pause. Forward DIEM to sDIEM after deposit.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        super._deposit(caller, receiver, assets, shares);
        // Forward deposited DIEM to sDIEM immediately
        sdiem.stake(assets);
    }

    /**
     * @dev Disable standard ERC-4626 withdrawals.
     *      Users must use requestRedeem()/completeRedeem() instead.
     */
    function _withdraw(
        address,
        address,
        address,
        uint256,
        uint256
    ) internal pure override {
        revert("csDIEM: use requestRedeem");
    }

    /// @notice Always returns 0 — standard ERC-4626 withdrawals are disabled.
    function maxWithdraw(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    /// @notice Always returns 0 — standard ERC-4626 redemptions are disabled.
    function maxRedeem(address) public pure override(ERC4626, IERC4626) returns (uint256) {
        return 0;
    }

    /// @dev Use 1e6 offset for inflation attack protection.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @inheritdoc IcsDIEM
    function redemptionRequests(address account)
        external
        view
        override
        returns (uint256 assets, uint256 shares, uint256 requestedAt)
    {
        RedemptionRequest storage req = _redemptionRequests[account];
        return (req.assets, req.shares, req.requestedAt);
    }

    /// @inheritdoc IcsDIEM
    function canCompleteRedeem(address account) external view override returns (bool) {
        RedemptionRequest storage req = _redemptionRequests[account];
        if (req.assets == 0) return false;
        if (block.timestamp < req.requestedAt + WITHDRAWAL_DELAY) return false;
        // Check liquid DIEM + completable sDIEM withdrawal
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        if (liquid >= req.assets) return true;
        // Would completing sDIEM withdrawal give us enough?
        (uint256 sdiemPending,) = sdiem.withdrawalRequests(address(this));
        if (sdiemPending > 0 && sdiem.canCompleteWithdraw(address(this))) {
            return liquid + sdiemPending >= req.assets;
        }
        return false;
    }

    /// @inheritdoc IcsDIEM
    function pendingHarvest() external view override returns (uint256) {
        return sdiem.earned(address(this));
    }

    // ── Harvest (permissionless) ────────────────────────────────────────

    /**
     * @notice Claim USDC rewards from sDIEM, swap to DIEM, restake.
     * @dev Anyone can call. TWAP oracle protects against sandwich attacks.
     *      Reverts if accrued USDC is below minHarvest threshold.
     * @param deadline Unix timestamp by which the swap must execute. The caller
     *      should compute this at submission time (e.g. `block.timestamp + 300`
     *      from their local view), NOT inside the contract — an internally-set
     *      deadline is always satisfied at execution time and provides no
     *      mempool-delay protection. Pashov audit finding #1.
     */
    function harvest(uint256 deadline) external override nonReentrant whenNotPaused {
        require(deadline >= block.timestamp, "csDIEM: expired deadline");

        // 1. Claim accrued USDC from sDIEM
        sdiem.claimReward();
        uint256 usdcBal = usdc.balanceOf(address(this));
        require(usdcBal >= minHarvest, "csDIEM: below min harvest");

        // 2. Swap USDC → DIEM via Slipstream (TWAP-protected)
        uint256 diemReceived = _swapUsdcToDiem(usdcBal, deadline);

        // 3. Restake DIEM into sDIEM (compounding)
        sdiem.stake(diemReceived);

        emit Harvested(msg.sender, usdcBal, diemReceived);
    }

    // ── Async Redemption ────────────────────────────────────────────────

    /**
     * @notice Request redemption of csDIEM shares. Burns shares, starts 24h delay.
     * @dev Burns shares at current exchange rate, records DIEM amount owed.
     *      Best-effort: initiates sDIEM withdrawal if balance allows.
     *      Always allowed, even when paused (users must be able to exit).
     * @param shares Number of csDIEM shares to redeem.
     * @return assets DIEM amount that will be claimable after delay.
     */
    function requestRedeem(uint256 shares) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "csDIEM: zero shares");
        require(balanceOf(msg.sender) >= shares, "csDIEM: insufficient shares");

        // Calculate DIEM owed at current exchange rate BEFORE burning
        assets = previewRedeem(shares);
        require(assets >= MIN_REDEEM_ASSETS, "csDIEM: below min redeem");

        // Effects — burn shares
        _burn(msg.sender, shares);

        // Track pending redemption
        RedemptionRequest storage req = _redemptionRequests[msg.sender];
        req.assets += assets;
        req.shares += shares;
        // Always reset timer — each new request enforces a fresh 24h delay
        req.requestedAt = block.timestamp;
        totalPendingRedemptions += assets;

        emit RedemptionRequested(msg.sender, shares, assets);

        // Best-effort: initiate sDIEM withdrawal for pending redemptions.
        // Only if no sDIEM withdrawal is already pending (avoids resetting
        // the 24h timer and griefing other redeemers — finding #5).
        _tryWithdrawFromSdiem();
    }

    /**
     * @notice Complete redemption after 24h delay.
     * @dev Auto-completes sDIEM withdrawal if needed and ready (partial ok).
     *      With partial sDIEM withdrawals, one user's unfunded portion
     *      doesn't block other users from completing their redemptions.
     *      Always allowed, even when paused.
     */
    function completeRedeem() external override nonReentrant {
        RedemptionRequest storage req = _redemptionRequests[msg.sender];
        uint256 assets = req.assets;
        require(assets > 0, "csDIEM: no pending redemption");
        require(
            block.timestamp >= req.requestedAt + WITHDRAWAL_DELAY,
            "csDIEM: delay not met"
        );

        // Ensure we have enough liquid DIEM
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        if (liquid < assets) {
            // Try to complete sDIEM withdrawal (supports partial payouts).
            // Use try/catch: sDIEM may revert with "nothing claimable yet"
            // if Venice cooldown hasn't matured for the remaining batch.
            (uint256 sdiemPending,) = sdiem.withdrawalRequests(address(this));
            if (sdiemPending > 0) {
                try sdiem.completeWithdraw() {} catch {}
                liquid = IERC20(asset()).balanceOf(address(this));
            }
        }
        require(liquid >= assets, "csDIEM: insufficient liquid DIEM");

        // Effects
        req.assets = 0;
        req.shares = 0;
        req.requestedAt = 0;
        totalPendingRedemptions -= assets;

        emit RedemptionCompleted(msg.sender, assets);

        // Interaction
        IERC20(asset()).safeTransfer(msg.sender, assets);
    }

    /**
     * @notice Cancel a pending redemption. Mints new shares at CURRENT rate.
     * @dev The user may receive fewer shares than originally burned if the
     *      share price increased since their request (due to harvests).
     *      This prevents arbitrage: request before harvest, cancel after,
     *      and extract value from other stakers via a transient price spike.
     *      Does NOT cancel the sDIEM withdrawal — excess DIEM will be
     *      restaked via redeployExcess() after sDIEM withdrawal completes.
     *      Always allowed, even when paused.
     */
    function cancelRedeem() external override nonReentrant {
        RedemptionRequest storage req = _redemptionRequests[msg.sender];
        uint256 assets = req.assets;
        uint256 storedShares = req.shares;
        require(assets > 0, "csDIEM: no pending redemption");

        // Effects
        req.assets = 0;
        req.shares = 0;
        req.requestedAt = 0;
        totalPendingRedemptions -= assets;

        // Re-mint shares: use current rate to prevent arbitrage, EXCEPT when
        // totalSupply == 0 (last/only staker), where previewDeposit uses the
        // virtual shares offset and would return far fewer shares. When there
        // are no other stakers, no arbitrage is possible anyway.
        uint256 newShares;
        if (totalSupply() == 0) {
            newShares = storedShares;
        } else {
            newShares = previewDeposit(assets);
        }
        require(newShares > 0, "csDIEM: zero shares on cancel");
        _mint(msg.sender, newShares);

        emit RedemptionCancelled(msg.sender, assets, newShares);
    }

    // ── Permissionless ──────────────────────────────────────────────────

    /**
     * @notice Restake excess liquid DIEM into sDIEM. Anyone can call.
     * @dev After sDIEM withdrawal completes, excess DIEM (beyond what's
     *      needed for pending redemptions) should be earning yield.
     */
    function redeployExcess() external override nonReentrant {
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        require(liquid > totalPendingRedemptions, "csDIEM: no excess");

        uint256 excess = liquid - totalPendingRedemptions;

        emit ExcessRedeployed(msg.sender, excess);

        sdiem.stake(excess);
    }

    /**
     * @notice Ensure sDIEM withdrawal is initiated for pending redemptions.
     * @dev Anyone can call. Calculates the deficit between what's needed
     *      (totalPendingRedemptions) and what's covered (liquid + sDIEM pending),
     *      then requests the difference from sDIEM.
     */
    function syncWithdrawals() external override nonReentrant {
        _tryWithdrawFromSdiem();
    }

    // ── Internal ────────────────────────────────────────────────────────

    /**
     * @dev Attempt to initiate sDIEM withdrawal for uncovered pending redemptions.
     *      - Calculates deficit: needed - (liquid + sdiemPending)
     *      - Caps to sDIEM balance
     *      - Skips if below sDIEM minimum withdraw
     */
    function _tryWithdrawFromSdiem() internal {
        uint256 needed = totalPendingRedemptions;
        if (needed == 0) return;

        // What do we already have available?
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        (uint256 sdiemPending,) = sdiem.withdrawalRequests(address(this));
        uint256 covered = liquid + sdiemPending;
        if (covered >= needed) return;

        // Don't initiate a new sDIEM withdrawal if one is already pending.
        // Calling sdiem.requestWithdraw() would reset the 24h timer for ALL
        // csDIEM redeemers, enabling griefing via repeated requestRedeem calls.
        if (sdiemPending > 0) return;

        uint256 deficit = needed - covered;
        uint256 sdiemBal = sdiem.balanceOf(address(this));
        if (sdiemBal == 0) return;

        uint256 toRequest = deficit > sdiemBal ? sdiemBal : deficit;
        if (toRequest < SDIEM_MIN_WITHDRAW) return;

        sdiem.requestWithdraw(toRequest);
    }

    /**
     * @dev Swap USDC → DIEM via Slipstream CL with TWAP-based slippage protection.
     *      Identical to the swap logic previously in RevenueSplitter.
     */
    function _swapUsdcToDiem(uint256 usdcAmount, uint256 deadline) internal returns (uint256) {
        // 0. Bound the OracleLibrary input to uint128. USDC supply makes
        //    overflow implausible today, but an explicit guard removes the
        //    silent-truncation footgun. Pashov audit finding #4.
        require(usdcAmount <= type(uint128).max, "csDIEM: usdc amount > uint128");

        // 1. Query CL TWAP oracle for fair price
        int24 arithmeticMeanTick = OracleLibrary.consult(oraclePool, twapWindow);
        uint256 twapOut = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(usdcAmount),
            address(usdc),
            asset()
        );

        // 2. Apply slippage tolerance
        uint256 amountOutMin = (twapOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        // 3. Circuit breaker: enforce absolute minimum DIEM-per-USDC floor.
        //    Mandatory (no zero-default escape hatch). Pashov audit finding #3.
        require(minDiemPerUsdc > 0, "csDIEM: floor unset");
        uint256 absoluteMin = (usdcAmount * minDiemPerUsdc) / 1e6;
        require(amountOutMin >= absoluteMin, "csDIEM: price below floor");

        // 4. Approve router to spend USDC
        usdc.forceApprove(swapRouter, usdcAmount);

        // 5. Execute swap via Slipstream exactInputSingle
        uint256 amountOut = ICLSwapRouter(swapRouter).exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: asset(),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: deadline,
                amountIn: usdcAmount,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        // 6. Revoke residual allowance
        usdc.forceApprove(swapRouter, 0);

        require(amountOut > 0, "csDIEM: swap returned zero");
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
        require(newAdmin != address(0), "csDIEM: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "csDIEM: not pending admin");
        address oldAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, msg.sender);
    }

    function setSwapRouter(address newRouter) external override onlyAdmin {
        require(newRouter != address(0), "csDIEM: zero router");
        address old = swapRouter;
        swapRouter = newRouter;
        emit SwapRouterUpdated(old, newRouter);
    }

    function setMaxSlippage(uint256 newSlippage) external override onlyAdmin {
        require(newSlippage <= 1000, "csDIEM: slippage > 10%");
        uint256 old = maxSlippageBps;
        maxSlippageBps = newSlippage;
        emit MaxSlippageUpdated(old, newSlippage);
    }

    function setOraclePool(address newPool) external override onlyAdmin {
        require(newPool != address(0), "csDIEM: zero oracle");
        address old = oraclePool;
        oraclePool = newPool;
        emit OraclePoolUpdated(old, newPool);
    }

    function setTwapWindow(uint32 newWindow) external override onlyAdmin {
        require(newWindow >= MIN_TWAP_WINDOW, "csDIEM: twap too short");
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit TwapWindowUpdated(old, newWindow);
    }

    function setTickSpacing(int24 newSpacing) external override onlyAdmin {
        require(newSpacing > 0, "csDIEM: zero tick spacing");
        int24 old = tickSpacing;
        tickSpacing = newSpacing;
        emit TickSpacingUpdated(old, newSpacing);
    }

    function setMinDiemPerUsdc(uint256 newMin) external override onlyAdmin {
        require(newMin > 0, "csDIEM: zero floor");
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
    /// @dev Cannot recover DIEM (underlying) or USDC (harvest intermediate).
    function recoverERC20(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin {
        require(token != asset(), "csDIEM: cannot recover DIEM");
        require(token != address(usdc), "csDIEM: cannot recover USDC");
        require(to != address(0), "csDIEM: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }
}
