/**
 * One-off test for rollingFees (no JS test runner in this app — run with `bun`).
 *   bun run src/lib/fees.test.ts
 */
import { rollingFees, type Distribution } from "./fees";

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

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall passed");
