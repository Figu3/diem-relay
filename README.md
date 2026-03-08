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

### Venice Forward-Staking

Both sDIEM and csDIEM forward-stake deposited DIEM tokens on Venice to generate compute credits:

```
User stakes DIEM → sDIEM/csDIEM
                      │ ~90% deployed to Venice (DIEM.stake())
                      │ ~10% kept as liquid buffer
                      │
                Venice compute credits ($1/day per staked DIEM)
                      │
              Revenue funds rewards
              (USDC for sDIEM, DIEM for csDIEM)
```

- **Buffer model**: 10% target / 5% floor — withdrawals served from buffer first, Venice unstaking (24h cooldown) only when buffer runs low
- **Conservation invariant**: `liquidBuffer + forwardStaked + pendingUnstake == totalStaked`

## Structure

```
src/              Relay server (TypeScript / Bun / Hono)
contracts/
  src/
    DIEMVault.sol           USDC deposit vault for relay credits
    sDIEM.sol               Stake DIEM, earn USDC (Synthetix model)
    csDIEM.sol              Stake DIEM, earn DIEM (ERC-4626, composable)
    interfaces/
      IDIEMStaking.sol      DIEM token staking interface (Base)
      IsDIEM.sol            sDIEM interface
      IcsDIEM.sol           csDIEM interface (extends IERC4626)
  test/
    sDIEM.t.sol             51 unit/fuzz tests (incl. Venice forward-staking)
    sDIEMInvariant.t.sol    6 invariant tests (buffer conservation)
    csDIEM.t.sol            53 unit/fuzz tests (incl. Venice forward-staking)
    csDIEMInvariant.t.sol   5 invariant tests (buffer conservation)
    DIEMVault.t.sol         40 unit/fuzz tests
    DIEMVaultInvariant.t.sol 4 invariant tests
    mocks/
      MockDIEMStaking.sol   DIEM token mock with built-in staking
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
forge test             # 159 tests (unit, fuzz, invariant)
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
| `bun run operator` | Venice forward-staking operator bot |
| `bun run admin` | Admin CLI |
| `bun run borrower` | Borrower CLI |
| `bun run test:e2e` | E2E relay tests |
| `bun run test:contracts` | Foundry tests |

## Security

- **Static analysis**: Slither clean on all contracts (zero High/Medium/Critical)
- **Test coverage**: 159 tests across 6 suites including invariant + fuzz testing
- **Pause design**: Deposits gated behind pause; withdrawals always allowed
- **csDIEM**: Two-step admin transfer, ERC-4626 virtual share offset (1e6) for inflation attack protection
- **sDIEM**: Immutable admin, CEI pattern, SafeERC20 throughout
