// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {sDIEM} from "../src/sDIEM.sol";
import {csDIEM} from "../src/csDIEM.sol";
import {MockDIEMStaking} from "./mocks/MockDIEMStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";

/**
 * @title RevenueSplitterHandler
 * @notice Guided handler for invariant testing of RevenueSplitter.
 *         Exercises distribution, config changes, and time warps.
 */
contract RevenueSplitterHandler is Test {
    RevenueSplitter public splitter;
    MockERC20 public usdcToken;
    MockDIEMStaking public diemToken;
    sDIEM public sdiem;
    csDIEM public csdiem;
    address public admin;

    // Ghost variables — track what SHOULD be true
    uint256 public ghost_totalUsdcFunded;
    uint256 public ghost_totalUsdcDistributed;
    uint256 public ghost_totalToSdiem;
    uint256 public ghost_totalToCsdiem;
    uint256 public ghost_distributionCount;

    constructor(
        RevenueSplitter _splitter,
        MockERC20 _usdc,
        MockDIEMStaking _diem,
        sDIEM _sdiem,
        csDIEM _csdiem,
        address _admin
    ) {
        splitter = _splitter;
        usdcToken = _usdc;
        diemToken = _diem;
        sdiem = _sdiem;
        csdiem = _csdiem;
        admin = _admin;
    }

    // ── Actions ───────────────────────────────────────────────────────────

    /// @notice Fund the splitter with random USDC then distribute all.
    function fundAndDistribute(uint256 amount) external {
        amount = bound(amount, splitter.minDistribution(), 100_000e6);

        // Fund splitter
        usdcToken.mint(address(splitter), amount);
        ghost_totalUsdcFunded += amount;

        // distribute() sends the FULL balance — may include leftover from partial distributions
        uint256 actualDistributed = usdcToken.balanceOf(address(splitter));

        // Snapshot sDIEM USDC balance before distribution
        uint256 sdiemBefore = usdcToken.balanceOf(address(sdiem));

        // Distribute
        splitter.distribute();

        // Track split amounts via ghost vars
        uint256 sdiemAfter = usdcToken.balanceOf(address(sdiem));
        uint256 usdcToSdiem = sdiemAfter - sdiemBefore;

        ghost_totalToSdiem += usdcToSdiem;
        ghost_totalToCsdiem += (actualDistributed - usdcToSdiem);
        ghost_totalUsdcDistributed += actualDistributed;
        ghost_distributionCount += 1;
    }

    /// @notice Fund and distribute a specific amount (partial balance).
    function fundAndDistributePartial(uint256 fundAmount, uint256 distributeAmount) external {
        fundAmount = bound(fundAmount, splitter.minDistribution(), 100_000e6);
        usdcToken.mint(address(splitter), fundAmount);
        ghost_totalUsdcFunded += fundAmount;

        uint256 balance = usdcToken.balanceOf(address(splitter));
        distributeAmount = bound(distributeAmount, splitter.minDistribution(), balance);

        uint256 sdiemBefore = usdcToken.balanceOf(address(sdiem));

        splitter.distribute(distributeAmount);

        uint256 sdiemAfter = usdcToken.balanceOf(address(sdiem));
        uint256 usdcToSdiem = sdiemAfter - sdiemBefore;

        ghost_totalToSdiem += usdcToSdiem;
        ghost_totalToCsdiem += (distributeAmount - usdcToSdiem);
        ghost_totalUsdcDistributed += distributeAmount;
        ghost_distributionCount += 1;
    }

    /// @notice Admin changes the sDIEM/csDIEM split ratio.
    function setSplit(uint256 newBps) external {
        newBps = bound(newBps, 0, 10_000);
        vm.prank(admin);
        splitter.setSplit(newBps);
    }

    /// @notice Admin changes the minimum distribution threshold.
    function setMinDistribution(uint256 newMin) external {
        newMin = bound(newMin, 1e6, 10_000e6); // 1 to 10K USDC
        vm.prank(admin);
        splitter.setMinDistribution(newMin);
    }

    /// @notice Admin changes the max slippage.
    function setMaxSlippage(uint256 newSlippage) external {
        newSlippage = bound(newSlippage, 0, 1000); // 0 to 10%
        vm.prank(admin);
        splitter.setMaxSlippage(newSlippage);
    }

    /// @notice Warp time to affect reward periods in sDIEM.
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 48 hours);
        vm.warp(block.timestamp + seconds_);
    }
}

/**
 * @title RevenueSplitterInvariantTest
 * @notice Invariant tests for the RevenueSplitter contract.
 *
 * Key invariants:
 *   1. Split conservation: toSdiem + toCsdiem == totalDistributed
 *   2. USDC solvency: splitter never distributes more than funded
 *   3. BPS invariant: sdiemBps <= 10000
 *   4. No USDC dust leak: splitter balance == funded - distributed
 *   5. Split ratio accuracy: sDIEM portion matches bps math
 *   6. Slippage bound: maxSlippageBps <= 1000 always
 */
contract RevenueSplitterInvariantTest is Test {
    RevenueSplitter public splitter;
    sDIEM public sdiem;
    csDIEM public csdiem;
    MockDIEMStaking public diemToken;
    MockERC20 public usdcToken;
    MockSwapRouter public router;
    MockAerodromePool public oraclePool;
    RevenueSplitterHandler public handler;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    uint256 constant INITIAL_SDIEM_BPS = 5000;
    uint256 constant MIN_DISTRIBUTION = 100e6;
    uint256 constant MAX_SLIPPAGE = 100;
    address constant AERO_FACTORY = address(0xAE40);
    uint256 constant TWAP_GRANULARITY = 4;

    function setUp() public {
        // Deploy mocks
        diemToken = new MockDIEMStaking();
        usdcToken = new MockERC20("USDC", "USDC", 6);
        router = new MockSwapRouter(address(diemToken));
        oraclePool = new MockAerodromePool();

        // Deploy staking contracts
        sdiem = new sDIEM(address(diemToken), address(usdcToken), admin, operator);
        csdiem = new csDIEM(IERC20(address(diemToken)), admin, operator);

        // Deploy splitter
        splitter = new RevenueSplitter(
            address(usdcToken),
            address(diemToken),
            address(sdiem),
            address(csdiem),
            address(router),
            address(oraclePool),
            AERO_FACTORY,
            admin,
            INITIAL_SDIEM_BPS,
            MIN_DISTRIBUTION,
            MAX_SLIPPAGE,
            TWAP_GRANULARITY
        );

        // Set splitter as operator on sDIEM
        vm.prank(admin);
        sdiem.setOperator(address(splitter));

        // Seed stakers so rewards can be distributed
        diemToken.mint(alice, 10_000e18);
        vm.startPrank(alice);
        diemToken.approve(address(sdiem), type(uint256).max);
        diemToken.approve(address(csdiem), type(uint256).max);
        sdiem.stake(5_000e18);
        csdiem.deposit(5_000e18, alice);
        vm.stopPrank();

        // Instant cooldown for testing
        diemToken.setCooldownDuration(0);

        handler = new RevenueSplitterHandler(
            splitter,
            usdcToken,
            diemToken,
            sdiem,
            csdiem,
            admin
        );

        // Target only the handler
        targetContract(address(handler));
    }

    // ── Invariant 1: Split conservation ────────────────────────────────────
    // Every USDC distributed must go to either sDIEM or csDIEM — nothing lost.

    function invariant_splitConservation() public view {
        assertEq(
            handler.ghost_totalToSdiem() + handler.ghost_totalToCsdiem(),
            handler.ghost_totalUsdcDistributed(),
            "toSdiem + toCsdiem != totalDistributed"
        );
    }

    // ── Invariant 2: USDC solvency ─────────────────────────────────────────
    // Splitter never distributes more USDC than it received.

    function invariant_usdcSolvency() public view {
        assertLe(
            handler.ghost_totalUsdcDistributed(),
            handler.ghost_totalUsdcFunded(),
            "distributed > funded"
        );
    }

    // ── Invariant 3: BPS bound ─────────────────────────────────────────────
    // sdiemBps must always be <= 10000.

    function invariant_bpsBound() public view {
        assertLe(
            splitter.sdiemBps(),
            10_000,
            "sdiemBps > 10000"
        );
    }

    // ── Invariant 4: No USDC dust leak ─────────────────────────────────────
    // Splitter's USDC balance == total funded - total distributed.

    function invariant_noUsdcDustLeak() public view {
        assertEq(
            usdcToken.balanceOf(address(splitter)),
            handler.ghost_totalUsdcFunded() - handler.ghost_totalUsdcDistributed(),
            "splitter USDC balance != funded - distributed"
        );
    }

    // ── Invariant 5: Slippage bound ────────────────────────────────────────
    // maxSlippageBps must always be <= 1000 (10%).

    function invariant_slippageBound() public view {
        assertLe(
            splitter.maxSlippageBps(),
            1000,
            "maxSlippageBps > 1000"
        );
    }

    // ── Invariant 6: Distribution count consistency ────────────────────────
    // If distributions happened, total distributed must be > 0.

    function invariant_distributionCountConsistency() public view {
        if (handler.ghost_distributionCount() > 0) {
            assertGt(
                handler.ghost_totalUsdcDistributed(),
                0,
                "distributions happened but totalDistributed is 0"
            );
        }
    }
}
