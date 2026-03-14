// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IDIEMVault
 * @notice Interface for the DIEM USDC deposit vault.
 *
 * Borrowers deposit USDC on-chain. An off-chain watcher listens for
 * `Deposited` events and credits the borrower's relay balance.
 *
 * Phase 1: deposit-only (no borrower withdrawal).
 */
interface IDIEMVault {
    // ── Events ──────────────────────────────────────────────────────────

    event Deposited(address indexed borrower, uint256 amount, uint256 fee, uint256 newBalance);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event MinDepositChanged(uint256 oldMin, uint256 newMin);
    event FeeBpsChanged(uint256 oldBps, uint256 newBps);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    // ── Views ───────────────────────────────────────────────────────────

    function depositToken() external view returns (IERC20);
    function admin() external view returns (address);
    function paused() external view returns (bool);
    function minDeposit() external view returns (uint256);
    function feeBps() external view returns (uint256);
    function totalDeposits() external view returns (uint256);
    function protocolFees() external view returns (uint256);
    function borrowerBalance(address borrower) external view returns (uint256);

    // ── Mutative ────────────────────────────────────────────────────────

    function deposit(uint256 amount) external;
    function withdrawProtocolFees(address to, uint256 amount) external;

    // ── Admin ───────────────────────────────────────────────────────────

    function pause() external;
    function unpause() external;
    function setMinDeposit(uint256 newMin) external;
    function setFeeBps(uint256 newFeeBps) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function recoverERC20(address token, address to, uint256 amount) external;
}
