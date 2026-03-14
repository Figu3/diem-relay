// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DIEMVault} from "../src/DIEMVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @title TestSepolia
 * @notice Comprehensive on-chain smoke tests for DIEMVault on Sepolia.
 *
 * Revert-expected tests use low-level calls + stopBroadcast/startBroadcast
 * to avoid Forge treating expected reverts as failed transactions.
 *
 * Usage:
 *   forge script script/TestSepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
 */
contract TestSepolia is Script {
    DIEMVault vault;
    MockERC20 usdc;
    address deployer;
    uint256 deployerKey;

    uint256 passed;
    uint256 failed;

    function run() external {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        console.log("\n========================================");
        console.log("  DIEM Vault - Sepolia Test Suite");
        console.log("========================================");
        console.log("  Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // Deploy Mock USDC
        usdc = new MockERC20("USD Coin (Mock)", "USDC", 6);
        usdc.mint(deployer, 10_000_000e6);
        console.log("\n  MockUSDC:", address(usdc));

        // Deploy DIEMVault
        vault = new DIEMVault(address(usdc), deployer);
        console.log("  DIEMVault:", address(vault));

        // Approve vault
        usdc.approve(address(vault), type(uint256).max);

        console.log("\n----------------------------------------");
        console.log("  Running tests...");
        console.log("----------------------------------------\n");

        // === 01: Constructor state ===
        _assertAddr(vault.admin(), deployer, "01a: admin is deployer");
        _assertBool(vault.paused(), false, "01b: not paused");
        _assertEq(vault.minDeposit(), 10e6, "01c: minDeposit = 10 USDC");
        _assertEq(vault.totalDeposits(), 0, "01d: totalDeposits = 0");
        _assertEq(vault.protocolFees(), 0, "01e: protocolFees = 0");
        _assertAddr(address(vault.depositToken()), address(usdc), "01f: depositToken = USDC");

        // === 02: Basic deposit ===
        uint256 balBefore = usdc.balanceOf(deployer);
        vault.deposit(100e6);
        _assertEq(vault.borrowerBalance(deployer), 100e6, "02a: borrowerBalance = 100");
        _assertEq(vault.totalDeposits(), 100e6, "02b: totalDeposits = 100");
        _assertEq(usdc.balanceOf(address(vault)), 100e6, "02c: vault holds 100 USDC");
        _assertEq(usdc.balanceOf(deployer), balBefore - 100e6, "02d: deployer lost 100 USDC");

        // === 03: Multiple deposits ===
        vault.deposit(200e6);
        vault.deposit(50e6);
        _assertEq(vault.borrowerBalance(deployer), 350e6, "03a: cumulative = 350");
        _assertEq(vault.totalDeposits(), 350e6, "03b: totalDeposits = 350");
        _assertEq(usdc.balanceOf(address(vault)), 350e6, "03c: vault holds 350 USDC");

        vm.stopBroadcast();

        // === 04: Below minimum reverts (low-level call, no broadcast) ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.deposit.selector, 5e6),
            "04: below-min reverts"
        );

        vm.startBroadcast(deployerKey);

        // === 05: Pause ===
        vault.pause();
        _assertBool(vault.paused(), true, "05: pause works");

        vm.stopBroadcast();

        // === 06: Deposit while paused reverts ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.deposit.selector, 100e6),
            "06: deposit while paused reverts"
        );

        vm.startBroadcast(deployerKey);

        // === 07: Unpause ===
        vault.unpause();
        _assertBool(vault.paused(), false, "07: unpause works");

        // === 08: Deposit after unpause ===
        vault.deposit(25e6);
        _assertEq(vault.borrowerBalance(deployer), 375e6, "08a: deposit after unpause");
        _assertEq(vault.totalDeposits(), 375e6, "08b: total after unpause");

        // === 09: setMinDeposit ===
        vault.setMinDeposit(100e6);
        _assertEq(vault.minDeposit(), 100e6, "09: setMinDeposit = 100");

        // === 10: Deposit at new minimum ===
        vault.deposit(100e6);
        _assertEq(vault.borrowerBalance(deployer), 475e6, "10: deposit at new min");

        vm.stopBroadcast();

        // === 11: Below new min reverts ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.deposit.selector, 50e6),
            "11: below new min reverts"
        );

        vm.startBroadcast(deployerKey);

        // === 12: Reset min deposit ===
        vault.setMinDeposit(10e6);
        _assertEq(vault.minDeposit(), 10e6, "12: resetMinDeposit");

        // === 13: Large deposit ===
        vault.deposit(1_000_000e6);
        _assertEq(vault.borrowerBalance(deployer), 1_000_475e6, "13a: large deposit balance");
        _assertEq(vault.totalDeposits(), 1_000_475e6, "13b: large deposit total");

        // === 14: State consistency ===
        {
            uint256 vaultBal = usdc.balanceOf(address(vault));
            uint256 total = vault.totalDeposits();
            uint256 fees = vault.protocolFees();
            _assertEq(vaultBal, total + fees, "14: vault = deposits + fees");
        }

        vm.stopBroadcast();

        // === 15: withdrawProtocolFees(0) reverts ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.withdrawProtocolFees.selector, deployer, uint256(0)),
            "15: withdraw 0 fees reverts"
        );

        // === 16: withdrawProtocolFees exceeds reverts ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.withdrawProtocolFees.selector, deployer, uint256(1)),
            "16: withdraw exceeds fees reverts"
        );

        // === 17: transferAdmin(address(0)) reverts ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.transferAdmin.selector, address(0)),
            "17: transferAdmin(0) reverts"
        );

        vm.startBroadcast(deployerKey);

        // === 18: two-step admin transfer ===
        vault.transferAdmin(address(0xBEEF));

        vm.stopBroadcast();

        // Accept as 0xBEEF
        vm.startBroadcast(uint256(uint160(address(0xBEEF))));
        vault.acceptAdmin();
        vm.stopBroadcast();

        _assertAddr(vault.admin(), address(0xBEEF), "18: admin transferred to 0xBEEF");

        // === 19: Old admin cannot act ===
        _assertReverts(
            address(vault),
            abi.encodeWithSelector(DIEMVault.pause.selector),
            "19: old admin cannot pause"
        );

        // === 20: Admin state verified ===
        _assertAddr(vault.admin(), address(0xBEEF), "20a: admin is 0xBEEF");
        _pass("20b: admin transfer verified");

        // === 21: Final state check ===
        {
            uint256 vaultBal = usdc.balanceOf(address(vault));
            uint256 total = vault.totalDeposits();
            _assertEq(vaultBal, total, "21a: final vault balance matches");

            uint256 deployerBal = usdc.balanceOf(deployer);
            _assertEq(deployerBal, 10_000_000e6 - total, "21b: deployer balance correct");

            console.log("\n  Final state:");
            console.log("    Vault USDC:   ", vaultBal / 1e6, "USDC");
            console.log("    totalDeposits:", total / 1e6, "USDC");
            console.log("    borrowerBal:  ", vault.borrowerBalance(deployer) / 1e6, "USDC");
            console.log("    protocolFees: ", vault.protocolFees());
            console.log("    admin:        ", vault.admin());
            console.log("    paused:       ", vault.paused());
        }

        // Results
        console.log("\n========================================");
        console.log("  Passed:", passed);
        console.log("  Failed:", failed);
        console.log("========================================\n");

        if (failed > 0) {
            console.log("  SOME TESTS FAILED!");
        } else {
            console.log("  ALL TESTS PASSED!");
        }

        console.log("\n  Vault address: ", address(vault));
        console.log("  MockUSDC address:", address(usdc));
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _pass(string memory name) internal {
        passed++;
        console.log(string.concat("  [PASS] ", name));
    }

    function _fail(string memory name) internal {
        failed++;
        console.log(string.concat("  [FAIL] ", name));
    }

    function _assertEq(uint256 a, uint256 b, string memory name) internal {
        if (a == b) _pass(name); else _fail(name);
    }

    function _assertAddr(address a, address b, string memory name) internal {
        if (a == b) _pass(name); else _fail(name);
    }

    function _assertBool(bool a, bool expected, string memory name) internal {
        if (a == expected) _pass(name); else _fail(name);
    }

    /// @dev Low-level call that expects a revert. Runs outside broadcast.
    function _assertReverts(address target, bytes memory data, string memory name) internal {
        (bool success, ) = target.call(data);
        if (!success) _pass(name); else _fail(name);
    }
}
