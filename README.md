# DIEM Relay

Pay-per-token AI inference relay backed by on-chain USDC deposits, with DIEM token staking for yield.

## Architecture

```
Borrower deposits USDC --> DIEMVault (on-chain)
                               | Deposited event
                          deposit-watcher (relay)
                               | credits balance in SQLite
Borrower calls /v1/chat/completions --> Relay --> Venice.ai
                               | deducts from balance
```

### Staking (Dual-Mode)

DIEM holders can stake to earn yield from Venice AI compute revenue:

```
                  ┌─────────────────────────────────────┐
                  │         Venice AI Revenue            │
                  │         (USDC from inference)        │
                  └──────────────┬──────────────────────┘
                                 │
                        ┌────────▼─────────┐
                        │  RevenueSplitter  │
                        │  (permissionless) │
                        └───┬──────────┬───┘
                            │          │
                    USDC    │          │  USDC → swap → DIEM
                            │          │
                    ┌───────▼──────┐  ┌▼──────────────┐
                    │    sDIEM     │  │    csDIEM      │
                    │  Earn USDC   │  │  Earn DIEM     │
                    │  Synthetix   │  │  ERC-4626      │
                    │  24h stream  │  │  Composable    │
                    └──────────────┘  └────────────────┘
```

| Contract | Model | Reward | Composable | Use Case |
|---|---|---|---|---|
| **sDIEM** | Synthetix StakingRewards | USDC (streamed over 24h) | No | Direct yield, claim anytime |
| **csDIEM** | ERC-4626 vault | DIEM (via donation) | Yes | Pendle, Morpho, Silo integration |
| **RevenueSplitter** | Permissionless splitter | — | — | Splits USDC revenue to sDIEM + csDIEM |

### Venice Forward-Staking

Both sDIEM and csDIEM forward-stake deposited DIEM tokens on Venice to generate compute credits:

```
User stakes DIEM → sDIEM/csDIEM
                      │ All DIEM deployed to Venice (DIEM.stake())
                      │ Liquid DIEM held only for pending withdrawals
                      │
                Venice compute credits ($1/day per staked DIEM)
                      │
              Revenue → RevenueSplitter → rewards
              (USDC for sDIEM, DIEM for csDIEM)
```

- **Permissionless Venice management**: `claimFromVenice()` and `redeployExcess()` callable by anyone
- **24h async withdrawals**: Users `requestWithdraw()` (auto-initiates Venice unstake) → wait 24h → `completeWithdraw()` (auto-claims from Venice). Cancel anytime with `cancelWithdraw()`

### RevenueSplitter

Receives USDC from Venice compute credit revenue and splits it:

- **sDIEM portion**: USDC transferred to sDIEM + `notifyRewardAmount()` called (starts 24h stream)
- **csDIEM portion**: USDC swapped to DIEM via Uniswap V3, then `donate()` called on csDIEM (increases share price)

`distribute()` is fully permissionless — anyone can trigger it when the contract holds USDC above the minimum threshold. Split ratio is admin-configurable in basis points.

## Structure

```
src/              Relay server (TypeScript / Bun / Hono)
contracts/
  src/
    DIEMVault.sol           USDC deposit vault for relay credits
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    csDIEM.sol              Stake DIEM, earn DIEM (ERC-4626, composable)
    RevenueSplitter.sol     Permissionless USDC revenue distribution
    interfaces/
      IDIEMStaking.sol      DIEM token staking interface (Base)
      IsDIEM.sol            sDIEM interface
      IcsDIEM.sol           csDIEM interface (extends IERC4626)
      IRevenueSplitter.sol  RevenueSplitter interface
      ISwapRouter.sol       Minimal Uniswap V3 router interface
  test/
    sDIEM.t.sol             51 unit/fuzz tests (incl. Venice forward-staking)
    sDIEMInvariant.t.sol    6 invariant tests
    csDIEM.t.sol            53 unit/fuzz tests (incl. Venice forward-staking)
    csDIEMInvariant.t.sol   5 invariant tests
    RevenueSplitter.t.sol   33 unit tests (split, swap, admin, integration)
    DIEMVault.t.sol         40 unit/fuzz tests
    DIEMVaultInvariant.t.sol 4 invariant tests
    mocks/
      MockDIEMStaking.sol   DIEM token mock with built-in staking
      MockERC20.sol         Mintable ERC20 with configurable decimals
      MockSwapRouter.sol    DEX router mock with configurable rate
app/              Staking UI (Next.js 16 / wagmi / RainbowKit / Tailwind)
```

## Quick Start

### Relay

```bash
cp .env.example .env   # fill in VENICE_API_KEY and ADMIN_SECRET
bun install
bun run dev            # http://localhost:3100
```

### Contracts

```bash
cd contracts
forge install
forge build
forge test             # 242 tests (unit, fuzz, invariant)
```

### Deploy

**DIEMVault (Sepolia testnet)**:
```bash
cd contracts
forge script script/DeployMockUSDC.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
forge script script/DeployDIEMVault.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

**sDIEM (Base)**:
```bash
cd contracts
OPERATOR=0x... forge script script/DeploySDiem.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

**csDIEM (Base)**:
```bash
cd contracts
OPERATOR=0x... forge script script/DeployCSDiem.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

## Scripts

| Command | Description |
|---|---|
| `bun run dev` | Start relay in watch mode |
| `bun run watcher` | Start deposit event watcher |
| `bun run operator` | Permissionless keeper bot (Venice + revenue distribution) |
| `bun run admin` | Admin CLI |
| `bun run borrower` | Borrower CLI |
| `bun run test:e2e` | E2E relay tests |
| `bun run test:contracts` | Foundry tests |

## Security

- **Static analysis**: Slither clean on all contracts (zero High/Medium/Critical)
- **Test coverage**: 242 tests across 8 suites including invariant + fuzz testing
- **Permissionless design**: Venice management and revenue distribution require no special roles — anyone can call
- **Pause design**: Deposits/staking gated behind pause; withdrawals and reward claims always allowed (even when paused)
- **csDIEM**: Two-step admin transfer, ERC-4626 virtual share offset (1e6) for inflation attack protection
- **sDIEM**: Two-step admin transfer, CEI pattern, SafeERC20 throughout
- **RevenueSplitter**: ReentrancyGuard, two-step admin transfer, max slippage cap (10%), min distribution threshold, token recovery (non-USDC)
- **Audited** by [Bretzel](https://github.com/bretzke) (March 2026) — 0 Critical, 0 High, 1 Medium, 1 Low, 4 Informational. All findings remediated.

### Audit Remediations (v2)

| Finding | Severity | Fix |
|---|---|---|
| M-01: Venice cooldown reset DoS | Medium | Claim-first semantics in `initiateVeniceUnstake()` — claims matured cooldown before initiating new one |
| L-01: Reward dust stuck forever | Low | `notifyRewardAmount()` returns rounding dust to caller |
| I-01: DIEMVault missing safety functions | Info | Added `nonReentrant` to `withdrawProtocolFees()`, added `recoverERC20()` |

### UX Improvements (v2)

| Change | Before | After |
|---|---|---|
| Withdrawal flow | 4 manual transactions | 2 transactions: `requestWithdraw()` + `completeWithdraw()` |
| Venice initiation | Manual `initiateVeniceUnstake()` | Auto-initiated on `requestWithdraw()`/`requestRedeem()` |
| Venice claim | Manual `claimFromVenice()` | Auto-claimed on `completeWithdraw()`/`completeRedeem()` |
| Cancel withdrawal | Not possible | `cancelWithdraw()` / `cancelRedeem()` re-stakes DIEM |
| Check readiness | Simulate tx | `canCompleteWithdraw(addr)` / `canCompleteRedeem(addr)` view |
| Pause behavior | Blocked exit + claim | Only deposits blocked; exit and claim always allowed |
| Reward seeding | 2 txs (transfer + notify) | 1 tx (`notifyRewardAmount` pulls via `transferFrom`) |
