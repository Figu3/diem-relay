/**
 * One-off test for calcSDiemApr (no JS test runner in this app — run with `bun`).
 *   bun run src/lib/apr.test.ts
 *
 * Guards the stale-rewardRate bug: Synthetix `rewardRate` is never zeroed when
 * a reward period ends, so annualizing it after `periodFinish` shows a phantom
 * APR for rewards that are no longer streaming.
 */
import { calcSDiemApr } from "./apr";

let failures = 0;
function check(name: string, cond: boolean) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.error(`  FAIL ${name}`);
  }
}

const PRICE = 1318.18;

// --- Live sDIEM v1 snapshot: period ended ~27 days ago, rewardRate still 32.
// The vault pays nothing, so the displayed APR must be null, not ~76.5%.
{
  const now = 1782403258n;
  const periodFinish = 1780099505n; // 26.7 days in the past
  const apr = calcSDiemApr(32n, 1000029005656532886n, PRICE, periodFinish, now);
  check("ended period → null (no phantom APR)", apr === null);
}

// --- Live sDIEM v2 snapshot: period still active → real APR (~4.46%).
{
  const now = 1782403211n;
  const periodFinish = 1782466771n; // ~17h ahead
  const apr = calcSDiemApr(32n, 17163974232721811848n, PRICE, periodFinish, now);
  check("active period → numeric APR", apr !== null);
  check("active APR in sane range", apr !== null && apr > 3 && apr < 6);
}

// --- The "32,704%" hero-card bug: page.tsx annualized USDC-per-DIEM-per-day
// without dividing by the DIEM price (implicitly 1 DIEM = $1). With the price
// divisor the same live values must yield ~24.6%, not tens of thousands of %.
{
  const now = 1782454760n;
  const periodFinish = 1782518703n; // active
  const apr = calcSDiemApr(178n, 17164418267624488343n, 1331.37, periodFinish, now);
  check("rewardRate 178 → ~24.6%, not 32,704%", apr !== null && apr > 20 && apr < 30);
  // Sanity: the old price-less formula (usdcPerDiemDay * 365 * 100) blows up.
  const usdcPerDiemDay = Number((178n * 86400n * 10n ** 18n) / 17164418267624488343n) / 1e6;
  check("old price-less formula really did explode", usdcPerDiemDay * 365 * 100 > 30000);
}

// --- Boundary: now === periodFinish counts as ended (rewardRate already stale).
{
  const t = 1782466771n;
  check(
    "now == periodFinish → null",
    calcSDiemApr(32n, 17163974232721811848n, PRICE, t, t) === null
  );
}

// --- Existing guards still hold.
{
  const now = 1n;
  const pf = 1000n;
  check("zero stake → null", calcSDiemApr(32n, 0n, PRICE, pf, now) === null);
  check("null price → null", calcSDiemApr(32n, 1n, null, pf, now) === null);
}

if (failures > 0) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
