/**
 * Calculate sDIEM APR from on-chain rewardRate and totalStaked.
 *
 * rewardRate  = USDC per second (6 decimals)
 * totalStaked = DIEM staked     (18 decimals)
 * diemPriceUsd = USD per 1 DIEM (float, from price oracle/API)
 *
 * APR (%) = (rewardsPerYearUsd / totalStakedUsd) * 100
 */
export function calcSDiemApr(
  rewardRate: bigint,
  totalStaked: bigint,
  diemPriceUsd: number | null
): number | null {
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
