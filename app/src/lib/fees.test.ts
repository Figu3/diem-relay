/**
 * One-off test for rollingFees (no JS test runner in this app — run with `bun`).
 *   bun run src/lib/fees.test.ts
 */
import { rollingApr, rollingFees, stakedAtClose, type Distribution } from "./fees";

let failures = 0;
function check(name: string, cond: boolean) {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    console.log(`  FAIL ${name}`);
    failures++;
  }
}

const DAY = 86_400;
const T0 = 1_776_729_600; // 2026-04-21 00:00 UTC
const usdc = (n: number) => BigInt(Math.round(n * 1e6));
const dist = (day: number, total: number, hour = 12): Distribution => ({
  timestamp: T0 + day * DAY + hour * 3600,
  platform: usdc(total * 0.2),
  staker: usdc(total * 0.8),
});

console.log("rollingFees");

check("empty input -> no points", rollingFees([], T0).length === 0);

{
  const pts = rollingFees([dist(0, 10)], T0 + 10 * DAY);
  check("one point per day from first distribution to today", pts.length === 11);
  check("first point starts at the distribution's UTC day", pts[0].day === T0);
  check("distribution counts on its own day", pts[0].total === 10);
  check("still in window on day 6", pts[6].total === 10);
  check("drops out on day 7", pts[7].total === 0);
  check("split is carried through", pts[0].staker === 8 && pts[0].platform === 2);
}

{
  // Unsorted input; two on the same day; one exactly 7 days later at 00:00.
  const pts = rollingFees(
    [dist(7, 5, 0), dist(0, 1), dist(0, 2, 23), dist(3, 4)],
    T0 + 8 * DAY
  );
  check("sorts its input and sums same-day distributions", pts[0].total === 3);
  check("accumulates across the window", pts[3].total === 7);
  check("day 7 drops day 0 and adds day 7", pts[7].total === 9);
}

console.log("stakedAtClose");

{
  const diem = (n: number) => BigInt(n) * 10n ** 18n;
  const days = [T0, T0 + DAY, T0 + 2 * DAY];
  const staked = stakedAtClose(
    [
      { timestamp: T0 + DAY + 10, delta: -diem(4) },
      { timestamp: T0 + 5, delta: diem(10) },
      { timestamp: T0 + 2 * DAY + DAY, delta: diem(99) }, // next day's 00:00: excluded
    ],
    days
  );
  check("applies changes up to each day's close, unsorted input", staked.join() === "10,6,6");
}

console.log("rollingApr");

{
  // 7 days of $7/day to stakers -> $49 per 7d; 100 DIEM at $1 -> $100 staked.
  const pts = rollingFees(
    Array.from({ length: 7 }, (_, d) => ({
      timestamp: T0 + d * DAY + 3600,
      platform: 0n,
      staker: usdc(7),
    })),
    T0 + 6 * DAY
  );
  const apr = rollingApr(pts, Array(7).fill(100), Array(7).fill(1));
  check("annualizes the window's staker fees over staked value", Math.abs((apr[6] ?? 0) - 49 * (365 / 7)) < 1e-9);
  check("missing price -> null", rollingApr(pts, Array(7).fill(100), [1, 1, 1, 1, 1, 1, null])[6] === null);
  check("nothing staked -> null", rollingApr(pts, Array(7).fill(0), Array(7).fill(1))[6] === null);
}

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall passed");
