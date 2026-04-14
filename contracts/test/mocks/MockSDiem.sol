// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Minimal sDIEM mock that matches IsDIEM.notifyRewardAmount behavior:
 * pulls USDC from msg.sender via safeTransferFrom, only operator can call.
 */
contract MockSDiem {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public operator;
    uint256 public totalNotified;
    uint256 public rewardRate;
    uint256 public periodFinish;

    uint256 public constant REWARDS_DURATION = 1 days;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
        operator = msg.sender;
    }

    function setOperator(address _op) external {
        operator = _op;
    }

    function notifyRewardAmount(uint256 reward) external {
        require(msg.sender == operator, "MockSDiem: not operator");
        usdc.safeTransferFrom(msg.sender, address(this), reward);
        totalNotified += reward;
        rewardRate = reward / REWARDS_DURATION;
        periodFinish = block.timestamp + REWARDS_DURATION;
    }
}
