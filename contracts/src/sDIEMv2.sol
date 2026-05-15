// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IsDIEMv2} from "./interfaces/IsDIEMv2.sol";
import {IDIEMStaking} from "./interfaces/IDIEMStaking.sol";

/**
 * @title sDIEM v2
 * @notice ERC-20 transferable Staked DIEM with Synthetix-style USDC rewards.
 *
 * v2 vs v1: full ERC-20 + EIP-2612 transferability. Rewards are checkpointed
 * in the _update hook on every mint/burn/transfer so that:
 *   - Recipients of a transfer cannot retroactively claim rewards that
 *     accrued to the sender before the transfer (Synthetix-ERC20 trap).
 *   - Senders keep all rewards earned through the moment of transfer.
 *
 * The withdrawal queue is intentionally per-address and does NOT transfer
 * with sDIEM. If Alice queues 5 sDIEM for withdrawal and then transfers
 * her remaining 10 sDIEM to Bob, Bob receives 10 sDIEM with no queue
 * baggage; Alice retains her 5 queued for the 24h delay.
 *
 * All Venice forwarding, two-step admin, pause, EIP-1271, and the v1 audit
 * fixes (M-01 stale-cooldown claim, M-02 ordering, L-01 dust refund) are
 * preserved verbatim.
 */
contract sDIEMv2 is IsDIEMv2, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant REWARDS_DURATION = 24 hours;
    uint256 public constant override WITHDRAWAL_DELAY = 24 hours;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MIN_WITHDRAW = 1e18; // 1 DIEM minimum withdrawal

    // ── Immutables ──────────────────────────────────────────────────────

    IERC20 public immutable override diem;
    IERC20 public immutable override usdc;
    IDIEMStaking public immutable diemStaking;

    // ── State — roles ───────────────────────────────────────────────────

    address public override admin;
    address public override pendingAdmin;
    address public override operator;
    bool public override paused;

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
        require(msg.sender == admin, "sDIEMv2: not admin");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "sDIEMv2: not operator");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "sDIEMv2: paused");
        _;
    }

    /// @dev Checkpoint global reward accumulator + (optionally) one user.
    ///      Use this for ops that don't touch balances (claim, notify).
    ///      Balance-changing ops (stake, requestWithdraw, transfer) are
    ///      checkpointed automatically via the _update override.
    modifier updateReward(address account) {
        _checkpointGlobal();
        if (account != address(0)) _checkpointUser(account);
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(address _diem, address _usdc, address _admin, address _operator)
        ERC20("Staked DIEM", "sDIEM")
        ERC20Permit("Staked DIEM")
    {
        require(_diem != address(0), "sDIEMv2: zero diem");
        require(_usdc != address(0), "sDIEMv2: zero usdc");
        require(_admin != address(0), "sDIEMv2: zero admin");
        require(_operator != address(0), "sDIEMv2: zero operator");

        diem = IERC20(_diem);
        usdc = IERC20(_usdc);
        diemStaking = IDIEMStaking(_diem);
        admin = _admin;
        operator = _operator;
    }

    // ── Diamond override ────────────────────────────────────────────────

    /// @dev Resolves `nonces` defined in both ERC20Permit and IERC20Permit.
    function nonces(address owner)
        public
        view
        override(ERC20Permit, IERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    // ── ERC-20 hook: reward checkpoint on every balance change ──────────

    /**
     * @dev OZ v5's single hook for mint/burn/transfer. We checkpoint rewards
     *      BEFORE the balance change so that:
     *        - For a transfer (from, to, v): sender's accrued rewards are
     *          captured in rewards[from], and recipient's userRewardPerTokenPaid
     *          is initialized to the current rewardPerToken — preventing the
     *          Synthetix-ERC20 reward-leak trap.
     *        - For a mint (0, to, v): recipient is checkpointed; the new supply
     *          starts earning from now.
     *        - For a burn (from, 0, v): sender's accrued rewards are captured
     *          before their balance drops.
     */
    function _update(address from, address to, uint256 value) internal override {
        _checkpointGlobal();
        if (from != address(0)) _checkpointUser(from);
        if (to != address(0)) _checkpointUser(to);
        super._update(from, to, value);
    }

    function _checkpointGlobal() internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    function _checkpointUser(address user) internal {
        rewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice Total sDIEM in existence; equivalent to total DIEM staked
    ///         (since stake mints 1:1 and requestWithdraw burns).
    function totalStaked() external view override returns (uint256) {
        return totalSupply();
    }

    /// @notice The latest timestamp at which rewards are still accruing.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Accumulated reward per staked token, scaled by 1e18.
    function rewardPerToken() public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / supply;
    }

    /// @notice Total USDC rewards earned by `account` so far (claimable now).
    function earned(address account) public view override returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    function withdrawalRequests(address account)
        external
        view
        override
        returns (uint256 amount, uint256 requestedAt)
    {
        WithdrawalRequest storage req = _withdrawalRequests[account];
        return (req.amount, req.requestedAt);
    }

    function canCompleteWithdraw(address account) external view override returns (bool) {
        WithdrawalRequest storage req = _withdrawalRequests[account];
        if (req.amount == 0) return false;
        if (block.timestamp < req.requestedAt + WITHDRAWAL_DELAY) return false;
        uint256 liquid = diem.balanceOf(address(this));
        (, uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));
        if (pending > 0 && block.timestamp >= cooldownEnd) {
            liquid += pending;
        }
        return liquid > 0;
    }

    function veniceCooldownEnd() external view override returns (uint256) {
        (, uint256 cooldownEnd,) = diemStaking.stakedInfos(address(this));
        return cooldownEnd;
    }

    /**
     * @notice DIEM amount of pending withdrawals that still needs to be
     *         pulled from Venice via `initiateUnstake`.
     * @dev Derived from current state — equals
     *         max(0, totalPendingWithdrawals - liquidDiem - venicePending),
     *         capped to actually-available Venice stake.
     *      A pure view eliminates the phantom-counter desync that arises
     *      when a matured cooldown is claimed without explicit accounting.
     */
    function totalPendingNotInitiated() public view override returns (uint256) {
        uint256 owed = totalPendingWithdrawals;
        if (owed == 0) return 0;
        (uint256 staked,, uint256 pending) = diemStaking.stakedInfos(address(this));
        uint256 liquid = diem.balanceOf(address(this));
        uint256 covered = liquid + pending;
        if (covered >= owed) return 0;
        uint256 deficit = owed - covered;
        return deficit > staked ? staked : deficit;
    }

    // ── Mutative — staking ──────────────────────────────────────────────

    /// @notice Stake DIEM. Mints sDIEM 1:1, forwards DIEM to Venice.
    function stake(uint256 amount) external override nonReentrant whenNotPaused {
        require(amount > 0, "sDIEMv2: zero amount");

        // Mint triggers _update → reward checkpoint for msg.sender.
        _mint(msg.sender, amount);
        emit Staked(msg.sender, amount);

        // Interactions — pull DIEM then forward to Venice
        diem.safeTransferFrom(msg.sender, address(this), amount);
        diemStaking.stake(amount);
    }

    /**
     * @notice Request withdrawal. Burns sDIEM, queues DIEM for the 24h delay.
     * @dev Burning triggers _update → reward checkpoint. Queue is per-address
     *      and is NOT transferred when sDIEM is transferred.
     */
    function requestWithdraw(uint256 amount) external override nonReentrant {
        require(amount >= MIN_WITHDRAW, "sDIEMv2: below minimum withdraw");
        require(balanceOf(msg.sender) >= amount, "sDIEMv2: insufficient balance");

        // Burn triggers _update → reward checkpoint
        _burn(msg.sender, amount);

        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        req.amount += amount;
        req.requestedAt = block.timestamp; // always fresh 24h
        totalPendingWithdrawals += amount;
        emit WithdrawalRequested(msg.sender, amount);

        _tryInitiateVeniceUnstake();
    }

    /**
     * @notice Complete withdrawal after 24h delay. Supports partial payouts.
     * @dev Auto-claims from Venice if cooldown has matured. M-02 ordering
     *      preserved: try to initiate before the payout-zero check, so
     *      stuck cooldowns don't block forever.
     */
    function completeWithdraw() external override nonReentrant {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        uint256 amount = req.amount;
        require(amount > 0, "sDIEMv2: no pending withdrawal");
        require(
            block.timestamp >= req.requestedAt + WITHDRAWAL_DELAY,
            "sDIEMv2: withdrawal delay not met"
        );

        // M-02: initiate BEFORE the "nothing claimable yet" revert path.
        _tryInitiateVeniceUnstake();

        uint256 liquid = diem.balanceOf(address(this));
        if (liquid < amount) {
            (, uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));
            if (pending > 0 && block.timestamp >= cooldownEnd) {
                diemStaking.unstake();
                liquid = diem.balanceOf(address(this));
            }
        }

        uint256 payout = liquid >= amount ? amount : liquid;
        require(payout > 0, "sDIEMv2: nothing claimable yet");

        req.amount -= payout;
        if (req.amount == 0) {
            req.requestedAt = 0;
        }
        totalPendingWithdrawals -= payout;
        emit WithdrawalCompleted(msg.sender, payout);

        diem.safeTransfer(msg.sender, payout);

        _tryInitiateVeniceUnstake();
    }

    /// @notice Cancel a pending withdrawal and re-mint sDIEM 1:1.
    function cancelWithdraw() external override nonReentrant {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        uint256 amount = req.amount;
        require(amount > 0, "sDIEMv2: no pending withdrawal");

        req.amount = 0;
        req.requestedAt = 0;
        totalPendingWithdrawals -= amount;

        // Re-mint triggers _update → reward checkpoint
        _mint(msg.sender, amount);
        emit WithdrawalCancelled(msg.sender, amount);
    }

    /// @notice Claim accrued USDC rewards.
    function claimReward() public override nonReentrant updateReward(msg.sender) {
        _claimReward(msg.sender);
    }

    /**
     * @notice Request full withdrawal + claim rewards in one tx.
     * @dev Always allowed, even when paused — users must be able to exit.
     */
    function exit() external override nonReentrant {
        uint256 bal = balanceOf(msg.sender);
        if (bal > 0) {
            _burn(msg.sender, bal);

            WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
            req.amount += bal;
            req.requestedAt = block.timestamp;
            totalPendingWithdrawals += bal;
            emit WithdrawalRequested(msg.sender, bal);

            _tryInitiateVeniceUnstake();
        }
        // _claimReward checkpoints manually
        _checkpointGlobal();
        _checkpointUser(msg.sender);
        _claimReward(msg.sender);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _claimReward(address user) internal {
        uint256 reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            emit RewardPaid(user, reward);

            // Low-level call to handle USDC-blacklisted recipients without
            // bricking exit. If the transfer reverts, restore rewards so the
            // user can call claimRewardTo() with an alternate recipient.
            (bool ok,) = address(usdc).call(
                abi.encodeCall(IERC20.transfer, (user, reward))
            );
            if (!ok) {
                rewards[user] = reward;
            }
        }
    }

    /// @notice Claim accrued USDC rewards to an alternate address.
    function claimRewardTo(address to) external nonReentrant updateReward(msg.sender) {
        require(to != address(0), "sDIEMv2: zero to");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit RewardPaid(msg.sender, reward);
            usdc.safeTransfer(to, reward);
        }
    }

    // ── Permissionless — Venice management ──────────────────────────────

    function claimFromVenice() external override nonReentrant {
        (,, uint256 pending) = diemStaking.stakedInfos(address(this));
        require(pending > 0, "sDIEMv2: nothing pending on Venice");

        uint256 balBefore = diem.balanceOf(address(this));
        diemStaking.unstake();
        uint256 received = diem.balanceOf(address(this)) - balBefore;

        emit VeniceClaimed(msg.sender, received);
    }

    function initiateVeniceUnstake() external override nonReentrant {
        require(totalPendingNotInitiated() > 0, "sDIEMv2: nothing to initiate");
        _tryInitiateVeniceUnstake();
    }

    /**
     * @dev Internal: initiate Venice unstake for whatever pending withdrawal
     *      is not already covered by liquid DIEM or matured-but-unclaimed
     *      Venice pending.
     *      - If matured pending exists, claims it first (M-01). After the
     *        claim, recompute the deficit since the matured DIEM now sits
     *        as liquid and may already cover the outstanding withdrawals.
     *      - If cooldown is active, silently returns (auto-call safety).
     */
    function _tryInitiateVeniceUnstake() internal {
        uint256 needed = totalPendingNotInitiated();
        if (needed == 0) return;

        (, uint256 cooldownEnd, uint256 pending) = diemStaking.stakedInfos(address(this));

        if (pending > 0) {
            if (block.timestamp >= cooldownEnd) {
                // M-01: claim matured cooldown before initiating a new one.
                diemStaking.unstake();
                // Recompute deficit — the just-matured DIEM is now liquid.
                needed = totalPendingNotInitiated();
                if (needed == 0) return;
            } else {
                return;
            }
        }

        emit VeniceUnstakeInitiated(msg.sender, needed);
        diemStaking.initiateUnstake(needed);
    }

    function redeployExcess() external override nonReentrant {
        uint256 liquid = diem.balanceOf(address(this));
        require(liquid > totalPendingWithdrawals, "sDIEMv2: no excess to redeploy");

        uint256 excess = liquid - totalPendingWithdrawals;
        emit ExcessRedeployed(msg.sender, excess);

        diemStaking.stake(excess);
    }

    // ── Operator — reward notification ──────────────────────────────────

    /**
     * @notice Seed a new 24h reward period. Pulls USDC from caller.
     * @dev L-01 preserved: returns rounding dust to caller, capped at `reward`
     *      so leftover from a previous period is never refunded.
     */
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyOperator
        updateReward(address(0))
    {
        require(reward > 0, "sDIEMv2: zero reward");

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
        require(rewardRate > 0, "sDIEMv2: reward rate zero");

        uint256 balance = usdc.balanceOf(address(this));
        require(rewardRate <= balance / REWARDS_DURATION, "sDIEMv2: reward too high");

        // L-01 dust refund
        uint256 distributable = rewardRate * REWARDS_DURATION;
        uint256 dust = total - distributable;
        uint256 refund = dust > reward ? reward : dust;
        if (refund > 0) {
            usdc.safeTransfer(msg.sender, refund);
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
        require(newOperator != address(0), "sDIEMv2: zero operator");
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorChanged(oldOperator, newOperator);
    }

    function transferAdmin(address newAdmin) external override onlyAdmin {
        require(newAdmin != address(0), "sDIEMv2: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "sDIEMv2: not pending admin");
        address oldAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(oldAdmin, msg.sender);
    }

    function recoverERC20(address token, address to, uint256 amount) external override onlyAdmin {
        require(token != address(diem), "sDIEMv2: cannot recover DIEM");
        require(token != address(usdc), "sDIEMv2: cannot recover USDC");
        require(to != address(0), "sDIEMv2: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    // ── EIP-1271 — Venice authentication ────────────────────────────────

    bytes4 private constant _EIP1271_MAGIC = bytes4(0x1626ba7e);
    bytes4 private constant _EIP1271_FAIL = bytes4(0xffffffff);

    /**
     * @notice Validates a signature on behalf of this contract for Venice.
     * @dev Supports EOA admin (ECDSA recover) and contract admin (Safe etc.)
     *      via nested EIP-1271. Rotating admin updates who can sign.
     */
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        if (admin.code.length > 0) {
            try IERC1271(admin).isValidSignature(hash, signature) returns (bytes4 result) {
                return result;
            } catch {
                return _EIP1271_FAIL;
            }
        }

        address recovered = ECDSA.recover(hash, signature);
        if (recovered == admin) {
            return _EIP1271_MAGIC;
        }
        return _EIP1271_FAIL;
    }
}
