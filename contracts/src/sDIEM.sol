// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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
contract sDIEM is IsDIEM, IERC1271, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant REWARDS_DURATION = 24 hours;
    uint256 public constant override WITHDRAWAL_DELAY = 24 hours;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MIN_WITHDRAW = 1e18; // 1 DIEM minimum withdrawal

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable override diem;
    IERC20 public immutable override usdc;

    /// @notice The DIEM token contract (which has staking built-in).
    IDIEMStaking public immutable diemStaking;

    // ── State — roles ───────────────────────────────────────────────────

    address public override admin;
    address public override pendingAdmin;
    address public override operator;
    bool public override paused;

    // ── State — staking ─────────────────────────────────────────────────

    uint256 public override totalStaked;
    mapping(address => uint256) private _balances;

    // ── State — withdrawals ─────────────────────────────────────────────

    uint256 public override totalPendingWithdrawals;
    uint256 public override totalPendingNotInitiated;
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

    /// @notice Returns the staked DIEM balance for `account`.
    /// @param account The address to query.
    /// @return The staked balance.
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @notice The latest timestamp at which rewards are still accruing.
    /// @return The lesser of `block.timestamp` and `periodFinish`.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Accumulated reward per staked token, scaled by 1e18.
    /// @return The current cumulative reward-per-token value.
    function rewardPerToken() public view override returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalStaked;
    }

    /// @notice Calculates the total USDC rewards earned by `account` so far.
    /// @param account The staker address.
    /// @return The claimable USDC reward amount.
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
    /// @dev Returns true if ANY amount can be paid out (partial withdrawal support).
    function canCompleteWithdraw(address account) external view override returns (bool) {
        WithdrawalRequest storage req = _withdrawalRequests[account];
        if (req.amount == 0) return false;
        if (block.timestamp < req.requestedAt + WITHDRAWAL_DELAY) return false;
        // Check liquid + claimable pending
        uint256 liquid = diem.balanceOf(address(this));
        (,uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));
        if (pending > 0 && block.timestamp >= cooldownEnd) {
            liquid += pending; // Would be claimed automatically
        }
        return liquid > 0;
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
        emit Staked(msg.sender, amount);

        // Interactions — pull DIEM then forward to Venice
        diem.safeTransferFrom(msg.sender, address(this), amount);
        diemStaking.stake(amount);
    }

    /**
     * @notice Request withdrawal. Starts 24h delay.
     * @dev Deducts from staker's balance. Auto-initiates Venice unstake
     *      if no cooldown is active, so both timers run in parallel.
     *      Always resets the 24h timer on each new request, even if
     *      an existing request is pending (fresh delay enforced).
     *      Minimum withdrawal: 1 DIEM (prevents dust griefing of Venice queue).
     */
    function requestWithdraw(uint256 amount)
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount >= MIN_WITHDRAW, "sDIEM: below minimum withdraw");
        require(_balances[msg.sender] >= amount, "sDIEM: insufficient balance");

        // Effects
        _balances[msg.sender] -= amount;
        totalStaked -= amount;

        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        req.amount += amount;
        // Always reset timer — each new request enforces a fresh 24h delay
        req.requestedAt = block.timestamp;
        totalPendingWithdrawals += amount;
        totalPendingNotInitiated += amount;
        emit WithdrawalRequested(msg.sender, amount);

        // Auto-initiate Venice unstake if possible
        _tryInitiateVeniceUnstake();
    }

    /**
     * @notice Complete withdrawal after 24h delay. Supports partial payouts.
     * @dev Auto-claims from Venice if cooldown has matured. Transfers whatever
     *      liquid DIEM is available (up to the requested amount). If the full
     *      amount isn't available, the remainder stays in the request and
     *      Venice unstake is auto-initiated for the next batch.
     *      This prevents one user's unfunded withdrawal from blocking others
     *      (critical for csDIEM which shares a single withdrawal slot).
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

        // Try to initiate Venice unstake for any pending amounts that weren't
        // initiated during requestWithdraw (e.g., Venice cooldown was active then).
        // Must run BEFORE the payout check — otherwise the revert at "nothing
        // claimable yet" prevents this from ever executing (M-02 fix).
        _tryInitiateVeniceUnstake();

        // Auto-claim from Venice if matured but not yet claimed
        uint256 liquid = diem.balanceOf(address(this));
        if (liquid < amount) {
            (, uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));
            if (pending > 0 && block.timestamp >= cooldownEnd) {
                diemStaking.unstake();
                liquid = diem.balanceOf(address(this));
            }
        }

        // Partial payout: transfer what's available
        uint256 payout = liquid >= amount ? amount : liquid;
        require(payout > 0, "sDIEM: nothing claimable yet");

        // Effects
        req.amount -= payout;
        if (req.amount == 0) {
            req.requestedAt = 0;
        }
        totalPendingWithdrawals -= payout;
        emit WithdrawalCompleted(msg.sender, payout);

        // Interaction — transfer available DIEM
        diem.safeTransfer(msg.sender, payout);

        // Auto-initiate Venice unstake for any pending uninitiated amounts.
        // This covers both this user's partial remainder AND other users'
        // amounts that couldn't be initiated when Venice cooldown was active.
        // _tryInitiateVeniceUnstake returns early if nothing to initiate.
        _tryInitiateVeniceUnstake();
    }

    /**
     * @notice Cancel a pending withdrawal and re-stake the DIEM.
     * @dev Returns the pending amount back to staked balance.
     *      Useful if a user changes their mind or is stuck waiting.
     */
    function cancelWithdraw()
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        uint256 amount = req.amount;
        require(amount > 0, "sDIEM: no pending withdrawal");

        // Effects — move back to staked balance
        req.amount = 0;
        req.requestedAt = 0;
        totalPendingWithdrawals -= amount;
        // Only decrement totalPendingNotInitiated by what hasn't been initiated yet.
        // The remainder was already initiated on Venice and will complete normally;
        // excess DIEM will be redeployed via redeployExcess().
        uint256 notInitiatedDeduction = amount > totalPendingNotInitiated ? totalPendingNotInitiated : amount;
        totalPendingNotInitiated -= notInitiatedDeduction;
        // Reconcile tracker against Venice reality to prevent phantom inflation
        // from cancel→re-request cycles (where _tryInitiateVeniceUnstake caps to
        // staked=0 but totalPendingNotInitiated keeps incrementing).
        (uint256 veniceStaked,,) = diemStaking.stakedInfos(address(this));
        if (totalPendingNotInitiated > veniceStaked) {
            totalPendingNotInitiated = veniceStaked;
        }
        _balances[msg.sender] += amount;
        totalStaked += amount;
        emit WithdrawalCancelled(msg.sender, amount);
    }

    /// @notice Claim accrued USDC rewards. Always allowed, even when paused.
    function claimReward()
        public
        override
        nonReentrant
        updateReward(msg.sender)
    {
        _claimReward(msg.sender);
    }

    /**
     * @notice Request full withdrawal + claim rewards in one tx.
     *         Always allowed, even when paused (users must be able to exit).
     * @dev Only requests the withdrawal — user must call completeWithdraw()
     *      after the 24h delay to actually receive DIEM.
     *      Auto-initiates Venice unstake if no cooldown is active.
     */
    function exit()
        external
        override
        nonReentrant
        updateReward(msg.sender)
    {
        uint256 bal = _balances[msg.sender];
        if (bal > 0) {
            // Effects
            _balances[msg.sender] = 0;
            totalStaked -= bal;

            WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
            req.amount += bal;
            // Always reset timer — each new request enforces a fresh 24h delay
            req.requestedAt = block.timestamp;
            totalPendingWithdrawals += bal;
            totalPendingNotInitiated += bal;
            emit WithdrawalRequested(msg.sender, bal);

            // Auto-initiate Venice unstake if possible
            _tryInitiateVeniceUnstake();
        }
        _claimReward(msg.sender);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _claimReward(address user) internal {
        uint256 reward = rewards[user];
        if (reward > 0) {
            // Effects
            rewards[user] = 0;
            emit RewardPaid(user, reward);

            // Interaction — use low-level call to handle USDC blacklisted recipients.
            // If transfer fails (e.g. blacklisted), restore rewards so user can try
            // claimRewardTo() with an alternate recipient address.
            (bool ok,) = address(usdc).call(
                abi.encodeCall(IERC20.transfer, (user, reward))
            );
            if (!ok) {
                rewards[user] = reward;
            }
        }
    }

    /**
     * @notice Claim accrued USDC rewards to an alternate address.
     * @dev Allows USDC-blacklisted stakers to redirect rewards elsewhere.
     * @param to The recipient address for the rewards.
     */
    function claimRewardTo(address to)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        require(to != address(0), "sDIEM: zero to");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit RewardPaid(msg.sender, reward);
            usdc.safeTransfer(to, reward);
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

        // Interaction — measure actual balance delta
        uint256 balBefore = diem.balanceOf(address(this));
        diemStaking.unstake();
        uint256 received = diem.balanceOf(address(this)) - balBefore;

        emit VeniceClaimed(msg.sender, received);
    }

    /**
     * @notice Batch-send accumulated withdrawal amounts to Venice. Anyone can call.
     * @dev Claims matured cooldown first (M-01 fix) to prevent re-locking.
     *      Reverts if Venice cooldown is still active or nothing to initiate.
     */
    function initiateVeniceUnstake() external override nonReentrant {
        require(totalPendingNotInitiated > 0, "sDIEM: nothing to initiate");
        _tryInitiateVeniceUnstake();
    }

    /**
     * @dev Internal: attempt to initiate Venice unstake for all pending amounts.
     *      - If matured pending exists, claims it first (M-01 fix).
     *      - If cooldown is active, silently returns (no revert for auto-calls).
     */
    function _tryInitiateVeniceUnstake() internal {
        uint256 amount = totalPendingNotInitiated;
        if (amount == 0) return;

        (uint256 staked, uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));

        if (pending > 0) {
            if (block.timestamp >= cooldownEnd) {
                // M-01 fix: claim matured cooldown before initiating new one
                diemStaking.unstake();
            } else {
                // Cooldown still active — can't initiate, return silently
                return;
            }
        }

        // Cap to what's actually staked to prevent phantom unstakes
        // (totalPendingNotInitiated can be inflated by cancel/complete flows)
        if (amount > staked) {
            amount = staked;
        }

        // Effects — only subtract what we actually initiated, not the full tracker
        totalPendingNotInitiated -= amount;
        if (amount == 0) return;
        emit VeniceUnstakeInitiated(msg.sender, amount);

        // Interaction
        diemStaking.initiateUnstake(amount);
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

        // Effects — event before external call
        emit ExcessRedeployed(msg.sender, excess);

        // Interaction — forward excess to Venice
        diemStaking.stake(excess);
    }

    // ── Operator — reward notification ──────────────────────────────────

    /**
     * @notice Seed a new 24h reward period. Pulls USDC from caller.
     * @dev L-01 fix: returns rounding dust to caller instead of stranding it.
     * @param reward Amount of USDC to distribute over the next 24 hours.
     */
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyOperator
        updateReward(address(0))
    {
        require(reward > 0, "sDIEM: zero reward");

        // Pull USDC from operator (single-tx instead of pre-transfer)
        usdc.safeTransferFrom(msg.sender, address(this), reward);

        uint256 total;
        if (block.timestamp >= periodFinish) {
            total = reward;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            total = leftover + reward;
        }

        rewardRate = total / REWARDS_DURATION;
        require(rewardRate > 0, "sDIEM: reward rate zero");

        // Sanity: contract must hold enough USDC to pay out (checked BEFORE dust
        // refund so it catches under-funded calls — after dust removal the check
        // would be tautological).
        uint256 balance = usdc.balanceOf(address(this));
        require(rewardRate <= balance / REWARDS_DURATION, "sDIEM: reward too high");

        // L-01 fix: return rounding dust to caller
        uint256 distributable = rewardRate * REWARDS_DURATION;
        uint256 dust = total - distributable;
        if (dust > 0) {
            usdc.safeTransfer(msg.sender, dust);
        }

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

    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "sDIEM: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Pending admin accepts the role, completing the two-step transfer.
    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "sDIEM: not pending admin");
        address oldAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, msg.sender);
    }

    /// @inheritdoc IsDIEM
    function recoverERC20(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin {
        require(token != address(diem), "sDIEM: cannot recover DIEM");
        require(token != address(usdc), "sDIEM: cannot recover USDC");
        require(to != address(0), "sDIEM: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // ── EIP-1271 — Smart contract signature verification ─────────────

    /**
     * @notice EIP-1271: Validates a signature on behalf of this contract.
     * @dev Venice uses this to verify the sDIEM contract controls its
     *      staking address. The admin signs messages off-chain and Venice
     *      calls isValidSignature() to verify against this contract.
     *
     *      Returns the EIP-1271 magic value (0x1626ba7e) if the signature
     *      was produced by the current admin. Returns 0xffffffff otherwise.
     *
     *      Admin rotation via transferAdmin/acceptAdmin automatically
     *      updates who can sign — no separate signer management needed.
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view override returns (bytes4) {
        address recovered = ECDSA.recover(hash, signature);
        if (recovered == admin) {
            return bytes4(0x1626ba7e); // EIP-1271 magic value
        }
        return bytes4(0xffffffff);
    }
}
