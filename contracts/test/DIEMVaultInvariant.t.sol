// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DIEMVault} from "../src/DIEMVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title DIEMVaultInvariant
 * @notice Invariant tests for the DIEM Vault.
 *
 * Invariants tested:
 *   1. USDC balance of vault == totalDeposits + protocolFees
 *   2. Sum of all borrowerBalance[i] == totalDeposits
 *   3. totalDeposits never decreases (no withdrawal in Phase 1)
 */
contract VaultHandler is Test {
    DIEMVault public vault;
    MockERC20 public usdc;

    // Ghost variables for tracking invariants
    address[] public depositors;
    mapping(address => bool) public isDepositor;
    uint256 public previousTotalDeposits;

    constructor(DIEMVault _vault, MockERC20 _usdc) {
        vault = _vault;
        usdc = _usdc;
    }

    /// @notice Simulate a deposit from a bounded set of actors.
    function deposit(uint256 actorSeed, uint256 amount) external {
        // Pick an actor deterministically
        address actor = _getActor(actorSeed);

        // Bound amount to something valid
        uint256 minDep = vault.minDeposit();
        if (minDep == 0) minDep = 1;
        amount = bound(amount, minDep, 10_000e6);

        // Ensure actor has enough tokens
        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        // Track depositor
        if (!isDepositor[actor]) {
            depositors.push(actor);
            isDepositor[actor] = true;
        }

        previousTotalDeposits = vault.totalDeposits();
    }

    /// @notice Return all depositors (for invariant checks).
    function getDepositors() external view returns (address[] memory) {
        return depositors;
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function _getActor(uint256 seed) internal pure returns (address) {
        // 10 possible actors
        uint256 idx = seed % 10;
        return address(uint160(uint256(keccak256(abi.encodePacked("actor", idx)))));
    }
}

contract DIEMVaultInvariantTest is Test {
    DIEMVault public vault;
    MockERC20 public usdc;
    VaultHandler public handler;

    address public admin = makeAddr("admin");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new DIEMVault(address(usdc), admin);
        handler = new VaultHandler(vault, usdc);

        // Target only the handler for invariant calls
        targetContract(address(handler));
    }

    /// @notice Invariant: USDC balance of vault == totalDeposits + protocolFees
    function invariant_vaultBalanceMatchesAccounting() public view {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        uint256 expectedBalance = vault.totalDeposits() + vault.protocolFees();
        assertEq(vaultBalance, expectedBalance, "Vault balance != totalDeposits + protocolFees");
    }

    /// @notice Invariant: Sum of all borrower balances == totalDeposits
    function invariant_borrowerBalancesSumToTotalDeposits() public view {
        address[] memory depositors = handler.getDepositors();
        uint256 sumBalances = 0;

        for (uint256 i = 0; i < depositors.length; i++) {
            sumBalances += vault.borrowerBalance(depositors[i]);
        }

        assertEq(sumBalances, vault.totalDeposits(), "Sum of borrower balances != totalDeposits");
    }

    /// @notice Invariant: totalDeposits never decreases (Phase 1 — no withdrawals)
    function invariant_totalDepositsNeverDecreases() public view {
        assertGe(
            vault.totalDeposits(),
            handler.previousTotalDeposits(),
            "totalDeposits decreased"
        );
    }

    /// @notice Invariant: protocolFees is always 0 in Phase 1 (no fee accrual mechanism)
    function invariant_protocolFeesZeroInPhaseOne() public view {
        assertEq(vault.protocolFees(), 0, "Protocol fees should be 0 in Phase 1");
    }
}
