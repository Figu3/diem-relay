// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";

/**
 * @title sDIEM
 * @notice Staked DIEM — deposit DIEM, earn USDC rewards.
 *
 * Synthetix StakingRewards fork. An off-chain operator sells Venice AI
 * compute credits and calls `notifyRewardAmount()` daily with USDC revenue.
 * Rewards stream linearly over 24 hours to all stakers pro-rata.
 *
 * Key differences from vanilla Synthetix:
 *   - Reward token is USDC (6 decimals) instead of 18-decimal token.
 *     Precision is safe because `rewardPerTokenStored` uses 1e18 scaling.
 *   - No withdrawal cooldown — instant unstake.
 *   - Emergency pause on stake/withdraw/claim.
 *   - Operator role (can notify rewards) separated from admin (can pause/set operator).
 */
contract sDIEM is IsDIEM, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant REWARDS_DURATION = 24 hours;
    uint256 private constant PRECISION = 1e18;

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable override diem;
    IERC20 public immutable override usdc;

    // ── State — roles ───────────────────────────────────────────────────

    address public immutable admin;
    address public override operator;
    bool public override paused;

    // ── State — staking ─────────────────────────────────────────────────

    uint256 public override totalStaked;
    mapping(address => uint256) private _balances;

    // ── State — rewards ─────────────────────────────────────────────────

    uint256 public override rewardRate;
    uint256 public override periodFinish;
    uint256 public override lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "sDIEM: not admin");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "sDIEM: not operator");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "sDIEM: paused");
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(address _diem, address _usdc, address _admin, address _operator) {
        require(_diem != address(0), "sDIEM: zero diem");
        require(_usdc != address(0), "sDIEM: zero usdc");
        require(_admin != address(0), "sDIEM: zero admin");
        require(_operator != address(0), "sDIEM: zero operator");

        diem = IERC20(_diem);
        usdc = IERC20(_usdc);
        admin = _admin;
        operator = _operator;
    }

    // ── Views ───────────────────────────────────────────────────────────

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view override returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalStaked;
    }

    function earned(address account) public view override returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    // ── Mutative — staking ──────────────────────────────────────────────

    function stake(uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "sDIEM: zero amount");

        // Effects
        totalStaked += amount;
        _balances[msg.sender] += amount;

        // Interaction
        diem.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        _withdraw(msg.sender, amount);
    }

    function claimReward()
        public
        override
        nonReentrant
        updateReward(msg.sender)
    {
        _claimReward(msg.sender);
    }

    function exit()
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        _withdraw(msg.sender, _balances[msg.sender]);
        _claimReward(msg.sender);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _withdraw(address user, uint256 amount) internal {
        require(amount > 0, "sDIEM: zero amount");
        require(_balances[user] >= amount, "sDIEM: insufficient balance");

        // Effects
        totalStaked -= amount;
        _balances[user] -= amount;

        // Interaction
        diem.safeTransfer(user, amount);

        emit Withdrawn(user, amount);
    }

    function _claimReward(address user) internal {
        uint256 reward = rewards[user];
        if (reward > 0) {
            // Effects
            rewards[user] = 0;

            // Interaction
            usdc.safeTransfer(user, reward);

            emit RewardPaid(user, reward);
        }
    }

    // ── Operator — reward notification ──────────────────────────────────

    /**
     * @notice Seed a new 24h reward period. Operator must have transferred
     *         `reward` USDC to this contract before calling.
     * @param reward Amount of USDC to distribute over the next 24 hours.
     */
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyOperator
        updateReward(address(0))
    {
        require(reward > 0, "sDIEM: zero reward");

        if (block.timestamp >= periodFinish) {
            // New period
            rewardRate = reward / REWARDS_DURATION;
        } else {
            // Extend existing period — add leftover + new
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (leftover + reward) / REWARDS_DURATION;
        }

        // Sanity: contract must hold enough USDC to pay out
        uint256 balance = usdc.balanceOf(address(this));
        require(rewardRate <= balance / REWARDS_DURATION, "sDIEM: reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARDS_DURATION;

        emit RewardNotified(reward, rewardRate, periodFinish);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function pause() external override onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setOperator(address newOperator) external override onlyAdmin {
        require(newOperator != address(0), "sDIEM: zero operator");
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorChanged(oldOperator, newOperator);
    }
}
