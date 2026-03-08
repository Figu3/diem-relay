// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDIEMVault} from "./interfaces/IDIEMVault.sol";

/**
 * @title DIEMVault
 * @notice USDC deposit vault for the DIEM Relay.
 *
 * Borrowers deposit USDC here; an off-chain watcher picks up `Deposited`
 * events and credits the corresponding relay account.
 *
 * Phase 1 — deposit-only. No borrower withdrawals.
 *
 * Security:
 *   - Reserve segregation: `totalDeposits` vs `protocolFees` tracked separately.
 *   - Emergency pause on `deposit()`.
 *   - CEI pattern everywhere.
 *   - SafeERC20 for all token ops (USDT, USDC safe).
 *   - Zero-address checks on constructor + admin setters.
 *   - Events on every state change.
 *   - `depositToken` is immutable.
 */
contract DIEMVault is IDIEMVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_MIN_DEPOSIT = 10e6; // 10 USDC (6 decimals)

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable override depositToken;

    // ── State ───────────────────────────────────────────────────────────

    address public override admin;
    bool public override paused;
    uint256 public override minDeposit;
    uint256 public override totalDeposits;
    uint256 public override protocolFees;
    mapping(address => uint256) public override borrowerBalance;

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "DIEMVault: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DIEMVault: paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(address _depositToken, address _admin) {
        require(_depositToken != address(0), "DIEMVault: zero token");
        require(_admin != address(0), "DIEMVault: zero admin");

        depositToken = IERC20(_depositToken);
        admin = _admin;
        minDeposit = DEFAULT_MIN_DEPOSIT;
    }

    // ── Deposit ─────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC into the vault. Caller must have approved this
     *         contract for at least `amount` of `depositToken`.
     * @param amount Amount of deposit token (6 decimals for USDC).
     */
    function deposit(uint256 amount) external override nonReentrant whenNotPaused {
        require(amount >= minDeposit, "DIEMVault: below min deposit");

        // Effects
        borrowerBalance[msg.sender] += amount;
        totalDeposits += amount;

        // Interaction
        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount, borrowerBalance[msg.sender]);
    }

    // ── Protocol fee withdrawal ─────────────────────────────────────────

    /**
     * @notice Withdraw accumulated protocol fees to `to`.
     * @param to   Destination address.
     * @param amount Amount to withdraw (must be <= protocolFees).
     */
    function withdrawProtocolFees(address to, uint256 amount) external override onlyAdmin {
        require(to != address(0), "DIEMVault: zero address");
        require(amount > 0, "DIEMVault: zero amount");
        require(amount <= protocolFees, "DIEMVault: exceeds fees");

        // Effects
        protocolFees -= amount;

        // Interaction
        depositToken.safeTransfer(to, amount);

        emit ProtocolFeesWithdrawn(to, amount);
    }

    // ── Admin functions ─────────────────────────────────────────────────

    function pause() external override onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Update the minimum deposit amount.
    /// @param newMin New minimum in deposit token units (6 decimals for USDC).
    function setMinDeposit(uint256 newMin) external override onlyAdmin {
        uint256 oldMin = minDeposit;
        minDeposit = newMin;
        emit MinDepositChanged(oldMin, newMin);
    }

    /// @notice Transfer admin role to a new address.
    /// @param newAdmin The new admin address (must not be zero).
    function setAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "DIEMVault: zero admin");
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminChanged(oldAdmin, newAdmin);
    }
}
