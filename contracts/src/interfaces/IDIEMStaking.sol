// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IDIEMStaking
 * @notice Interface for the DIEM token's built-in staking mechanism.
 * @dev Reverse-engineered from the DIEM token contract on Base
 *      (0xf4d97f2da56e8c3098f3a8d538db630a2606a024).
 *
 *      Staking is built directly into the ERC-20 token — calling `stake()`
 *      transfers tokens from the caller's `balanceOf` into the contract's
 *      own `balanceOf` and tracks the staked amount in `stakedInfos`.
 *
 *      Unstaking is two-step:
 *        1. `initiateUnstake(amount)` — starts cooldown (24h), amount moves
 *           from `stakedAmount` to `pendingUnstakeAmount`
 *        2. `unstake()` — after cooldown expires, transfers pending amount
 *           back to caller's `balanceOf`
 *
 *      Important: calling `initiateUnstake()` again while one is pending
 *      accumulates the pending amount AND resets the cooldown timer.
 *
 *      No EOA restriction — smart contracts can call `stake()`.
 *      No approval needed — `stake()` does internal balance adjustment.
 */
interface IDIEMStaking {
    /// @notice Stake DIEM tokens. Transfers from caller's balanceOf to
    ///         the contract's balanceOf. No approval needed.
    /// @param amount Amount of DIEM to stake (18 decimals).
    function stake(uint256 amount) external;

    /// @notice Begin the unstaking process. Starts the cooldown timer.
    ///         Moves `amount` from stakedAmount to pendingUnstakeAmount.
    ///         If called again while pending, accumulates and resets cooldown.
    /// @param amount Amount of DIEM to unstake.
    function initiateUnstake(uint256 amount) external;

    /// @notice Complete the unstaking process after cooldown expires.
    ///         Transfers pendingUnstakeAmount back to caller's balanceOf.
    function unstake() external;

    /// @notice Returns the cooldown duration in seconds (currently 86400 = 24h).
    function cooldownDuration() external view returns (uint256);

    /// @notice Returns staking info for an address.
    /// @return stakedAmount Currently staked DIEM.
    /// @return cooldownEndTimestamp When the current cooldown expires (0 if none).
    /// @return pendingUnstakeAmount DIEM pending unstake (in cooldown).
    function stakedInfos(address account) external view returns (
        uint256 stakedAmount,
        uint256 cooldownEndTimestamp,
        uint256 pendingUnstakeAmount
    );

    /// @notice Total DIEM staked across all stakers.
    function totalStaked() external view returns (uint256);

    /// @notice Standard ERC-20 balance (un-staked, liquid DIEM).
    function balanceOf(address account) external view returns (uint256);
}
