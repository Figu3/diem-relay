/** One RevenueSplitter `Distributed` event (USDC amounts, 6 decimals). */
export interface Distribution {
  /** Unix seconds, from the event's own `timestamp` field. */
  timestamp: number;
  platform: bigint;
  staker: bigint;
}

export interface FeePoint {
  /** Unix seconds at 00:00 UTC of the day this point closes. */
  day: number;
  /** USD of fees distributed in the window ending at the close of `day`. */
  total: number;
  staker: number;
  platform: number;
}

const DAY = 86_400;

/**
 * Trailing-window fee totals, one point per UTC day from the first
 * distribution's day through `nowSec`'s day. Each point sums the
 * distributions in (dayEnd - windowDays, dayEnd], so a day's point includes
 * that whole day. Fees are counted when distributed, not when earned: a
 * splitter that holds revenue under its floor shows zero until it pays out.
 */
export function rollingFees(
  distributions: readonly Distribution[],
  nowSec: number,
  windowDays = 7
): FeePoint[] {
  if (distributions.length === 0) return [];

  const sorted = [...distributions].sort((a, b) => a.timestamp - b.timestamp);
  const firstDay = Math.floor(sorted[0].timestamp / DAY) * DAY;
  const lastDay = Math.floor(nowSec / DAY) * DAY;
  const window = windowDays * DAY;

  const points: FeePoint[] = [];
  let lo = 0;
  let hi = 0;
  let staker = 0n;
  let platform = 0n;

  for (let day = firstDay; day <= lastDay; day += DAY) {
    const end = day + DAY;
    while (hi < sorted.length && sorted[hi].timestamp < end) {
      staker += sorted[hi].staker;
      platform += sorted[hi].platform;
      hi++;
    }
    while (lo < hi && sorted[lo].timestamp < end - window) {
      staker -= sorted[lo].staker;
      platform -= sorted[lo].platform;
      lo++;
    }
    points.push({
      day,
      total: Number(staker + platform) / 1e6,
      staker: Number(staker) / 1e6,
      platform: Number(platform) / 1e6,
    });
  }

  return points;
}

/** A change to total staked DIEM (18 decimals); negative for exits. */
export interface StakeChange {
  timestamp: number;
  delta: bigint;
}

/** Total staked DIEM (as a float) at the close of each UTC day in `days`. */
export function stakedAtClose(changes: readonly StakeChange[], days: readonly number[]): number[] {
  const sorted = [...changes].sort((a, b) => a.timestamp - b.timestamp);
  const out: number[] = [];
  let i = 0;
  let staked = 0n;
  for (const day of days) {
    while (i < sorted.length && sorted[i].timestamp < day + DAY) {
      staked += sorted[i].delta;
      i++;
    }
    out.push(Number(staked) / 1e18);
  }
  return out;
}

/**
 * Trailing staker APR (%) per point: the window's staker fees, annualized,
 * over the window's average staked value (mean of daily closes of staked
 * DIEM × DIEM price). Null where nothing was staked or the price is unknown.
 * Uses the same window as `points` (built by rollingFees).
 */
export function rollingApr(
  points: readonly FeePoint[],
  staked: readonly number[],
  prices: readonly (number | null)[],
  windowDays = 7
): (number | null)[] {
  return points.map((point, i) => {
    let valueSum = 0;
    let samples = 0;
    for (let k = Math.max(0, i - windowDays + 1); k <= i; k++) {
      const price = prices[k];
      if (price === null || !(price > 0)) return null;
      valueSum += staked[k] * price;
      samples++;
    }
    const avgValue = valueSum / samples;
    if (!(avgValue > 0)) return null;
    return ((point.staker * (365 / windowDays)) / avgValue) * 100;
  });
}
