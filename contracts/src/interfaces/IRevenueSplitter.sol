// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsDIEM} from "./IsDIEM.sol";

/**
 * @title IRevenueSplitter
 * @notice Receives USDC revenue from cheaptokens.ai customers and distributes
 *         a configurable platform cut to a platform Safe and the remainder to
 *         sDIEM stakers via notifyRewardAmount. Permissionless trigger with
 *         cooldown. The platform cut is admin-settable but hard-capped at 20%
 *         (MAX_PLATFORM_BPS) so the platform can never exceed that share.
 */
interface IRevenueSplitter {
    // Events
    event Distributed(
        address indexed caller,
        uint256 platformCut,
        uint256 stakerCut,
        uint256 timestamp
    );
    event PlatformBpsSet(uint256 newPlatformBps);
    event PlatformReceiverSet(address indexed newReceiver);
    event MinAmountSet(uint256 newMinAmount);
    event CooldownSet(uint256 newCooldown);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event AdminTransferStarted(address indexed pendingAdmin);
    event AdminTransferAccepted(address indexed newAdmin);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // Views
    function USDC() external view returns (IERC20);
    function sdiem() external view returns (IsDIEM);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function platformReceiver() external view returns (address);
    function platformBps() external view returns (uint256);
    function minAmount() external view returns (uint256);
    function cooldown() external view returns (uint256);
    function lastDistribution() external view returns (uint256);
    function paused() external view returns (bool);
    function totalPlatformPaid() external view returns (uint256);
    function totalStakerPaid() external view returns (uint256);

    // Core
    function distribute() external;

    // Admin
    function setPlatformBps(uint256 newPlatformBps) external;
    function setPlatformReceiver(address newReceiver) external;
    function setMinAmount(uint256 newMinAmount) external;
    function setCooldown(uint256 newCooldown) external;
    function pause() external;
    function unpause() external;
    function rescueToken(address token, address to, uint256 amount) external;
    function transferAdmin(address newAdmin) external;
    function acceptAdmin() external;
}
