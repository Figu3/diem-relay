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
