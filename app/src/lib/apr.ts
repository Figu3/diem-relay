/**
 * Calculate sDIEM APR from on-chain rewardRate and totalStaked.
 *
 * rewardRate   = USDC per second (6 decimals)
 * totalStaked  = DIEM staked     (18 decimals)
 * diemPriceUsd = USD per 1 DIEM (float, from price oracle/API)
 * periodFinish = unix ts when the current reward period ends (on-chain)
 * nowSec       = current unix ts
 *
 * APR (%) = (rewardsPerYearUsd / totalStakedUsd) * 100
 *
 * Returns null once the reward period has ended: the Synthetix model never
 * zeroes `rewardRate` at `periodFinish` (it only changes on the next
 * notifyRewardAmount), so annualizing a lapsed rate would show a phantom APR
 * for rewards that are no longer streaming.
 */
export function calcSDiemApr(
  rewardRate: bigint,
  totalStaked: bigint,
  diemPriceUsd: number | null,
  periodFinish: bigint,
  nowSec: bigint
): number | null {
  if (nowSec >= periodFinish) return null;
  if (totalStaked === 0n) return null;
  if (!diemPriceUsd || diemPriceUsd <= 0) return null;

  const SECONDS_PER_YEAR = 31_536_000n;
  const rewardsPerYearUsdc = rewardRate * SECONDS_PER_YEAR;

  const rewardsPerYearUsd = Number(rewardsPerYearUsdc) / 1e6;
  const totalStakedDiem = Number(totalStaked) / 1e18;
  const totalStakedUsd = totalStakedDiem * diemPriceUsd;

  if (totalStakedUsd === 0) return null;

  return (rewardsPerYearUsd / totalStakedUsd) * 100;
}

/**
 * Calculate trailing APR from the growth (delta) of Synthetix
 * `rewardPerToken()` between two blocks.
 *
 * rewardPerToken accrues `reward * 1e18 / totalSupply` (reward in USDC
 * 6 decimals, supply in DIEM 18 decimals), so a holder of exactly 1 DIEM
 * earns `delta / 1e18 * 1e18 = delta` raw USDC units over the window —
 * i.e. `delta / 1e6` USD per DIEM staked.
 *
 * Unlike the live-rate APR above, this measures rewards actually accrued
 * over the window, so it needs no periodFinish gate: lapsed periods simply
 * stop growing rewardPerToken.
 */
export function calcTrailingApr(
  rewardPerTokenDelta: bigint,
  windowSeconds: bigint,
  diemPriceUsd: number | null
): number | null {
  if (windowSeconds <= 0n) return null;
  if (!diemPriceUsd || diemPriceUsd <= 0) return null;
  if (rewardPerTokenDelta < 0n) return null;

  const SECONDS_PER_YEAR = 31_536_000;
  const usdPerDiem = Number(rewardPerTokenDelta) / 1e6;

  return (
    (usdPerDiem / diemPriceUsd) * (SECONDS_PER_YEAR / Number(windowSeconds)) * 100
  );
}
