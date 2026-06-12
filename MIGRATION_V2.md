# sDIEM v2 / csDIEM v2 — Deploy + Migration Runbook

This is the pre-deploy and deploy checklist for the `sdiem-v2` branch. It is
not a smart-contract design doc — see `contracts/AUDIT.md` and
`contracts/KNOWN_ISSUES.md` for that. The goal here is "what do I actually run
on the day of the deploy, and what changes off-chain after the contracts go
live."

## TL;DR for LPs

The v1 contracts (sDIEM `0xdbF05A…`, csDIEM `0x4899f5…`) will keep working
indefinitely. There is **no on-chain migration contract**. LPs migrate by:

1. v1 sDIEM holder: `sDIEM.requestWithdraw(amount)` → wait 24h → `sDIEM.completeWithdraw()` → receive DIEM → `sDIEMv2.stake(amount)` (or `csDIEMv2.depositDIEM(amount, you)` if you want the auto-compounding wrapper).
2. v1 csDIEM holder: `csDIEM.requestRedeem(shares)` → wait 24h → `csDIEM.completeRedeem()` → receive DIEM → `csDIEMv2.depositDIEM(amount, you)` (or `sDIEMv2.stake(amount)` if you prefer the raw-yield stream).

Frontend will add a "Migrate to v2" path with the two-tx wait. The 24h delay
is inherent — DIEM has to round-trip through Venice cooldown.

Once an LP is on v2: their sDIEM is **transferable** (the v2 unlock), and
csDIEM v2 is a **standard ERC-4626** integratable with Pendle, Morpho,
Spectra, and Silo without bespoke adapters.

## Pre-deploy checklist

Run through this in order. Don't skip steps.

### 1. Branch state

```bash
cd /Users/figue/Desktop/Vibe\ Coding/DeFi/_active/diem-lending
git checkout sdiem-v2
git pull origin sdiem-v2
git log --oneline main..HEAD     # confirm what's in the branch
```

### 2. Local test suite

```bash
cd contracts
forge build
forge test --no-match-path "test/*Fork.t.sol"   # 271 tests, ~10s
```

All must pass. If you see a failure, **do not deploy** — open a PR fix
first.

### 3. Base mainnet fork tests

```bash
BASE_RPC_URL=$BASE_RPC_URL forge test --match-contract DiemV2ForkTest -vv
```

Five tests against live infrastructure:
- TWAP queryable on the production oracle pool
- Real DIEM → Venice forward-stake works
- sDIEM transfer preserves rewards (the v2 unlock proven on live state)
- Full zap → harvest → real Slipstream swap → real Venice → redeem cycle
- maxDeposit pause fix works (Morpho-integration prerequisite)

If any of these revert, the production pool or one of the external
dependencies has shifted state. Investigate before deploying.

### 4. Slither (optional but recommended)

```bash
slither . --foundry-out-directory out --filter-paths "lib/|test/"
```

v2 should produce the same severity profile as v1 (no new actionable
findings beyond the accepted patterns documented in `KNOWN_ISSUES.md`).

### 5. External audit gate

If TVL on day-1 will be > $500K or a third-party integrator (Pendle,
Morpho, Spectra, Silo) is planning to wire in v2, run an external Pashov
deep pass before mainnet deploy. Internal review covers the four
adversarial passes documented in `KNOWN_ISSUES.md` §K-10.

## Deploy steps

### 1. Env vars

Set these in your shell before any `forge script`:

```bash
export PRIVATE_KEY=0x...        # deployer
export BASE_RPC_URL=https://...  # use a dedicated endpoint, not mainnet.base.org
export BASESCAN_API_KEY=...
export ADMIN=0x01Ea790410D9863A57771D992D2A72ea326DD7C9  # the 2/2 Safe
export OPERATOR=0x96DAE834f7276D50a09149D938e998b1766AFCDa  # RevenueSplitter v2
```

`ADMIN` must be the literal Safe address or the string `DEPLOYER` (sentinel
for opt-in deployer-as-admin). Defaulting to the deployer is refused.

### 2. Deploy sDIEM v2

```bash
forge script script/DeploySDiemV2.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

Verify the broadcast log shows the expected immutables:
- `diem == 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024`
- `usdc == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- `admin == <Safe>`
- `operator == <RevenueSplitter v2>`

Save the deployed address. We'll call it `SDIEM_V2` below.

### 3. Deploy csDIEM v2

The deploy script's `_assertOracleTwapQueryable` helper will revert if
the oracle pool doesn't have enough observation history. The production
pool already does (v1 has been running for months), so this is just a
safety probe.

```bash
export SDIEM=$SDIEM_V2
export SWAP_ROUTER=0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
export ORACLE_POOL=0xBc3231036Ee1ECa03E5F67FEceDC640D21610823
export TICK_SPACING=100
# Set MIN_DIEM_PER_USDC to 50% of current TWAP at deploy time. Query
# beforehand with `cast call $ORACLE_POOL ...` or use the same value
# that v1 csDIEM uses today (see user memory: 442705213890074).
export MIN_DIEM_PER_USDC=442705213890074

forge script script/DeployCSDiemV2.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

Save the deployed address as `CSDIEM_V2`.

### 4. Verify on BaseScan if `--verify` was rate-limited

```bash
# sDIEMv2
forge verify-contract $SDIEM_V2 sDIEMv2 --chain base --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
    0xF4d97F2da56e8c3098f3a8D538DB630A2606a024 \
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
    $ADMIN \
    $OPERATOR)

# csDIEMv2
forge verify-contract $CSDIEM_V2 csDIEMv2 --chain base --watch \
  --constructor-args $(cast abi-encode \
    "constructor(address,address,address,address,address,address,uint256,uint32,int24,uint256,uint256)" \
    $SDIEM_V2 \
    0xF4d97F2da56e8c3098f3a8D538DB630A2606a024 \
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
    $SWAP_ROUTER \
    $ORACLE_POOL \
    $ADMIN \
    50 \
    3600 \
    100 \
    100000000 \
    $MIN_DIEM_PER_USDC)
```

csDIEM v1 was unverified for months — don't repeat that. Verification
makes the contract integratable.

### 5. Operator setup

RevenueSplitter v2 is the live operator for sDIEM v2 rewards and is the
address that receives current CheapTokens USDC revenue. sDIEM v2's `operator`
is immutable at construction, so the splitter used by the keeper must be the
same RevenueSplitter v2 address configured as the sDIEM v2 operator.

Current cutover state:

- RevenueSplitter v2 receives new CheapTokens revenue and notifies sDIEM v2.
- RevenueSplitter v1 remains historical for the v1 migration window.
- The keeper should distribute through RevenueSplitter v2 by default.

## Post-deploy checklist

### 1. Sanity-check the deployment on-chain

```bash
# sDIEM v2
cast call $SDIEM_V2 "name()" --rpc-url $BASE_RPC_URL          # "Staked DIEM"
cast call $SDIEM_V2 "symbol()" --rpc-url $BASE_RPC_URL        # "sDIEM"
cast call $SDIEM_V2 "diem()" --rpc-url $BASE_RPC_URL          # = DIEM addr
cast call $SDIEM_V2 "admin()" --rpc-url $BASE_RPC_URL         # = Safe
cast call $SDIEM_V2 "operator()" --rpc-url $BASE_RPC_URL      # = chosen operator
cast call $SDIEM_V2 "DOMAIN_SEPARATOR()" --rpc-url $BASE_RPC_URL  # non-zero

# csDIEM v2
cast call $CSDIEM_V2 "asset()" --rpc-url $BASE_RPC_URL        # = SDIEM_V2
cast call $CSDIEM_V2 "sdiem()" --rpc-url $BASE_RPC_URL        # = SDIEM_V2
cast call $CSDIEM_V2 "diem()" --rpc-url $BASE_RPC_URL         # = DIEM
cast call $CSDIEM_V2 "admin()" --rpc-url $BASE_RPC_URL        # = Safe
cast call $CSDIEM_V2 "minDiemPerUsdc()" --rpc-url $BASE_RPC_URL  # > 0
cast call $CSDIEM_V2 "totalAssets()" --rpc-url $BASE_RPC_URL  # 0 at deploy
cast call $CSDIEM_V2 "totalSupply()" --rpc-url $BASE_RPC_URL  # 0 at deploy
cast call $CSDIEM_V2 "maxDeposit(address)(uint256)" 0x0 --rpc-url $BASE_RPC_URL  # type(uint256).max
```

### 2. Smoke test from the Safe

The Safe stakes a tiny amount (say 0.01 DIEM) to confirm:

```
1. safe.diem.approve(SDIEM_V2, 0.01e18)
2. safe.sDIEM_V2.stake(0.01e18)
3. assertEq(SDIEM_V2.balanceOf(safe), 0.01e18)
4. assertEq(diem.balanceOf(SDIEM_V2), 0)     # forwarded to Venice
5. assertEq(diemStaking.stakedInfos(SDIEM_V2).stakedAmount, 0.01e18)
```

Bundle these into a single Safe transaction batch if possible. Verifying
on-chain that Venice received the stake catches integration mistakes early.

### 3. Seed first reward period

If using a temporary operator EOA:

```
operator.usdc.approve(SDIEM_V2, X)
operator.sDIEM_V2.notifyRewardAmount(X)   # X ≥ 86400 (smallest non-trivial)
```

Wait 24 hours and confirm `sDIEM_V2.earned(safe)` is non-zero.

### 4. Smoke-test csDIEM v2

```
1. safe.diem.approve(CSDIEM_V2, 0.01e18)
2. safe.csDIEM_V2.depositDIEM(0.01e18, safe)
3. assertEq(SDIEM_V2.balanceOf(CSDIEM_V2), 0.01e18)
4. assertGt(csDIEM_V2.balanceOf(safe), 0)
```

Wait for USDC to accrue, then `harvest(now+300)` and confirm `totalAssets()`
went up.

## Off-chain updates after deploy

### Keeper script (`src/keeper-distribute.ts` on the NUC)

The keeper currently calls `csDIEM.harvest(deadline)` and
`RevenueSplitter.distribute()`. After v2 deploy, decisions:

- **Add a second harvest step for csDIEM v2.** The keeper should harvest
  both v1 and v2 until v1 is deprecated. Both calls have independent
  try/catch and skip-conditions — a failure on v2 shouldn't block v1's
  distribute.
- **Distribute through RevenueSplitter v2.** The keeper default should match
  the live RevenueSplitter v2 address that receives CheapTokens revenue.

Sketch of the keeper diff:

```typescript
// existing
await csDIEMv1.harvest(deadline);
await revenueSplitter.distribute();

// add
await csDIEMv2.harvest(deadline);  // new
```

Wrap each `await` in its own `try/catch` so a v2 hiccup doesn't kill the
v1 path during migration.

### Frontend (`app/` — Next.js)

Add a v2 page (or v2 toggle) that:

1. Shows the user's v1 sDIEM + csDIEM balances.
2. Renders a "Migrate to v2" CTA explaining the two-tx + 24h flow.
3. Routes through the v1 exit functions, then on a follow-up visit
   (after the 24h delay) prompts the v2 deposit.
4. For new users: defaults to v2.

Address constants (in `app/lib/contracts.ts` or equivalent):

```typescript
export const SDIEM_V2 = "0x...";       // fill in after deploy
export const CSDIEM_V2 = "0x...";      // fill in after deploy
```

### AUDIT.md / KNOWN_ISSUES.md

After deploy: edit the v2 entries in both files to remove the *(pending
deploy)* tag and add the live addresses.

### README

Move the "v2 (sdiem-v2 branch — pending deploy)" section to "v2 (live)"
and add the addresses.

## Deprecating v1 (later)

When LP migration is complete (or after a 30-day window — your call):

1. Safe pauses sDIEM v1 (`sDIEM.pause()`). Withdrawals/redemptions still work.
2. Safe pauses csDIEM v1 (`csDIEM.pause()`). Same — exits remain open.
3. RevenueSplitter rotates to sDIEM v2 (if not done at v2 launch).
4. Update README's deployment table to note v1 as "deprecated, exit-only."
5. Keeper drops the v1 harvest call.
6. Frontend hides v1 deposit UI; keeps v1 withdraw UI for stragglers.

There's no rush — v1 can sit paused-but-exitable indefinitely without
harm. The Venice forward-stakes continue earning compute credits even
when sDIEM v1 is paused (pause only gates new staking, not the underlying
Venice relationship).

## Rollback

If something goes wrong post-deploy:

- **Pause** both contracts via the Safe. Users can still exit (both pause
  semantics keep redemptions open).
- **Do not** transfer admin away from the Safe. Two-step admin transfer
  is your safety net.
- **Investigate** with `cast call` and the broadcast logs before any
  state-changing action.

If a fix requires a redeploy: the contracts have no upgrade path (no
proxy by design), so a redeploy is a fresh contract with its own
migration. Communicate to LPs early.
