// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDIEMStaking} from "../../src/interfaces/IDIEMStaking.sol";

/**
 * @title MockDIEMStaking
 * @notice Mock of the DIEM token with built-in staking for testing.
 *
 * Simulates the real DIEM token's staking behavior:
 *   - stake() does internal balance transfer (no approval needed)
 *   - Two-step unstaking with configurable cooldown (default 24h)
 *   - stakedInfos() view for tracking
 *   - totalStaked() for aggregate tracking
 *
 * The real DIEM token on Base has staking built into the ERC-20 contract.
 * When stake() is called, tokens move from the caller's balanceOf into the
 * token contract's own balanceOf and are tracked in stakedInfos.
 */
contract MockDIEMStaking is ERC20, IDIEMStaking {
    struct StakeInfo {
        uint256 stakedAmount;
        uint256 cooldownEndTimestamp;
        uint256 pendingUnstakeAmount;
    }

    mapping(address => StakeInfo) private _stakeInfos;
    uint256 private _totalStaked;
    uint256 private _cooldownDuration = 24 hours;

    constructor() ERC20("DIEM", "DIEM") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Mint tokens for testing.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn tokens for testing.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    // ── IDIEMStaking implementation ─────────────────────────────────────

    /// @inheritdoc IDIEMStaking
    function stake(uint256 amount) external override {
        require(balanceOf(msg.sender) >= amount, "MockDIEM: insufficient balance");
        // Internal transfer: caller → this contract (no approval needed)
        _transfer(msg.sender, address(this), amount);
        _stakeInfos[msg.sender].stakedAmount += amount;
        _totalStaked += amount;
    }

    /// @inheritdoc IDIEMStaking
    function initiateUnstake(uint256 amount) external override {
        StakeInfo storage info = _stakeInfos[msg.sender];
        require(info.stakedAmount >= amount, "MockDIEM: insufficient staked");
        info.stakedAmount -= amount;
        info.pendingUnstakeAmount += amount; // Accumulates if called again
        info.cooldownEndTimestamp = block.timestamp + _cooldownDuration; // Resets timer
        _totalStaked -= amount;
    }

    /// @inheritdoc IDIEMStaking
    function unstake() external override {
        StakeInfo storage info = _stakeInfos[msg.sender];
        require(info.pendingUnstakeAmount > 0, "MockDIEM: nothing pending");
        require(block.timestamp >= info.cooldownEndTimestamp, "MockDIEM: cooldown active");

        uint256 amount = info.pendingUnstakeAmount;
        info.pendingUnstakeAmount = 0;
        info.cooldownEndTimestamp = 0;

        // Internal transfer: this contract → caller
        _transfer(address(this), msg.sender, amount);
    }

    /// @inheritdoc IDIEMStaking
    function cooldownDuration() external view override returns (uint256) {
        return _cooldownDuration;
    }

    /// @inheritdoc IDIEMStaking
    function stakedInfos(address account)
        external
        view
        override
        returns (uint256 stakedAmount, uint256 cooldownEndTimestamp, uint256 pendingUnstakeAmount)
    {
        StakeInfo storage info = _stakeInfos[account];
        return (info.stakedAmount, info.cooldownEndTimestamp, info.pendingUnstakeAmount);
    }

    /// @inheritdoc IDIEMStaking
    function totalStaked() external view override returns (uint256) {
        return _totalStaked;
    }

    /// @notice Explicit override to satisfy both ERC20 and IDIEMStaking.
    function balanceOf(address account) public view override(ERC20, IDIEMStaking) returns (uint256) {
        return super.balanceOf(account);
    }

    // ── Test helpers ────────────────────────────────────────────────────

    /// @notice Set cooldown duration for testing (e.g., 0 for instant unstake).
    function setCooldownDuration(uint256 duration) external {
        _cooldownDuration = duration;
    }
}
