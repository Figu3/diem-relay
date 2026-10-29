"use client";

import { useMemo } from "react";
import { Header } from "@/components/Header";
import { FeesChart } from "@/components/FeesChart";
import { useFeeHistory } from "@/hooks/useFeeHistory";
import { rollingFees } from "@/lib/fees";

function formatUsd(value: number) {
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 2 });
}

function formatDay(day: number) {
  return new Date(day * 1000).toLocaleDateString("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export default function FeesPage() {
  const { data: distributions, isLoading, isError } = useFeeHistory();

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

  // Weekly rows (newest first) for the table view.
  const weekly = stats ? stats.points.filter((_, i, all) => (all.length - 1 - i) % 7 === 0).reverse() : [];

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
              <span>7d fees</span>
              <strong>{stats ? formatUsd(stats.current.total) : "—"}</strong>
              <small>{stats ? `${formatUsd(stats.current.staker)} to stakers` : "Loading"}</small>
            </div>
          </section>

          <section className="pool-vault-totals" aria-label="Fees since launch">
            <div className="pool-vault-totals-header">
              <span>Trailing 7d fees</span>
              <small>{stats ? `Since ${formatDay(stats.points[0].day)}` : "Since launch"}</small>
            </div>

            {isError ? (
              <div className="pool-empty-state">Fee history needs an RPC that serves full-range logs. Try again later.</div>
            ) : isLoading || !stats ? (
              <div className="pool-empty-state">Loading distributions…</div>
            ) : (
              <FeesChart points={stats.points} />
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
              Fees count on the day they are distributed. The June gap is the v2 splitter period: its
              100 USDC floor was never reached, so it distributed only once, at the v3 cutover.
            </p>

            {weekly.length > 0 && (
              <details className="fees-table">
                <summary>Show as table</summary>
                <table>
                  <thead>
                    <tr>
                      <th>Week ending</th>
                      <th>7d fees</th>
                      <th>Stakers</th>
                      <th>Platform</th>
                    </tr>
                  </thead>
                  <tbody>
                    {weekly.map((p) => (
                      <tr key={p.day}>
                        <td>{formatDay(p.day)}</td>
                        <td>{formatUsd(p.total)}</td>
                        <td>{formatUsd(p.staker)}</td>
                        <td>{formatUsd(p.platform)}</td>
                      </tr>
                    ))}
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
