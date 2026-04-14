# DIEM Staking

Stake DIEM tokens to earn yield from Venice AI compute revenue. All staked DIEM is forward-staked on Venice for compute credits, and revenue flows back to stakers as USDC or compounded DIEM.

Deployed on **Base**. Built with Foundry (Solidity 0.8.24).

## Architecture

```
                     ┌──────────────────────────────┐
                     │      Venice AI Compute        │
                     │   (sold via cheaptokens.ai)   │
                     └──────────────┬───────────────┘
                                    │ USDC revenue
                                    │
                         notifyRewardAmount()
                                    │
                     ┌──────────────▼───────────────┐
                     │            sDIEM              │
                     │   Synthetix StakingRewards    │
                     │   Stake DIEM → earn USDC      │
                     │   24h linear reward stream    │
                     └──────────────┬───────────────┘
                                    │
                     ┌──────────────▼───────────────┐
                     │           csDIEM              │
                     │     ERC-4626 Compounder       │
                     │  Claims USDC → swaps → DIEM   │
                     │     Restakes into sDIEM       │
                     └──────────────────────────────┘
```

### Contracts

| Contract | Description |
|---|---|
| **sDIEM** | Synthetix StakingRewards fork. Stake DIEM, earn USDC rewards streamed linearly over 24h. All staked DIEM is forward-staked on Venice for compute credits. 24h async withdrawals matching Venice's unstake cooldown. |
| **csDIEM** | ERC-4626 auto-compounding vault wrapping sDIEM. Claims USDC rewards, swaps USDC to DIEM via Aerodrome Slipstream CL (with TWAP oracle protection), restakes DIEM into sDIEM. For users who want compounding exposure rather than USDC yield. Compatible with Pendle, Morpho, Silo. |
| **DIEMVault** | USDC deposit vault for the DIEM Relay service. Borrowers deposit USDC on-chain; an off-chain watcher credits relay accounts. Deposit-only (Phase 1). |

### Revenue Loop

```
Stake DIEM → sDIEM
         → forward-staked on Venice ($1/day compute per staked DIEM)
         → compute sold via cheaptokens.ai
         → USDC revenue
         → notifyRewardAmount() on sDIEM
         → streamed to stakers over 24h
```

All USDC revenue goes directly to sDIEM. csDIEM users get compounding by harvesting their share of USDC rewards and swapping back to DIEM.

### Venice Forward-Staking

All deposited DIEM is immediately forward-staked on Venice (the DIEM token contract has staking built in). No liquid buffer is held.

- **Permissionless management**: `claimFromVenice()` and `redeployExcess()` callable by anyone.
- **24h async withdrawals**: `requestWithdraw()` auto-initiates Venice unstake. After 24h, `completeWithdraw()` auto-claims from Venice. Users can `cancelWithdraw()` at any time.
- **Partial withdrawals**: `completeWithdraw()` supports partial payouts when only some Venice-unstaked DIEM is available, preventing one user's unfunded batch from blocking others. After partial completion, Venice unstake is auto-initiated for remaining amounts.
- **Batched unstaking**: Withdrawal requests that arrive during an active Venice cooldown are batched via `totalPendingNotInitiated`. When the cooldown matures and a user completes, the next batch is auto-initiated. Worst-case withdrawal time: ~48h (two Venice cooldowns).

### csDIEM Harvest Flow

The `harvest()` function is permissionless and executes three steps:

1. Claims accrued USDC from sDIEM.
2. Swaps USDC to DIEM via Aerodrome Slipstream CL pool (TWAP-protected).
3. Restakes received DIEM into sDIEM.

Share price increases monotonically as harvested DIEM compounds.

## Project Structure

```
contracts/
  src/
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    csDIEM.sol              Auto-compounding ERC-4626 vault over sDIEM
    DIEMVault.sol           USDC deposit vault for relay credits
    interfaces/
      IsDIEM.sol            sDIEM interface
      IcsDIEM.sol           csDIEM interface (extends IERC4626)
      IDIEMStaking.sol      DIEM token staking interface (Base)
      IDIEMVault.sol        DIEMVault interface
      ICLSwapRouter.sol     Aerodrome Slipstream CL router interface
      ICLPool.sol           Aerodrome Slipstream CL pool interface
    libraries/
      OracleLibrary.sol     TWAP oracle consultation
      TickMath.sol          Tick-to-price math (Uniswap V3)
      FullMath.sol          512-bit multiplication helpers
  test/
    sDIEM.t.sol             67 unit/fuzz tests
    sDIEMInvariant.t.sol    7 invariant tests
    csDIEM.t.sol            56 unit/fuzz tests
    csDIEMInvariant.t.sol   5 invariant tests
    DIEMVault.t.sol         52 unit/fuzz tests
    DIEMVaultInvariant.t.sol 3 invariant tests
    mocks/                  MockDIEMStaking, MockERC20, MockSwapRouter, MockCLPool
  script/
    DeploySDiem.s.sol       sDIEM deployment
    DeployCSDiem.s.sol      csDIEM deployment
    DeployDIEMVault.s.sol   DIEMVault deployment
src/                        Relay server (TypeScript / Bun / Hono)
app/                        Staking UI (Next.js / wagmi / RainbowKit)
```

## Build and Test

```bash
cd contracts
forge install
forge build
forge test            # 212 tests across 8 suites (unit, fuzz, invariant, fork)
```

## Deployment

All contracts are deployed on **Base** (chain ID 8453).

| Contract | Address |
|---|---|
| **DIEMVault** | `0xdc9625b026f6Dd17F9d96e608592A9C592e27eEF` |
| **sDIEM** | `0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2` |
| **RevenueSplitter** | `0xd185138CEA135E60CA6E567BE53DEC81D89Ce7D6` |
| sDIEM (superseded) | `0x59650b79eF4c2eC193B49DbFc23d50d48EBf9f34` |
| sDIEM (superseded) | `0x9566a919c7A4a7b22243736f39781A2787ddC11e` |

Deploy scripts:

```bash
cd contracts

# sDIEM
OPERATOR=0x... forge script script/DeploySDiem.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# csDIEM
OPERATOR=0x... forge script script/DeployCSDiem.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# DIEMVault
forge script script/DeployDIEMVault.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

## Security

**Access control**: Two-step admin transfer on sDIEM and csDIEM. Separate operator role on sDIEM for reward notification.

**Emergency pause**: Deposits and staking gated behind pause. Withdrawals and reward claims always allowed, even when paused -- users can always exit.

**Reentrancy**: ReentrancyGuard on all mutative functions across all contracts. CEI (Checks-Effects-Interactions) pattern throughout.

**Token safety**: SafeERC20 for all ERC-20 operations. Zero-address checks on all constructors and admin setters.

**csDIEM swap protection**:
- TWAP oracle (minimum 5-minute window) for fair price reference on USDC-to-DIEM swaps.
- Configurable slippage tolerance (max 10% hard cap).
- Absolute DIEM-per-USDC price floor circuit breaker.
- ERC-4626 virtual share offset (1e6) for inflation attack mitigation.

**Token recovery**: `recoverERC20()` on all contracts for accidentally sent tokens, with safeguards preventing recovery of core assets (DIEM, USDC).

**Venice cooldown handling**: Claim-first semantics in `initiateVeniceUnstake()` -- claims matured cooldown before initiating new one, preventing cooldown reset DoS (audit finding M-01).

**Venice unstake auto-initiation**: `completeWithdraw()` calls `_tryInitiateVeniceUnstake()` before the payout check, ensuring deferred Venice unstakes are kicked off even when `requestWithdraw()` couldn't initiate them (M-02 fix).

**Partial withdrawal support**: `completeWithdraw()` pays out available liquid DIEM rather than reverting when full amount isn't funded. Auto-initiates next Venice unstake batch after partial completion.

**Timer reset on accumulation**: Every new `requestWithdraw`/`requestRedeem` resets the 24h timer, preventing delay bypass via stale timer inheritance (Pashov deep audit finding #2).

**Reward dust**: `notifyRewardAmount()` returns integer division rounding dust to caller instead of stranding it in the contract (audit finding L-01).

### Audit

Audited by Bretzel (March 2026). 0 Critical, 0 High, 1 Medium, 1 Low, 4 Informational. All findings remediated.

Pashov AI deep audit (March 2026). 2 Critical findings remediated: `totalPendingNotInitiated` accounting fix, withdrawal timer bypass fix.

### Test Coverage

212 tests across 8 suites: unit, fuzz, invariant, and Base-fork integration tests. Key invariants verified:
- Sum of staker balances equals `totalStaked`.
- Sum of borrower balances equals `totalDeposits`.
- csDIEM `totalAssets` accounts for all DIEM positions (staked + pending + liquid - owed).
- Share price never decreases (absent slashing).
