/**
 * Calculate sDIEM APR from on-chain rewardRate and totalStaked.
 *
 * rewardRate = USDC per second (6 decimals)
 * totalStaked = DIEM staked (18 decimals)
 *
 * APR = (rewardRate * 86400 * 365) / totalStaked * (1e18 / 1e6) * 100
 *     = (rewardRate * 31_536_000 * 1e12) / totalStaked * 100
 */
export function calcSDiemApr(
  rewardRate: bigint,
  totalStaked: bigint
): number | null {
  if (totalStaked === 0n) return null;

  const SECONDS_PER_YEAR = 31_536_000n;
  const DECIMAL_ADJUSTMENT = 10n ** 12n; // 1e18 / 1e6
  const PRECISION = 10n ** 4n; // 2 decimal places of APR

  const aprBps =
    (rewardRate * SECONDS_PER_YEAR * DECIMAL_ADJUSTMENT * PRECISION * 100n) /
    totalStaked;

  return Number(aprBps) / Number(PRECISION);
}
