// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRevenueSplitter} from "./interfaces/IRevenueSplitter.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";

/**
 * @title RevenueSplitter
 * @notice 20/80 USDC revenue splitter for DIEM ecosystem.
 *         Platform fees to 2/2 Safe, staker rewards to sDIEM.notifyRewardAmount.
 *         Permissionless distribute() with 23h cooldown + min amount floor.
 *
 * Security:
 *   - Immutable USDC and sDIEM addresses.
 *   - Admin cannot rescue USDC (non-rug by design).
 *   - Admin config bounds (cooldown <= 7 days, minAmount <= 10,000 USDC).
 *   - CEI pattern on distribute().
 *   - ReentrancyGuard on distribute().
 *   - 2-step admin transfer.
 */
contract RevenueSplitter is IRevenueSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PLATFORM_BPS = 2_000;         // 20%
    uint256 public constant STAKER_BPS = 8_000;           // 80%
    uint256 public constant MIN_AMOUNT_CAP = 10_000e6;    // 10,000 USDC (6 decimals)
    uint256 public constant MAX_COOLDOWN = 7 days;
    uint256 public constant DEFAULT_MIN_AMOUNT = 100e6;   // 100 USDC
    uint256 public constant DEFAULT_COOLDOWN = 23 hours;

    // Immutables
    IERC20 public immutable override USDC;
    IsDIEM public immutable override sdiem;

    // State
    address public override admin;
    address public override pendingAdmin;
    address public override platformReceiver;
    uint256 public override minAmount;
    uint256 public override cooldown;
    uint256 public override lastDistribution;
    bool public override paused;

    uint256 public override totalPlatformPaid;
    uint256 public override totalStakerPaid;

    // Modifiers
    modifier onlyAdmin() {
        require(msg.sender == admin, "RS: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "RS: paused");
        _;
    }

    // Constructor
    constructor(
        IERC20 _usdc,
        IsDIEM _sdiem,
        address _admin,
        address _platformReceiver
    ) {
        require(address(_usdc) != address(0), "RS: zero usdc");
        require(address(_sdiem) != address(0), "RS: zero sdiem");
        require(_admin != address(0), "RS: zero admin");
        require(_platformReceiver != address(0), "RS: zero receiver");

        USDC = _usdc;
        sdiem = _sdiem;
        admin = _admin;
        platformReceiver = _platformReceiver;
        minAmount = DEFAULT_MIN_AMOUNT;
        cooldown = DEFAULT_COOLDOWN;
    }

    // Core
    function distribute() external override nonReentrant whenNotPaused {
        require(block.timestamp >= lastDistribution + cooldown, "RS: cooldown");

        uint256 bal = USDC.balanceOf(address(this));
        require(bal >= minAmount, "RS: below min");

        uint256 platformCut = (bal * PLATFORM_BPS) / BPS_DENOMINATOR;
        uint256 stakerCut = bal - platformCut;

        // Effects
        lastDistribution = block.timestamp;
        totalPlatformPaid += platformCut;
        totalStakerPaid += stakerCut;

        // Interactions
        USDC.safeTransfer(platformReceiver, platformCut);
        USDC.forceApprove(address(sdiem), stakerCut);
        sdiem.notifyRewardAmount(stakerCut);

        emit Distributed(msg.sender, platformCut, stakerCut, block.timestamp);
    }

    // Unimplemented stubs — filled in by later tasks via TDD.

    // Admin — config setters
    function setPlatformReceiver(address newReceiver) external override onlyAdmin {
        require(newReceiver != address(0), "RS: zero receiver");
        platformReceiver = newReceiver;
        emit PlatformReceiverSet(newReceiver);
    }

    function setMinAmount(uint256 newMinAmount) external override onlyAdmin {
        require(newMinAmount <= MIN_AMOUNT_CAP, "RS: min too high");
        minAmount = newMinAmount;
        emit MinAmountSet(newMinAmount);
    }

    function setCooldown(uint256 newCooldown) external override onlyAdmin {
        require(newCooldown <= MAX_COOLDOWN, "RS: cooldown too high");
        cooldown = newCooldown;
        emit CooldownSet(newCooldown);
    }

    // Admin — pause
    function pause() external override onlyAdmin {
        require(!paused, "RS: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyAdmin {
        require(paused, "RS: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // Admin — rescue
    function rescueToken(address token, address to, uint256 amount) external override onlyAdmin {
        require(token != address(USDC), "RS: cannot rescue USDC");
        require(to != address(0), "RS: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // Admin — transfer
    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "RS: zero new admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(newAdmin);
    }

    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "RS: not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferAccepted(msg.sender);
    }
}
