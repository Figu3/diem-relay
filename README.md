# DIEM Relay

Pay-per-token AI inference relay backed by on-chain USDC deposits.

Borrowers deposit USDC into the on-chain vault, the relay watches for deposit events and credits balances, then borrowers consume AI inference at a discount through an OpenAI-compatible API proxying Venice.ai.

## Architecture

```
Borrower deposits USDC --> DIEMVault (on-chain)
                               | Deposited event
                          deposit-watcher (relay)
                               | credits balance in SQLite
Borrower calls /v1/chat/completions --> Relay --> Venice.ai
                               | deducts from balance
```

## Structure

```
src/              Relay server (TypeScript / Bun / Hono)
contracts/        On-chain vault (Solidity 0.8.24 / Foundry)
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
forge test
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
