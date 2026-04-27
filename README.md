# DIEM Staking

Stake DIEM tokens to earn USDC yield from Venice AI compute revenue. All staked DIEM is forward-staked on Venice for compute credits, and revenue flows back to stakers as USDC.

Deployed on **Base**. Built with Foundry (Solidity 0.8.24).

## Architecture

```
                     ┌──────────────────────────────┐
                     │      Venice AI Compute        │
                     └──────────────┬───────────────┘
                                    │ USDC revenue
                                    ▼
                     ┌──────────────────────────────┐
                     │       RevenueSplitter         │
                     │   Receives USDC from customers│
                     │     20% → platform Safe       │
                     │     80% → sDIEM stakers       │
                     │   Permissionless distribute() │
                     └──────┬─────────────────┬─────┘
                     20%    │             80% │ notifyRewardAmount()
                            ▼                 ▼
                     ┌──────────┐    ┌──────────────────┐
                     │ 2/2 Safe │    │      sDIEM       │
                     │ (platform│    │ Synthetix fork   │
                     │  fees)   │    │ Earn USDC (24h)  │
                     └──────────┘    └──────────────────┘
```

### Contracts

| Contract | Description |
|---|---|
| **sDIEM** | Synthetix StakingRewards fork. Stake DIEM, earn USDC rewards streamed linearly over 24h. All staked DIEM is forward-staked on Venice for compute credits. 24h async withdrawals matching Venice's unstake cooldown. |
| **RevenueSplitter** | Receives USDC revenue from compute customers and splits it 20% to the platform 2/2 Safe and 80% to sDIEM stakers via `notifyRewardAmount`. Permissionless `distribute()` with a 23h cooldown and minimum-amount floor to prevent reward-stream fragmentation. |
| **DIEMVault** | USDC deposit vault for the DIEM Relay service. Borrowers deposit USDC on-chain; an off-chain watcher credits relay accounts. Deposit-only (Phase 1). |

### Revenue Loop

```
Stake DIEM → sDIEM
         → forward-staked on Venice ($1/day compute per staked DIEM)
         → compute revenue lands on RevenueSplitter as USDC
         → distribute(): 20% → 2/2 Safe, 80% → sDIEM.notifyRewardAmount()
         → streamed to stakers over 24h
```

USDC revenue lands directly on the RevenueSplitter contract. Anyone can trigger `distribute()` once the balance exceeds the minimum floor and the 23h cooldown has elapsed. The splitter is the only authorized operator for `sDIEM.notifyRewardAmount()`.

### Venice Forward-Staking

All deposited DIEM is immediately forward-staked on Venice (the DIEM token contract has staking built in). No liquid buffer is held.

- **Permissionless management**: `claimFromVenice()` and `redeployExcess()` callable by anyone.
- **24h async withdrawals**: `requestWithdraw()` auto-initiates Venice unstake. After 24h, `completeWithdraw()` auto-claims from Venice. Users can `cancelWithdraw()` at any time.
- **Partial withdrawals**: `completeWithdraw()` supports partial payouts when only some Venice-unstaked DIEM is available, preventing one user's unfunded batch from blocking others. After partial completion, Venice unstake is auto-initiated for remaining amounts.
- **Batched unstaking**: Withdrawal requests that arrive during an active Venice cooldown are batched via `totalPendingNotInitiated`. When the cooldown matures and a user completes, the next batch is auto-initiated. Worst-case withdrawal time: ~48h (two Venice cooldowns).

## Project Structure

```
contracts/
  src/
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    RevenueSplitter.sol     20/80 USDC splitter: Safe + sDIEM
    DIEMVault.sol           USDC deposit vault for relay credits
    interfaces/
      IsDIEM.sol            sDIEM interface
      IRevenueSplitter.sol  RevenueSplitter interface
      IDIEMStaking.sol      DIEM token staking interface (Base)
      IDIEMVault.sol        DIEMVault interface
  test/
    sDIEM.t.sol             67 unit/fuzz tests
    sDIEMInvariant.t.sol    7 invariant tests
    DIEMVault.t.sol         52 unit/fuzz tests
    DIEMVaultInvariant.t.sol 3 invariant tests
    RevenueSplitter.t.sol   20 unit/fuzz tests
    RevenueSplitterInvariant.t.sol  2 invariant tests
    RevenueSplitterFork.t.sol  1 Base-fork integration test
    mocks/                  MockDIEMStaking, MockERC20
  script/
    DeploySDiem.s.sol             sDIEM deployment
    DeployDIEMVault.s.sol         DIEMVault deployment
    DeployRevenueSplitter.s.sol   RevenueSplitter deployment
src/                        Relay server (TypeScript / Bun / Hono)
app/                        Staking UI (Next.js / wagmi / RainbowKit)
```

## Build and Test

```bash
cd contracts
forge install
forge build
forge test            # 152 tests across 7 suites (unit, fuzz, invariant, fork)
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

# DIEMVault
forge script script/DeployDIEMVault.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify

# RevenueSplitter (addresses default to Base mainnet + 2/2 Safe)
forge script script/DeployRevenueSplitter.s.sol \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

After RevenueSplitter deployment, the sDIEM admin must call `sDIEM.setOperator(splitter)` so the splitter becomes the sole caller of `notifyRewardAmount`.

## Security

**Access control**: Two-step admin transfer on sDIEM. Separate operator role on sDIEM for reward notification.

**Emergency pause**: Deposits and staking gated behind pause. Withdrawals and reward claims always allowed, even when paused -- users can always exit.

**Reentrancy**: ReentrancyGuard on all mutative functions across all contracts. CEI (Checks-Effects-Interactions) pattern throughout.

**Token safety**: SafeERC20 for all ERC-20 operations. Zero-address checks on all constructors and admin setters.

**Token recovery**: `recoverERC20()` on all contracts for accidentally sent tokens, with safeguards preventing recovery of core assets (DIEM, USDC).

**Venice cooldown handling**: Claim-first semantics in `initiateVeniceUnstake()` -- claims matured cooldown before initiating new one, preventing cooldown reset DoS (audit finding M-01).

**Venice unstake auto-initiation**: `completeWithdraw()` calls `_tryInitiateVeniceUnstake()` before the payout check, ensuring deferred Venice unstakes are kicked off even when `requestWithdraw()` couldn't initiate them (M-02 fix).

**Partial withdrawal support**: `completeWithdraw()` pays out available liquid DIEM rather than reverting when full amount isn't funded. Auto-initiates next Venice unstake batch after partial completion.

**Timer reset on accumulation**: Every new `requestWithdraw` resets the 24h timer, preventing delay bypass via stale timer inheritance (Pashov deep audit finding #2).

**Reward dust**: `notifyRewardAmount()` returns integer division rounding dust to caller instead of stranding it in the contract (audit finding L-01).

### Audit

sDIEM and DIEMVault were audited by Bretzel (March 2026): 0 Critical, 0 High, 1 Medium, 1 Low, 4 Informational. All findings remediated. A follow-up Pashov AI deep pass (March 2026) surfaced two additional issues, both remediated. RevenueSplitter (April 2026) was reviewed internally with the same Pashov AI tooling and is pending an external review. See `contracts/AUDIT.md` and `contracts/KNOWN_ISSUES.md`.

### Test Coverage

152 tests across 7 suites: unit, fuzz, invariant, and Base-fork integration tests. Key invariants verified:
- Sum of staker balances equals `totalStaked`.
- Sum of borrower balances equals `totalDeposits`.
- Share price never decreases (absent slashing).
