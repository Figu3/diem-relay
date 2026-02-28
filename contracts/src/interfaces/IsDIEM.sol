// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IsDIEM {
    // ── Events ────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);

    // ── Views ─────────────────────────────────────────────────────────────
    function diem() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function operator() external view returns (address);
    function paused() external view returns (bool);

    function totalStaked() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);

    // ── Mutative ──────────────────────────────────────────────────────────
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimReward() external;
    function exit() external;

    // ── Operator ──────────────────────────────────────────────────────────
    function notifyRewardAmount(uint256 reward) external;

    // ── Admin ─────────────────────────────────────────────────────────────
    function pause() external;
    function unpause() external;
    function setOperator(address newOperator) external;
}
