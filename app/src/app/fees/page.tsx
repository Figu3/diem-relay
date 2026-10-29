"use client";

import { useMemo, useState } from "react";
import { Header } from "@/components/Header";
import { FeesChart, type ChartPoint } from "@/components/FeesChart";
import { useFeeHistory } from "@/hooks/useFeeHistory";
import { useStakeHistory } from "@/hooks/useStakeHistory";
import { rollingApr, rollingFees, stakedAtClose } from "@/lib/fees";

type ChartMode = "usd" | "apr";

const DAY = 86_400;
// A daily price further than this from a day's close is treated as missing.
const MAX_PRICE_GAP = 2 * DAY;

function formatUsd(value: number, maxFraction = 2) {
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: maxFraction });
}

function formatPercent(value: number, maxFraction = 2) {
  return `${value.toLocaleString("en-US", { minimumFractionDigits: maxFraction, maximumFractionDigits: maxFraction })}%`;
}

function formatDay(day: number) {
  return new Date(day * 1000).toLocaleDateString("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

/** Price nearest each day's close (00:00 UTC next day, or now for today). */
function pricesAtClose(prices: { timestamp: number; price: number }[], days: number[], nowSec: number) {
  let j = 0;
  return days.map((day) => {
    const close = Math.min(day + DAY, nowSec);
    while (j + 1 < prices.length && Math.abs(prices[j + 1].timestamp - close) <= Math.abs(prices[j].timestamp - close)) j++;
    const nearest = prices[j];
    return nearest && Math.abs(nearest.timestamp - close) <= MAX_PRICE_GAP ? nearest.price : null;
  });
}

export default function FeesPage() {
  const [mode, setMode] = useState<ChartMode>("usd");
  const { data: distributions, isLoading, isError } = useFeeHistory();
  // Only scan stake history once someone opens the APR view.
  const stakeHistory = useStakeHistory(mode === "apr");

  const stats = useMemo(() => {
    if (!distributions?.length) return null;
    const points = rollingFees(distributions, Math.floor(Date.now() / 1000));
    const staker = distributions.reduce((sum, d) => sum + d.staker, 0n);
    const platform = distributions.reduce((sum, d) => sum + d.platform, 0n);
    const peak = points.reduce((best, p) => (p.total > best.total ? p : best), points[0]);
    return {
      points,
      current: points[points.length - 1],
      peak,
      allTime: Number(staker + platform) / 1e6,
      allTimeStaker: Number(staker) / 1e6,
      count: distributions.length,
    };
  }, [distributions]);

  const aprSeries = useMemo(() => {
    if (!stats || !stakeHistory.data) return null;
    const days = stats.points.map((p) => p.day);
    const staked = stakedAtClose(stakeHistory.data.changes, days);
    const prices = pricesAtClose(stakeHistory.data.prices, days, Math.floor(Date.now() / 1000));
    const apr = rollingApr(stats.points, staked, prices);
    return { apr, staked, prices };
  }, [stats, stakeHistory.data]);

  const usdPoints: ChartPoint[] = useMemo(
    () =>
      stats?.points.map((p) => ({
        day: p.day,
        value: p.total,
        details: [`Stakers ${formatUsd(p.staker)}`, `Platform ${formatUsd(p.platform)}`],
      })) ?? [],
    [stats]
  );

  const aprPoints: ChartPoint[] = useMemo(
    () =>
      stats && aprSeries
        ? stats.points.map((p, i) => ({
            day: p.day,
            value: aprSeries.apr[i],
            details: [
              `Stakers ${formatUsd(p.staker)} in 7d`,
              `${aprSeries.staked[i].toLocaleString("en-US", { maximumFractionDigits: 2 })} DIEM staked`,
              aprSeries.prices[i] !== null ? `DIEM ${formatUsd(aprSeries.prices[i] ?? 0, 0)}` : "DIEM price n/a",
            ],
          }))
        : [],
    [stats, aprSeries]
  );

  const currentApr = aprSeries ? aprSeries.apr[aprSeries.apr.length - 1] : null;
  const aprLoading = mode === "apr" && (stakeHistory.isLoading || (!aprSeries && !stakeHistory.isError));

  // Weekly rows (newest first) for the table view.
  const weeklyIdx = stats
    ? stats.points.map((_, i) => i).filter((i) => (stats.points.length - 1 - i) % 7 === 0).reverse()
    : [];

  return (
    <>
      <Header />
      <div className="pool-page">
        <div className="pool-shell">
          <section className="pool-hero pool-hero-compact">
            <div>
              <div className="pool-kicker">Protocol revenue</div>
              <h1 className="pool-title">Fees</h1>
              <p className="pool-subtitle">
                USDC from inference sales, split on-chain between sDIEM stakers and the platform.
              </p>
            </div>
            <div className="pool-status-card">
              {mode === "usd" ? (
                <>
                  <span>7d fees</span>
                  <strong>{stats ? formatUsd(stats.current.total) : "—"}</strong>
                  <small>{stats ? `${formatUsd(stats.current.staker)} to stakers` : "Loading"}</small>
                </>
              ) : (
                <>
                  <span>7d staker APR</span>
                  <strong>{currentApr !== null ? formatPercent(currentApr) : "—"}</strong>
                  <small>{aprLoading ? "Loading" : "Fees to stakers / staked value"}</small>
                </>
              )}
            </div>
          </section>

          <section className="pool-vault-totals" aria-label="Fees since launch">
            <div className="pool-vault-totals-header">
              <div className="fees-header-left">
                <span>{mode === "usd" ? "Trailing 7d fees" : "Trailing 7d staker APR"}</span>
                <div className="fees-mode-tabs" role="tablist" aria-label="Chart unit">
                  <button
                    aria-selected={mode === "usd"}
                    className={mode === "usd" ? "fees-mode-tab-active" : ""}
                    onClick={() => setMode("usd")}
                    role="tab"
                    type="button"
                  >
                    $ Fees
                  </button>
                  <button
                    aria-selected={mode === "apr"}
                    className={mode === "apr" ? "fees-mode-tab-active" : ""}
                    onClick={() => setMode("apr")}
                    role="tab"
                    type="button"
                  >
                    % APR
                  </button>
                </div>
              </div>
              <small>{stats ? `Since ${formatDay(stats.points[0].day)}` : "Since launch"}</small>
            </div>

            {isError ? (
              <div className="pool-empty-state">Fee history needs an RPC that serves full-range logs. Try again later.</div>
            ) : isLoading || !stats ? (
              <div className="pool-empty-state">Loading distributions…</div>
            ) : mode === "usd" ? (
              <FeesChart
                ariaLabel="Trailing 7-day fees in USD, daily since launch"
                formatTick={(v) => formatUsd(v, 0)}
                formatValue={(v) => formatUsd(v)}
                points={usdPoints}
                valueLabel="7d fees"
              />
            ) : stakeHistory.isError ? (
              <div className="pool-empty-state">Could not load stake or price history. Try again later.</div>
            ) : aprLoading ? (
              <div className="pool-empty-state">Loading stake and price history…</div>
            ) : (
              <FeesChart
                ariaLabel="Trailing 7-day staker APR in percent, daily since launch"
                formatTick={(v) => formatPercent(v, Number.isInteger(v) ? 0 : 1)}
                formatValue={(v) => formatPercent(v)}
                points={aprPoints}
                valueLabel="7d staker APR"
              />
            )}

            {stats && (
              <div className="pool-vault-totals-grid fees-totals-grid">
                <div>
                  <span>All-time fees</span>
                  <strong>{formatUsd(stats.allTime)}</strong>
                </div>
                <div>
                  <span>Paid to stakers</span>
                  <strong>{formatUsd(stats.allTimeStaker)}</strong>
                </div>
                <div>
                  <span>Peak 7d</span>
                  <strong>{formatUsd(stats.peak.total)}</strong>
                </div>
                <div>
                  <span>Distributions</span>
                  <strong>{stats.count}</strong>
                </div>
              </div>
            )}

            <p className="fees-note">
              {mode === "apr" &&
                "APR is the stakers' share of the trailing 7d fees, annualized, over the average value staked across sDIEM v1 and v2 in that window (DIEM priced from DefiLlama). "}
              Fees count on the day they are distributed. The June gap is the v2 splitter period: its
              100 USDC floor was never reached, so it distributed only once, at the v3 cutover.
            </p>

            {stats && weeklyIdx.length > 0 && (
              <details className="fees-table">
                <summary>Show as table</summary>
                <table>
                  <thead>
                    <tr>
                      <th>Week ending</th>
                      <th>7d fees</th>
                      <th>Stakers</th>
                      <th>Platform</th>
                      {aprSeries && <th>Staker APR</th>}
                    </tr>
                  </thead>
                  <tbody>
                    {weeklyIdx.map((i) => {
                      const p = stats.points[i];
                      const apr = aprSeries?.apr[i] ?? null;
                      return (
                        <tr key={p.day}>
                          <td>{formatDay(p.day)}</td>
                          <td>{formatUsd(p.total)}</td>
                          <td>{formatUsd(p.staker)}</td>
                          <td>{formatUsd(p.platform)}</td>
                          {aprSeries && <td>{apr !== null ? formatPercent(apr) : "—"}</td>}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </details>
            )}
          </section>
        </div>
      </div>
    </>
  );
}
