// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DIEMVault} from "../src/DIEMVault.sol";
import {IDIEMVault} from "../src/interfaces/IDIEMVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DIEMVaultTest is Test {
    DIEMVault public vault;
    MockERC20 public usdc;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant MIN_DEPOSIT = 10e6; // 10 USDC
    uint256 public constant INITIAL_BALANCE = 100_000e6; // 100k USDC
    uint256 public constant DEFAULT_FEE_BPS = 2000; // 20%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new DIEMVault(address(usdc), admin);

        // Fund test accounts
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /// @dev Compute net deposit after 20% fee.
    function _netOf(uint256 amount) internal pure returns (uint256) {
        uint256 fee = (amount * DEFAULT_FEE_BPS) / BPS_DENOMINATOR;
        return amount - fee;
    }

    /// @dev Compute fee for a given amount.
    function _feeOf(uint256 amount) internal pure returns (uint256) {
        return (amount * DEFAULT_FEE_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @dev Directly set `protocolFees` storage slot for testing fee
     *      withdrawal.
     *
     *      Storage layout of DIEMVault (OZ v5 ReentrancyGuard uses transient storage):
     *        slot 0: admin (address, 20 bytes) + paused (bool, 1 byte) — packed
     *        slot 1: minDeposit (uint256)
     *        slot 2: feeBps (uint256)
     *        slot 3: totalDeposits (uint256)
     *        slot 4: protocolFees (uint256)
     *        slot 5: borrowerBalance mapping
     */
    function _setProtocolFees(uint256 amount) internal {
        vm.store(address(vault), bytes32(uint256(4)), bytes32(amount));
    }

    // ── Constructor ─────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.depositToken()), address(usdc));
        assertEq(vault.admin(), admin);
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
        assertEq(vault.feeBps(), DEFAULT_FEE_BPS);
        assertFalse(vault.paused());
        assertEq(vault.totalDeposits(), 0);
        assertEq(vault.protocolFees(), 0);
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("DIEMVault: zero token");
        new DIEMVault(address(0), admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("DIEMVault: zero admin");
        new DIEMVault(address(usdc), address(0));
    }

    // ── Deposit: basic ──────────────────────────────────────────────────

    function test_deposit_basic() public {
        uint256 amount = 50e6; // 50 USDC
        uint256 net = _netOf(amount); // 40 USDC
        uint256 fee = _feeOf(amount); // 10 USDC

        vm.prank(alice);
        vault.deposit(amount);

        assertEq(vault.borrowerBalance(alice), net);
        assertEq(vault.totalDeposits(), net);
        assertEq(vault.protocolFees(), fee);
        assertEq(usdc.balanceOf(address(vault)), amount); // full amount transferred
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - amount);
    }

    function test_deposit_multipleDeposits() public {
        vm.prank(alice);
        vault.deposit(20e6);

        vm.prank(alice);
        vault.deposit(30e6);

        assertEq(vault.borrowerBalance(alice), _netOf(20e6) + _netOf(30e6));
        assertEq(vault.totalDeposits(), _netOf(20e6) + _netOf(30e6));
        assertEq(vault.protocolFees(), _feeOf(20e6) + _feeOf(30e6));
    }

    function test_deposit_multipleDepositors() public {
        vm.prank(alice);
        vault.deposit(100e6);

        vm.prank(bob);
        vault.deposit(200e6);

        assertEq(vault.borrowerBalance(alice), _netOf(100e6));
        assertEq(vault.borrowerBalance(bob), _netOf(200e6));
        assertEq(vault.totalDeposits(), _netOf(100e6) + _netOf(200e6));
        assertEq(vault.protocolFees(), _feeOf(100e6) + _feeOf(200e6));
        assertEq(usdc.balanceOf(address(vault)), 300e6); // full amounts transferred
    }

    function test_deposit_emitsEvent() public {
        uint256 amount = 50e6;
        uint256 net = _netOf(amount);
        uint256 fee = _feeOf(amount);

        vm.expectEmit(true, false, false, true);
        emit IDIEMVault.Deposited(alice, net, fee, net);

        vm.prank(alice);
        vault.deposit(amount);
    }

    function test_deposit_revertsBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: below min deposit");
        vault.deposit(MIN_DEPOSIT - 1);
    }

    function test_deposit_revertsExactlyZero() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: below min deposit");
        vault.deposit(0);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert("DIEMVault: paused");
        vault.deposit(50e6);
    }

    function test_deposit_revertsInsufficientBalance() public {
        address charlie = makeAddr("charlie");
        usdc.mint(charlie, 5e6); // Only 5 USDC, below min

        vm.startPrank(charlie);
        usdc.approve(address(vault), type(uint256).max);

        // Charlie has 5 USDC but min deposit is 10 — will revert below min
        vm.expectRevert("DIEMVault: below min deposit");
        vault.deposit(5e6);
        vm.stopPrank();
    }

    function test_deposit_revertsNoApproval() public {
        address charlie = makeAddr("charlie");
        usdc.mint(charlie, 50e6);
        // No approval given

        vm.prank(charlie);
        vm.expectRevert(); // ERC20 will revert on transferFrom
        vault.deposit(50e6);
    }

    function test_deposit_atExactMinimum() public {
        vm.prank(alice);
        vault.deposit(MIN_DEPOSIT);

        assertEq(vault.borrowerBalance(alice), _netOf(MIN_DEPOSIT));
        assertEq(vault.totalDeposits(), _netOf(MIN_DEPOSIT));
    }

    // ── Fee mechanism ─────────────────────────────────────────────────

    function test_deposit_feeAccrual() public {
        uint256 amount = 100e6; // 100 USDC

        vm.prank(alice);
        vault.deposit(amount);

        // 20% fee → 20 USDC fee, 80 USDC net
        assertEq(vault.protocolFees(), 20e6);
        assertEq(vault.borrowerBalance(alice), 80e6);
        assertEq(vault.totalDeposits(), 80e6);

        // Vault holds full 100 USDC (80 deposits + 20 fees)
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_deposit_zeroFeeWhenBpsZero() public {
        // Admin sets fee to 0
        vm.prank(admin);
        vault.setFeeBps(0);

        uint256 amount = 50e6;
        vm.prank(alice);
        vault.deposit(amount);

        assertEq(vault.borrowerBalance(alice), amount); // no fee
        assertEq(vault.totalDeposits(), amount);
        assertEq(vault.protocolFees(), 0);
    }

    function test_setFeeBps_basic() public {
        vm.prank(admin);
        vault.setFeeBps(1000); // 10%

        assertEq(vault.feeBps(), 1000);
    }

    function test_setFeeBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IDIEMVault.FeeBpsChanged(DEFAULT_FEE_BPS, 1000);

        vm.prank(admin);
        vault.setFeeBps(1000);
    }

    function test_setFeeBps_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.setFeeBps(1000);
    }

    function test_setFeeBps_revertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert("DIEMVault: fee exceeds max");
        vault.setFeeBps(5001); // MAX_FEE_BPS = 5000
    }

    function test_setFeeBps_atMax() public {
        vm.prank(admin);
        vault.setFeeBps(5000); // exactly MAX_FEE_BPS
        assertEq(vault.feeBps(), 5000);
    }

    function test_setFeeBps_canSetToZero() public {
        vm.prank(admin);
        vault.setFeeBps(0);
        assertEq(vault.feeBps(), 0);
    }

    function test_deposit_usesUpdatedFee() public {
        // Change fee from 20% to 10%
        vm.prank(admin);
        vault.setFeeBps(1000);

        uint256 amount = 100e6;
        vm.prank(alice);
        vault.deposit(amount);

        // 10% fee → 10 USDC fee, 90 USDC net
        assertEq(vault.protocolFees(), 10e6);
        assertEq(vault.borrowerBalance(alice), 90e6);
    }

    // ── Protocol fee withdrawal ─────────────────────────────────────────

    function test_withdrawProtocolFees_basic() public {
        // Deposit to accrue real fees
        vm.prank(alice);
        vault.deposit(100e6); // 20 USDC fee

        address treasury = makeAddr("treasury");

        vm.prank(admin);
        vault.withdrawProtocolFees(treasury, 10e6);

        assertEq(vault.protocolFees(), 10e6);
        assertEq(usdc.balanceOf(treasury), 10e6);
    }

    function test_withdrawProtocolFees_emitsEvent() public {
        _setProtocolFees(100e6);
        usdc.mint(address(vault), 100e6);

        address treasury = makeAddr("treasury");

        vm.expectEmit(true, false, false, true);
        emit IDIEMVault.ProtocolFeesWithdrawn(treasury, 100e6);

        vm.prank(admin);
        vault.withdrawProtocolFees(treasury, 100e6);
    }

    function test_withdrawProtocolFees_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.withdrawProtocolFees(alice, 1);
    }

    function test_withdrawProtocolFees_revertsZeroAddress() public {
        _setProtocolFees(100e6);

        vm.prank(admin);
        vm.expectRevert("DIEMVault: zero address");
        vault.withdrawProtocolFees(address(0), 50e6);
    }

    function test_withdrawProtocolFees_revertsZeroAmount() public {
        _setProtocolFees(100e6);

        vm.prank(admin);
        vm.expectRevert("DIEMVault: zero amount");
        vault.withdrawProtocolFees(admin, 0);
    }

    function test_withdrawProtocolFees_revertsExceedsFees() public {
        _setProtocolFees(100e6);

        vm.prank(admin);
        vm.expectRevert("DIEMVault: exceeds fees");
        vault.withdrawProtocolFees(admin, 101e6);
    }

    // ── Admin: pause/unpause ────────────────────────────────────────────

    function test_pause_basic() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IDIEMVault.Paused(admin);

        vm.prank(admin);
        vault.pause();
    }

    function test_pause_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.pause();
    }

    function test_unpause_basic() public {
        vm.startPrank(admin);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    function test_unpause_emitsEvent() public {
        vm.prank(admin);
        vault.pause();

        vm.expectEmit(true, false, false, false);
        emit IDIEMVault.Unpaused(admin);

        vm.prank(admin);
        vault.unpause();
    }

    function test_unpause_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.unpause();
    }

    function test_depositWorksAfterUnpause() public {
        vm.startPrank(admin);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        uint256 amount = 50e6;
        vm.prank(alice);
        vault.deposit(amount);
        assertEq(vault.borrowerBalance(alice), _netOf(amount));
    }

    // ── Admin: setMinDeposit ────────────────────────────────────────────

    function test_setMinDeposit_basic() public {
        vm.prank(admin);
        vault.setMinDeposit(100e6);
        assertEq(vault.minDeposit(), 100e6);
    }

    function test_setMinDeposit_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IDIEMVault.MinDepositChanged(MIN_DEPOSIT, 100e6);

        vm.prank(admin);
        vault.setMinDeposit(100e6);
    }

    function test_setMinDeposit_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.setMinDeposit(100e6);
    }

    function test_setMinDeposit_canSetToZero() public {
        vm.prank(admin);
        vault.setMinDeposit(0);
        assertEq(vault.minDeposit(), 0);
    }

    // ── Admin: setAdmin ─────────────────────────────────────────────────

    function test_setAdmin_basic() public {
        vm.prank(admin);
        vault.setAdmin(alice);
        assertEq(vault.admin(), alice);
    }

    function test_setAdmin_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IDIEMVault.AdminChanged(admin, alice);

        vm.prank(admin);
        vault.setAdmin(alice);
    }

    function test_setAdmin_revertsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert("DIEMVault: not admin");
        vault.setAdmin(alice);
    }

    function test_setAdmin_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("DIEMVault: zero admin");
        vault.setAdmin(address(0));
    }

    function test_setAdmin_oldAdminLosesAccess() public {
        vm.prank(admin);
        vault.setAdmin(alice);

        vm.prank(admin);
        vm.expectRevert("DIEMVault: not admin");
        vault.pause();
    }

    function test_setAdmin_newAdminHasAccess() public {
        vm.prank(admin);
        vault.setAdmin(alice);

        vm.prank(alice);
        vault.pause();
        assertTrue(vault.paused());
    }

    // ── Fuzz tests ──────────────────────────────────────────────────────

    function testFuzz_deposit_anyValidAmount(uint256 amount) public {
        // Bound between min deposit and initial balance
        amount = bound(amount, MIN_DEPOSIT, INITIAL_BALANCE);

        uint256 fee = (amount * DEFAULT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = amount - fee;

        vm.prank(alice);
        vault.deposit(amount);

        assertEq(vault.borrowerBalance(alice), net);
        assertEq(vault.totalDeposits(), net);
        assertEq(vault.protocolFees(), fee);
        assertEq(usdc.balanceOf(address(vault)), amount);
    }

    function testFuzz_deposit_multipleDepositors(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, MIN_DEPOSIT, INITIAL_BALANCE);
        amountB = bound(amountB, MIN_DEPOSIT, INITIAL_BALANCE);

        uint256 feeA = (amountA * DEFAULT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 feeB = (amountB * DEFAULT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netA = amountA - feeA;
        uint256 netB = amountB - feeB;

        vm.prank(alice);
        vault.deposit(amountA);

        vm.prank(bob);
        vault.deposit(amountB);

        assertEq(vault.borrowerBalance(alice), netA);
        assertEq(vault.borrowerBalance(bob), netB);
        assertEq(vault.totalDeposits(), netA + netB);
        assertEq(vault.protocolFees(), feeA + feeB);
        assertEq(usdc.balanceOf(address(vault)), amountA + amountB);
    }

    function testFuzz_setMinDeposit(uint256 newMin) public {
        vm.prank(admin);
        vault.setMinDeposit(newMin);
        assertEq(vault.minDeposit(), newMin);
    }

    function testFuzz_setFeeBps(uint256 newBps) public {
        newBps = bound(newBps, 0, 5000); // MAX_FEE_BPS

        vm.prank(admin);
        vault.setFeeBps(newBps);
        assertEq(vault.feeBps(), newBps);
    }

    function testFuzz_withdrawProtocolFees(uint256 fees, uint256 withdrawAmount) public {
        fees = bound(fees, 1, 1_000_000e6);
        withdrawAmount = bound(withdrawAmount, 1, fees);

        _setProtocolFees(fees);
        usdc.mint(address(vault), fees);

        address treasury = makeAddr("treasury");

        vm.prank(admin);
        vault.withdrawProtocolFees(treasury, withdrawAmount);

        assertEq(vault.protocolFees(), fees - withdrawAmount);
        assertEq(usdc.balanceOf(treasury), withdrawAmount);
    }

    // ── Invariant: vault solvency ────────────────────────────────────────

    function test_invariant_vaultSolvency() public {
        // After deposits, vault balance == totalDeposits + protocolFees
        vm.prank(alice);
        vault.deposit(100e6);

        vm.prank(bob);
        vault.deposit(200e6);

        assertEq(
            usdc.balanceOf(address(vault)),
            vault.totalDeposits() + vault.protocolFees(),
            "Vault solvency: balance == totalDeposits + protocolFees"
        );
    }
}
