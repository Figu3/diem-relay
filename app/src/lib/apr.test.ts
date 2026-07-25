/**
 * One-off test for calcSDiemApr (no JS test runner in this app — run with `bun`).
 *   bun run src/lib/apr.test.ts
 *
 * Guards the stale-rewardRate bug: Synthetix `rewardRate` is never zeroed when
 * a reward period ends, so annualizing it after `periodFinish` shows a phantom
 * APR for rewards that are no longer streaming.
 */
import { calcSDiemApr, calcTrailingApr } from "./apr";

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

// --- calcTrailingApr: consistency with the live-rate APR above.
// Same v2 snapshot: rewardRate=32 (USDC6/s), totalStaked≈17.164 DIEM. Over a
// 7-day window at that rate, rewardPerToken grows by
// 32 * 604800 * 1e18 / 17163974232721811848 ≈ 1_127_570, and the trailing
// APR must land on the same ~4.46% as the instantaneous calculation.
{
  const delta = (32n * 604800n * 10n ** 18n) / 17163974232721811848n;
  const apr = calcTrailingApr(delta, 604800n, PRICE);
  check("trailing ≈ live-rate APR for constant rate", apr !== null && apr > 4.3 && apr < 4.6);
}

// --- Trailing APR needs no periodFinish gate: a window with zero accrual
// (lapsed period) reports 0%, not null and not a phantom rate.
{
  const apr = calcTrailingApr(0n, 604800n, PRICE);
  check("zero accrual → 0% (not null)", apr === 0);
}

// --- Guards.
{
  check("zero window → null", calcTrailingApr(1n, 0n, PRICE) === null);
  check("null price → null (trailing)", calcTrailingApr(1n, 604800n, null) === null);
  check("negative delta → null", calcTrailingApr(-1n, 604800n, PRICE) === null);
}

if (failures > 0) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
