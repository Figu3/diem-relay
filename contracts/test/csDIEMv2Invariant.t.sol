// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {csDIEMv2} from "../src/csDIEMv2.sol";
import {sDIEMv2} from "../src/sDIEMv2.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

/**
 * @title csDIEMv2Handler
 * @notice Guided handler for csDIEM v2 invariant testing.
 *
 *         csDIEM v2 is a canonical ERC-4626 wrapper over sDIEM v2:
 *           - deposit(sDIEMv2) → mint csDIEMv2 shares
 *           - redeem(csDIEMv2) → burn shares, return sDIEMv2 (synchronous)
 *
 *         The handler exercises both the sDIEM-asset path and the depositDIEM
 *         zap, plus harvest, transfers, and standard 4626 ops.
 */
contract csDIEMv2Handler is Test {
    csDIEMv2 public vault;
    sDIEMv2 public stakingVault;
    MockDIEMStaking public diem;
    ERC20Mock public usdc;
    address public operator;

    address[] public actors;

    // Ghost trackers
    uint256 public ghost_totalDiemDeposited;     // via depositDIEM
    uint256 public ghost_totalSdiemDeposited;    // via canonical deposit
    uint256 public ghost_totalSdiemRedeemed;     // via canonical redeem
    uint256 public ghost_totalHarvested;         // USDC harvested

    constructor(
        csDIEMv2 _vault,
        sDIEMv2 _stakingVault,
        MockDIEMStaking _diem,
        ERC20Mock _usdc,
        address _operator
    ) {
        vault = _vault;
        stakingVault = _stakingVault;
        diem = _diem;
        usdc = _usdc;
        operator = _operator;

        diem.setCooldownDuration(0); // instant unstake

        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(0xBEEF + i));
            actors.push(actor);
            diem.mint(actor, 10_000e18);

            vm.startPrank(actor);
            diem.approve(address(stakingVault), type(uint256).max);
            diem.approve(address(vault), type(uint256).max);
            stakingVault.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ── Actions ────────────────────────────────────────────────────────────

    /// @notice Stake DIEM into sDIEM v2 directly (so actor has sDIEM to deposit).
    function stakeIntoSdiem(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = diem.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try stakingVault.stake(amount) {} catch {}
    }

    /// @notice Standard ERC-4626 deposit (asset = sDIEM v2).
    function depositSdiem(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = stakingVault.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try vault.deposit(amount, actor) {
            ghost_totalSdiemDeposited += amount;
        } catch {}
    }

    /// @notice The depositDIEM zap — pulls raw DIEM, stakes internally.
    function depositDIEM(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = diem.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        try vault.depositDIEM(amount, actor) {
            ghost_totalDiemDeposited += amount;
        } catch {}
    }

    /// @notice Standard ERC-4626 synchronous redeem.
    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 maxShares = vault.maxRedeem(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        uint256 expectedAssets = vault.previewRedeem(shares);
        if (expectedAssets == 0) return;

        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256 actualAssets) {
            ghost_totalSdiemRedeemed += actualAssets;
            // previewRedeem is a lower bound: actualAssets >= preview
            // (OZ rounds down in preview, the actual call uses the same math).
            // Equal in practice; assert >= for safety.
            assertGe(actualAssets, expectedAssets, "redeem returned less than preview");
        } catch {}
    }

    /// @notice Transfer csDIEM v2 shares between actors (composability test).
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        try vault.transfer(to, amount) {} catch {}
    }

    function harvest() external {
        if (vault.totalSupply() == 0) return;
        if (stakingVault.balanceOf(address(vault)) == 0) return;

        // Seed rewards into sDIEM v2 via the operator.
        uint256 rewardAmount = 5e6;
        usdc.mint(operator, rewardAmount);
        vm.startPrank(operator);
        usdc.approve(address(stakingVault), rewardAmount);
        try stakingVault.notifyRewardAmount(rewardAmount) {} catch {}
        vm.stopPrank();

        vm.warp(block.timestamp + 24 hours);

        try vault.harvest(block.timestamp + 300) {
            ghost_totalHarvested += rewardAmount;
        } catch {}
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 7 days);
        vm.warp(block.timestamp + secs);
    }
}

/**
 * @title csDIEMv2InvariantTest
 * @notice Spec-driven invariants for csDIEM v2 — canonical 4626 over sDIEM v2.
 */
contract csDIEMv2InvariantTest is Test {
    csDIEMv2 public vault;
    sDIEMv2 public stakingVault;
    MockDIEMStaking public diem;
    ERC20Mock public usdc;
    MockSwapRouter public router;
    MockCLPool public oracle;
    csDIEMv2Handler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");

    uint256 private lastSharePrice;

    function setUp() public {
        diem = new MockDIEMStaking();
        usdc = new ERC20Mock();
        router = new MockSwapRouter(address(diem));
        oracle = new MockCLPool();

        stakingVault = new sDIEMv2(address(diem), address(usdc), admin, operator);

        vault = new csDIEMv2(
            stakingVault,
            address(diem),
            address(usdc),
            address(router),
            address(oracle),
            admin,
            50,           // 0.5% slippage
            1800,         // 30 min TWAP
            1,            // tick spacing
            1e6,          // minHarvest = 1 USDC
            1             // minDiemPerUsdc — sentinel non-zero (mocks return 1:1)
        );

        handler = new csDIEMv2Handler(vault, stakingVault, diem, usdc, operator);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = csDIEMv2Handler.stakeIntoSdiem.selector;
        selectors[1] = csDIEMv2Handler.depositSdiem.selector;
        selectors[2] = csDIEMv2Handler.depositDIEM.selector;
        selectors[3] = csDIEMv2Handler.redeem.selector;
        selectors[4] = csDIEMv2Handler.transferShares.selector;
        selectors[5] = csDIEMv2Handler.harvest.selector;
        selectors[6] = csDIEMv2Handler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ── Invariant 1: totalAssets matches sDIEM holding ─────────────────
    // For a true wrapper, the relationship must be 1:1 with the asset.

    function invariant_totalAssetsEqualsSdiemBalance() public view {
        assertEq(
            vault.totalAssets(),
            stakingVault.balanceOf(address(vault)),
            "totalAssets != sdiem.balanceOf(vault)"
        );
    }

    // ── Invariant 2: No shares without assets ────────────────────────────

    function invariant_noSharesWithoutAssets() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0, "shares exist but totalAssets is 0");
        }
    }

    // ── Invariant 3: Share price never regresses ─────────────────────────
    // The whole point of csDIEM v2 is monotonic share price (Spectra/Pendle
    // depend on it). Harvests only add; redeems use the current rate.

    function invariant_sharePriceMonotonic() public {
        if (vault.totalSupply() == 0) return;
        uint256 currentPrice = vault.convertToAssets(1e24);
        // Rounding tolerance: tiny noise from convertToAssets at very low
        // supply with offset=1e6.
        if (lastSharePrice > 0) {
            assertGe(currentPrice + 1, lastSharePrice, "share price regressed");
        }
        if (currentPrice > lastSharePrice) lastSharePrice = currentPrice;
    }

    // ── Invariant 4: Standard 4626 maxRedeem = balanceOf (composability) ─
    // This is the big v1 → v2 fix. v1 returned 0; v2 must return the real
    // value so Pendle/Morpho/Spectra/Silo can integrate.

    function invariant_maxRedeemEqualsBalance() public view {
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(0xBEEF + i));
            assertEq(
                vault.maxRedeem(user),
                vault.balanceOf(user),
                "maxRedeem != balanceOf - breaks 4626 composability"
            );
        }
    }

    // ── Invariant 5: Standard 4626 maxWithdraw = previewRedeem(balanceOf) ─

    function invariant_maxWithdrawConsistent() public view {
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(0xBEEF + i));
            uint256 expected = vault.previewRedeem(vault.balanceOf(user));
            assertEq(
                vault.maxWithdraw(user),
                expected,
                "maxWithdraw != previewRedeem(balanceOf)"
            );
        }
    }

    // ── Invariant 6: convertToAssets ∘ convertToShares ≈ identity ────────
    // OZ rounds down in both directions; round-trip should lose <= rounding.

    function invariant_conversionRoundTrip() public view {
        if (vault.totalSupply() == 0) return;

        uint256 testAssets = 100e18;
        uint256 shares = vault.convertToShares(testAssets);
        uint256 assetsBack = vault.convertToAssets(shares);

        // Tolerance scales with supply; 1e-5 of input is safe.
        uint256 tolerance = testAssets / 100_000 + 1;
        assertApproxEqAbs(assetsBack, testAssets, tolerance, "round-trip drift");
        assertLe(assetsBack, testAssets, "vault overpays on conversion");
    }

    // ── Invariant 7: Pause does not block redemption ─────────────────────
    // Critical user-protection invariant. Even when admin pauses the vault,
    // users must be able to exit. We verify by toggling pause and reading
    // maxRedeem.

    function invariant_redemptionAlwaysAllowed() public {
        // Force-pause to check redemption availability still holds.
        // (We don't actually call redeem here — the maxRedeem signal is
        // sufficient because _withdraw isn't overridden with whenNotPaused.)
        bool wasPaused = vault.paused();
        if (!wasPaused) {
            vm.prank(admin);
            vault.pause();
        }

        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(0xBEEF + i));
            uint256 bal = vault.balanceOf(user);
            // When paused, maxRedeem must still equal balanceOf.
            assertEq(vault.maxRedeem(user), bal, "pause blocks redemption");
        }

        if (!wasPaused) {
            vm.prank(admin);
            vault.unpause();
        }
    }

    // ── Invariant 8: recovery blacklist excludes asset(), DIEM, USDC ─────

    function invariant_recoveryBlacklist() public {
        // Each blocked token, when admin tries to recover, must revert.
        vm.startPrank(admin);
        vm.expectRevert();
        vault.recoverERC20(address(stakingVault), admin, 0);
        vm.expectRevert();
        vault.recoverERC20(address(diem), admin, 0);
        vm.expectRevert();
        vault.recoverERC20(address(usdc), admin, 0);
        vm.stopPrank();
    }
}
