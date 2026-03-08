// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IsDIEM} from "./interfaces/IsDIEM.sol";
import {IDIEMStaking} from "./interfaces/IDIEMStaking.sol";

/**
 * @title sDIEM
 * @notice Staked DIEM — deposit DIEM, earn USDC rewards.
 *
 * Synthetix StakingRewards fork with 24h async withdrawals.
 *
 * All deposited DIEM is immediately forward-staked on Venice for
 * compute credits ($1/day per staked DIEM). No liquid buffer needed.
 *
 * Withdrawals use a request/complete pattern with a 24h delay,
 * matching Venice's unstake cooldown. Venice management is fully
 * permissionless — anyone can call claimFromVenice() or redeployExcess().
 *
 * An off-chain operator (or RevenueSplitter contract) calls
 * `notifyRewardAmount()` daily with USDC revenue. Rewards stream
 * linearly over 24 hours to all stakers pro-rata.
 *
 * Key differences from vanilla Synthetix StakingRewards:
 *   - Reward token is USDC (6 decimals) instead of 18-decimal token.
 *     Precision is safe because `rewardPerTokenStored` uses 1e18 scaling.
 *   - All DIEM forward-staked on Venice for compute credits.
 *   - 24h async withdrawal instead of instant withdraw.
 *   - Emergency pause on stake/claim.
 *   - Operator role separated from admin.
 */
contract sDIEM is IsDIEM, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant REWARDS_DURATION = 24 hours;
    uint256 public constant override WITHDRAWAL_DELAY = 24 hours;
    uint256 private constant PRECISION = 1e18;

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable override diem;
    IERC20 public immutable override usdc;

    /// @notice The DIEM token contract (which has staking built-in).
    IDIEMStaking public immutable diemStaking;

    // ── State — roles ───────────────────────────────────────────────────

    address public immutable admin;
    address public override operator;
    bool public override paused;

    // ── State — staking ─────────────────────────────────────────────────

    uint256 public override totalStaked;
    mapping(address => uint256) private _balances;

    // ── State — withdrawals ─────────────────────────────────────────────

    uint256 public override totalPendingWithdrawals;
    mapping(address => WithdrawalRequest) private _withdrawalRequests;

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
        // DIEM token contract has staking built-in — same address
        diemStaking = IDIEMStaking(_diem);
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

    /// @inheritdoc IsDIEM
    function withdrawalRequests(address account)
        external
        view
        override
        returns (uint256 amount, uint256 requestedAt)
    {
        WithdrawalRequest storage req = _withdrawalRequests[account];
        return (req.amount, req.requestedAt);
    }

    /// @inheritdoc IsDIEM
    function veniceCooldownEnd() external view override returns (uint256) {
        (, uint256 cooldownEnd,) = diemStaking.stakedInfos(address(this));
        return cooldownEnd;
    }

    // ── Mutative — staking ──────────────────────────────────────────────

    /**
     * @notice Stake DIEM. Tokens are transferred in and immediately
     *         forward-staked on Venice for compute credits.
     */
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

        // Interactions — pull DIEM then forward to Venice
        diem.safeTransferFrom(msg.sender, address(this), amount);
        diemStaking.stake(amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Request withdrawal. Starts 24h delay.
     * @dev Deducts from staker's balance. Initiates Venice unstake
     *      (which starts the 24h cooldown). Warning: Venice resets
     *      the cooldown timer for ALL pending if called again.
     *      Users with existing pending requests accumulate amounts.
     */
    function requestWithdraw(uint256 amount)
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "sDIEM: zero amount");
        require(_balances[msg.sender] >= amount, "sDIEM: insufficient balance");

        // Effects
        _balances[msg.sender] -= amount;
        totalStaked -= amount;

        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        req.amount += amount;
        req.requestedAt = block.timestamp;
        totalPendingWithdrawals += amount;

        // Interaction — initiate Venice unstake (starts/resets cooldown)
        diemStaking.initiateUnstake(amount);

        emit WithdrawalRequested(msg.sender, amount);
    }

    /**
     * @notice Complete withdrawal after 24h delay.
     * @dev Requires:
     *      1. User's personal 24h delay has elapsed
     *      2. Contract has enough liquid DIEM (call claimFromVenice first if needed)
     */
    function completeWithdraw()
        external
        override
        nonReentrant
    {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        uint256 amount = req.amount;
        require(amount > 0, "sDIEM: no pending withdrawal");
        require(
            block.timestamp >= req.requestedAt + WITHDRAWAL_DELAY,
            "sDIEM: withdrawal delay not met"
        );

        uint256 liquid = diem.balanceOf(address(this));
        require(liquid >= amount, "sDIEM: claim from Venice first");

        // Effects
        req.amount = 0;
        req.requestedAt = 0;
        totalPendingWithdrawals -= amount;

        // Interaction
        diem.safeTransfer(msg.sender, amount);

        emit WithdrawalCompleted(msg.sender, amount);
    }

    /// @notice Claim accrued USDC rewards.
    function claimReward()
        public
        override
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        _claimReward(msg.sender);
    }

    /**
     * @notice Request full withdrawal + claim rewards in one tx.
     * @dev Only requests the withdrawal — user must call completeWithdraw()
     *      after the 24h delay to actually receive DIEM.
     */
    function exit()
        external
        override
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        uint256 bal = _balances[msg.sender];
        if (bal > 0) {
            // Effects
            _balances[msg.sender] = 0;
            totalStaked -= bal;

            WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
            req.amount += bal;
            req.requestedAt = block.timestamp;
            totalPendingWithdrawals += bal;

            // Interaction — initiate Venice unstake
            diemStaking.initiateUnstake(bal);

            emit WithdrawalRequested(msg.sender, bal);
        }
        _claimReward(msg.sender);
    }

    // ── Internal ────────────────────────────────────────────────────────

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

    // ── Permissionless — Venice management ──────────────────────────────

    /**
     * @notice Claim matured DIEM from Venice. Anyone can call.
     * @dev Calls diemStaking.unstake() which transfers all pending
     *      DIEM back after cooldown. Reverts if cooldown hasn't expired.
     */
    function claimFromVenice() external override nonReentrant {
        (,, uint256 pending) = diemStaking.stakedInfos(address(this));
        require(pending > 0, "sDIEM: nothing pending on Venice");

        // Interaction
        diemStaking.unstake();

        emit VeniceClaimed(msg.sender, pending);
    }

    /**
     * @notice Redeploy excess liquid DIEM to Venice. Anyone can call.
     * @dev Any liquid DIEM beyond what's needed for pending withdrawals
     *      is excess and should be earning Venice compute credits.
     */
    function redeployExcess() external override nonReentrant {
        uint256 liquid = diem.balanceOf(address(this));
        require(liquid > totalPendingWithdrawals, "sDIEM: no excess to redeploy");

        uint256 excess = liquid - totalPendingWithdrawals;

        // Interaction — forward excess to Venice
        diemStaking.stake(excess);

        emit ExcessRedeployed(msg.sender, excess);
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
