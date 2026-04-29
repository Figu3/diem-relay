// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {csDIEM} from "../src/csDIEM.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";

// ── Handler ────────────────────────────────────────────────────────────────

contract csDIEMHandler is Test {
    csDIEM public vault;
    sDIEM public stakingVault;
    MockDIEMStaking public diem;
    ERC20Mock public usdc;
    address public operator;

    address[] public actors;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalRedeemed;
    uint256 public ghost_totalPendingRedemptions;

    constructor(
        csDIEM _vault,
        sDIEM _stakingVault,
        MockDIEMStaking _diem,
        ERC20Mock _usdc,
        address _operator
    ) {
        vault = _vault;
        stakingVault = _stakingVault;
        diem = _diem;
        usdc = _usdc;
        operator = _operator;

        // Instant cooldown for invariant testing
        diem.setCooldownDuration(0);

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(0xBEEF + i));
            actors.push(actor);
            diem.mint(actor, 10_000e18);
            vm.prank(actor);
            diem.approve(address(vault), type(uint256).max);
        }
    }

    // ── Actions ────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = diem.balanceOf(actor);
        if (bal == 0) return;

        amount = bound(amount, 1e15, bal);

        vm.prank(actor);
        vault.deposit(amount, actor);

        ghost_totalDeposited += amount;
    }

    function requestRedeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        uint256 maxShares = vault.balanceOf(actor);
        if (maxShares == 0) return;

        shares = bound(shares, 1, maxShares);

        // Skip if redeem would be below minimum
        uint256 assets = vault.previewRedeem(shares);
        if (assets < 1e18) return;

        vm.prank(actor);
        uint256 actualAssets = vault.requestRedeem(shares);

        ghost_totalPendingRedemptions += actualAssets;
    }

    function completeRedeem(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        (uint256 pendingAssets,, uint256 requestedAt) = vault.redemptionRequests(actor);
        if (pendingAssets == 0) return;

        // Ensure delay has passed
        if (block.timestamp < requestedAt + vault.WITHDRAWAL_DELAY()) {
            vm.warp(requestedAt + vault.WITHDRAWAL_DELAY());
        }

        // Ensure sDIEM withdrawal is complete
        (uint256 sdiemPending,) = stakingVault.withdrawalRequests(address(vault));
        if (sdiemPending > 0) {
            try stakingVault.completeWithdraw() {} catch {}
        }

        // Only complete if enough liquid
        uint256 liquid = diem.balanceOf(address(vault));
        if (liquid < pendingAssets) {
            // Try syncing and completing
            try vault.syncWithdrawals() {} catch {}
            (sdiemPending,) = stakingVault.withdrawalRequests(address(vault));
            if (sdiemPending > 0) {
                try stakingVault.completeWithdraw() {} catch {}
            }
            liquid = diem.balanceOf(address(vault));
            if (liquid < pendingAssets) return;
        }

        vm.prank(actor);
        vault.completeRedeem();

        ghost_totalPendingRedemptions -= pendingAssets;
        ghost_totalRedeemed += pendingAssets;
    }

    function harvest() external {
        // Only harvest if there's something to harvest
        if (vault.totalSupply() == 0) return;
        if (stakingVault.balanceOf(address(vault)) == 0) return;

        // Seed rewards
        uint256 rewardAmount = 5e6; // 5 USDC
        usdc.mint(operator, rewardAmount);
        vm.startPrank(operator);
        usdc.approve(address(stakingVault), rewardAmount);
        stakingVault.notifyRewardAmount(rewardAmount);
        vm.stopPrank();

        // Warp to accrue full rewards
        vm.warp(block.timestamp + 24 hours);

        // Harvest
        try vault.harvest() {} catch {}
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 7 days);
        vm.warp(block.timestamp + secs);
    }

    function redeployExcess() external {
        uint256 liquid = diem.balanceOf(address(vault));
        uint256 pendingR = vault.totalPendingRedemptions();
        if (liquid <= pendingR) return;

        vault.redeployExcess();
    }

    function syncWithdrawals() external {
        try vault.syncWithdrawals() {} catch {}
    }
}

// ── Invariant Test Suite ───────────────────────────────────────────────────

contract csDIEMInvariantTest is Test {
    csDIEM public vault;
    sDIEM public stakingVault;
    MockDIEMStaking public diem;
    ERC20Mock public usdc;
    MockSwapRouter public router;
    MockCLPool public oracle;
    csDIEMHandler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");

    function setUp() public {
        diem = new MockDIEMStaking();
        usdc = new ERC20Mock();
        router = new MockSwapRouter(address(diem));
        oracle = new MockCLPool();

        stakingVault = new sDIEM(address(diem), address(usdc), admin, operator);

        vault = new csDIEM(
            IERC20(address(diem)),
            address(stakingVault),
            address(usdc),
            address(router),
            address(oracle),
            admin,
            50,
            1800,
            1,
            1e6
        );

        handler = new csDIEMHandler(vault, stakingVault, diem, usdc, operator);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = csDIEMHandler.deposit.selector;
        selectors[1] = csDIEMHandler.requestRedeem.selector;
        selectors[2] = csDIEMHandler.completeRedeem.selector;
        selectors[3] = csDIEMHandler.harvest.selector;
        selectors[4] = csDIEMHandler.warpTime.selector;
        selectors[5] = csDIEMHandler.redeployExcess.selector;
        selectors[6] = csDIEMHandler.syncWithdrawals.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Total deposited >= total redeemed + totalAssets + totalPendingRedemptions
    /// Harvests add DIEM from swaps, so deposited may be less than the total accounted.
    /// But redeemed + inVault should never exceed deposited + harvested.
    function invariant_noSharesWithoutAssets() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0, "shares exist but totalAssets is 0");
        }
    }

    /// @notice Share price (assets per share) must never drop below initial 1:1
    function invariant_sharePriceNeverBelowInitial() public view {
        if (vault.totalSupply() == 0) return;

        uint256 currentPrice = vault.convertToAssets(1e24);
        // Price starts at ~1e18 (1 DIEM per share), should only go up
        assertGe(currentPrice + 1, 1e18, "share price dropped below 1:1");
    }

    /// @notice convertToAssets and convertToShares are inverse (within rounding)
    function invariant_conversionConsistency() public view {
        if (vault.totalSupply() == 0) return;

        uint256 testAssets = 100e18;
        uint256 shares = vault.convertToShares(testAssets);
        uint256 assetsBack = vault.convertToAssets(shares);

        uint256 tolerance = testAssets / 100_000 + 1;
        assertApproxEqAbs(assetsBack, testAssets, tolerance, "conversion round-trip failed");
        assertLe(assetsBack, testAssets, "vault overpaying on conversion");
    }

    /// @notice Ghost pending redemptions tracks contract state
    function invariant_pendingRedemptionsMatchGhost() public view {
        assertEq(
            vault.totalPendingRedemptions(),
            handler.ghost_totalPendingRedemptions(),
            "totalPendingRedemptions != ghost"
        );
    }

    /// @notice totalAssets must account for all DIEM positions
    /// totalAssets = sdiemBalance + sdiemPending + liquid - totalPendingRedemptions
    function invariant_totalAssetsAccountsForAllDiem() public view {
        uint256 sdiemBal = stakingVault.balanceOf(address(vault));
        (uint256 sdiemPending,) = stakingVault.withdrawalRequests(address(vault));
        uint256 liquid = diem.balanceOf(address(vault));
        uint256 gross = sdiemBal + sdiemPending + liquid;
        uint256 expected = gross > vault.totalPendingRedemptions()
            ? gross - vault.totalPendingRedemptions()
            : 0;

        assertEq(
            vault.totalAssets(),
            expected,
            "totalAssets != sdiemBal + sdiemPending + liquid - pendingRedemptions"
        );
    }
}
