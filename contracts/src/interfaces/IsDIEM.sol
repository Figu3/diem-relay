// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IsDIEM
 * @notice Interface for Staked DIEM — deposit DIEM, earn USDC rewards.
 *
 * Synthetix StakingRewards fork with 24h async withdrawals.
 *
 * All deposited DIEM is forward-staked on Venice for compute credits.
 * Withdrawals require a 24h delay (matching Venice's unstake cooldown).
 *
 * Venice management (claimFromVenice, redeployExcess) is fully
 * permissionless — anyone can call when conditions are met.
 *
 * The implementation also supports EIP-1271 (IERC1271) so Venice can
 * verify the contract's admin signed authentication messages — this
 * links the on-chain stake to the operator's Venice API account.
 */
interface IsDIEM {
    // ── Structs ─────────────────────────────────────────────────────────────

    struct WithdrawalRequest {
        uint256 amount;
        uint256 requestedAt;
    }

    // ── Events ──────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event WithdrawalRequested(address indexed user, uint256 amount);
    event WithdrawalCompleted(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when anyone claims matured DIEM from Venice.
    event VeniceClaimed(address indexed caller, uint256 amount);

    /// @notice Emitted when anyone redeploys excess liquid DIEM to Venice.
    event ExcessRedeployed(address indexed caller, uint256 amount);

    /// @notice Emitted when anyone batches pending unstakes to Venice.
    event VeniceUnstakeInitiated(address indexed caller, uint256 amount);

    // ── Views ───────────────────────────────────────────────────────────────

    function diem() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function operator() external view returns (address);
    function paused() external view returns (bool);

    function totalStaked() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);

    /// @notice Total DIEM currently pending withdrawal across all users.
    function totalPendingWithdrawals() external view returns (uint256);

    /// @notice DIEM withdrawal amounts not yet sent to Venice for unstaking.
    function totalPendingNotInitiated() external view returns (uint256);

    /// @notice Withdrawal request for a specific user.
    function withdrawalRequests(address account) external view returns (uint256 amount, uint256 requestedAt);

    /// @notice Venice cooldown end timestamp for this contract.
    function veniceCooldownEnd() external view returns (uint256);

    /// @notice Delay before withdrawals can be completed (matches Venice cooldown).
    function WITHDRAWAL_DELAY() external view returns (uint256);

    // ── Mutative — staking ──────────────────────────────────────────────────

    /// @notice Stake DIEM. Tokens are forwarded to Venice immediately.
    function stake(uint256 amount) external;

    /// @notice Request withdrawal. Starts 24h delay. Call initiateVeniceUnstake() to batch-send to Venice.
    function requestWithdraw(uint256 amount) external;

    /// @notice Complete withdrawal after 24h delay + Venice cooldown.
    function completeWithdraw() external;

    /// @notice Claim accrued USDC rewards.
    function claimReward() external;

    /// @notice Request full withdrawal + claim rewards in one tx.
    function exit() external;

    // ── Permissionless — Venice management ───────────────────────────────────

    /// @notice Claim matured DIEM from Venice. Anyone can call.
    function claimFromVenice() external;

    /// @notice Redeploy excess liquid DIEM (above pending withdrawals) to Venice.
    function redeployExcess() external;

    /// @notice Batch-send accumulated withdrawal amounts to Venice. Anyone can call.
    /// @dev Calls diemStaking.initiateUnstake() once for all pending amounts,
    ///      minimizing cooldown resets.
    function initiateVeniceUnstake() external;

    // ── Operator ────────────────────────────────────────────────────────────

    /// @notice Seed a new 24h USDC reward period.
    function notifyRewardAmount(uint256 reward) external;

    // ── Admin ───────────────────────────────────────────────────────────────

    function pause() external;
    function unpause() external;
    function setOperator(address newOperator) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;

    /// @notice Recover tokens accidentally sent to the contract.
    /// @dev Cannot recover DIEM or USDC.
    function recoverERC20(address token, address to, uint256 amount) external;
}
