// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title IsDIEMv2
 * @notice Interface for Staked DIEM v2 — ERC-20 + EIP-2612 + Synthetix-style rewards.
 *
 * sDIEM v2 is a transferable ERC-20 representing a claim on staked DIEM.
 * Stakers deposit DIEM, earn USDC rewards, and can transfer their sDIEM
 * freely to anyone (including ERC-4626 wrappers, lending markets, etc).
 *
 * DIEM is forward-staked on Venice for compute credits, exactly as in v1.
 * Withdrawals use a request/complete pattern with a 24h delay matching
 * Venice's cooldown.
 *
 * Differences from v1:
 *   - Full ERC-20 surface (transfer/transferFrom/approve + EIP-2612 permit).
 *   - Reward accounting checkpointed on every transfer via _update hook —
 *     prevents the Synthetix-ERC20 reward-leak trap.
 *   - Withdrawal queue is per-address and does NOT transfer with sDIEM.
 *     If Alice has 10 sDIEM + 5 queued, transferring sDIEM to Bob moves
 *     only liquid sDIEM. Alice keeps her queued withdrawal.
 */
interface IsDIEMv2 is IERC20, IERC20Permit, IERC1271 {
    // ── Structs ─────────────────────────────────────────────────────────────

    struct WithdrawalRequest {
        uint256 amount;
        uint256 requestedAt;
    }

    // ── Events ──────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event WithdrawalRequested(address indexed user, uint256 amount);
    event WithdrawalCompleted(address indexed user, uint256 amount);
    event WithdrawalCancelled(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    event VeniceClaimed(address indexed caller, uint256 amount);
    event ExcessRedeployed(address indexed caller, uint256 amount);
    event VeniceUnstakeInitiated(address indexed caller, uint256 amount);

    // ── Views ───────────────────────────────────────────────────────────────

    function diem() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function operator() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Total sDIEM in existence; equals total DIEM currently staked
    ///         (not counting amounts pending withdrawal, which are burned).
    function totalStaked() external view returns (uint256);

    function earned(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);

    function totalPendingWithdrawals() external view returns (uint256);
    function totalPendingNotInitiated() external view returns (uint256);

    function withdrawalRequests(address account) external view returns (uint256 amount, uint256 requestedAt);
    function canCompleteWithdraw(address account) external view returns (bool);
    function veniceCooldownEnd() external view returns (uint256);

    function WITHDRAWAL_DELAY() external view returns (uint256);

    // ── Mutative — staking ──────────────────────────────────────────────────

    function stake(uint256 amount) external;
    function requestWithdraw(uint256 amount) external;
    function completeWithdraw() external;
    function cancelWithdraw() external;
    function claimReward() external;
    function claimRewardTo(address to) external;
    function exit() external;

    // ── Permissionless — Venice management ──────────────────────────────────

    function claimFromVenice() external;
    function redeployExcess() external;
    function initiateVeniceUnstake() external;

    // ── Operator ────────────────────────────────────────────────────────────

    function notifyRewardAmount(uint256 reward) external;

    // ── Admin ───────────────────────────────────────────────────────────────

    function pause() external;
    function unpause() external;
    function setOperator(address newOperator) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
    function recoverERC20(address token, address to, uint256 amount) external;
}
