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
                  └──────────┬──────────────┬────────────┘
                             │              │
                     ┌───────▼──────┐  ┌────▼──────────┐
                     │    sDIEM     │  │    csDIEM     │
                     │  Earn USDC   │  │  Earn DIEM    │
                     │  Synthetix   │  │  ERC-4626     │
                     │  24h stream  │  │  Composable   │
                     └──────────────┘  └───────────────┘
```

| Contract | Model | Reward | Composable | Use Case |
|---|---|---|---|---|
| **sDIEM** | Synthetix StakingRewards | USDC (streamed over 24h) | No | Direct yield, claim anytime |
| **csDIEM** | ERC-4626 vault | DIEM (via operator donation) | Yes | Pendle, Morpho, Silo integration |

## Structure

```
src/              Relay server (TypeScript / Bun / Hono)
contracts/
  src/
    DIEMVault.sol           USDC deposit vault for relay credits
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    csDIEM.sol              Stake DIEM, earn DIEM (ERC-4626, composable)
    interfaces/
      IsDIEM.sol            sDIEM interface
      IcsDIEM.sol           csDIEM interface (extends IERC4626)
  test/
    sDIEM.t.sol             34 unit/fuzz tests
    sDIEMInvariant.t.sol    6 invariant tests
    csDIEM.t.sol            35 unit/fuzz tests
    csDIEMInvariant.t.sol   5 invariant tests
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
forge test             # 124 tests (unit, fuzz, invariant)
```

### Deploy (Sepolia)

```bash
cd contracts
forge script script/DeployMockUSDC.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
forge script script/DeployDIEMVault.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

## Scripts

| Command | Description |
|---|---|
| `bun run dev` | Start relay in watch mode |
| `bun run watcher` | Start deposit event watcher |
| `bun run admin` | Admin CLI |
| `bun run borrower` | Borrower CLI |
| `bun run test:e2e` | E2E relay tests |
| `bun run test:contracts` | Foundry tests |

## Security

- **Static analysis**: Slither clean on all contracts (zero High/Medium/Critical)
- **Test coverage**: 124 tests across 6 suites including invariant + fuzz testing
- **Pause design**: Deposits gated behind pause; withdrawals always allowed
- **csDIEM**: Two-step admin transfer, ERC-4626 virtual share offset (1e6) for inflation attack protection
- **sDIEM**: Immutable admin, CEI pattern, SafeERC20 throughout
