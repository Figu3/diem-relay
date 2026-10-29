"use client";

import { useEffect, useMemo, useRef, useState, type PointerEvent } from "react";

const HEIGHT = 300;
const PAD = { top: 16, right: 16, bottom: 30, left: 56 };

export interface ChartPoint {
  /** Unix seconds at 00:00 UTC. */
  day: number;
  /** Null leaves a gap in the line (e.g. no price or nothing staked). */
  value: number | null;
  /** Extra tooltip lines below the headline value. */
  details: string[];
}

interface FeesChartProps {
  points: ChartPoint[];
  /** Tooltip headline value. */
  formatValue: (value: number) => string;
  /** Y-axis tick label. */
  formatTick: (value: number) => string;
  /** Caption under the tooltip value, e.g. "7d fees". */
  valueLabel: string;
  ariaLabel: string;
}

function formatDay(day: number, opts: Intl.DateTimeFormatOptions) {
  return new Date(day * 1000).toLocaleDateString("en-US", { timeZone: "UTC", ...opts });
}

/** Round the max up to a 1/2/2.5/5 × 10^n step so ticks land on clean values. */
function niceTicks(max: number, count = 4) {
  if (max <= 0) return [0, 1];
  const raw = max / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? raw;
  const ticks: number[] = [];
  for (let v = 0; v <= max + step * 0.001; v += step) ticks.push(v);
  if (ticks[ticks.length - 1] < max) ticks.push(ticks[ticks.length - 1] + step);
  return ticks;
}

export function FeesChart({ points, formatValue, formatTick, valueLabel, ariaLabel }: FeesChartProps) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(720);
  const [hover, setHover] = useState<number | null>(null);

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const geometry = useMemo(() => {
    const innerW = Math.max(width - PAD.left - PAD.right, 1);
    const innerH = HEIGHT - PAD.top - PAD.bottom;
    const ticks = niceTicks(Math.max(...points.map((p) => p.value ?? 0), 0));
    const yMax = ticks[ticks.length - 1];
    const span = Math.max(points.length - 1, 1);
    const x = (i: number) => PAD.left + (i / span) * innerW;
    const y = (v: number) => PAD.top + innerH - (v / yMax) * innerH;

    // Split into runs of known values so nulls show as gaps, not drops to 0.
    const runs: number[][] = [];
    points.forEach((p, i) => {
      if (p.value === null) return;
      const run = runs[runs.length - 1];
      if (run && run[run.length - 1] === i - 1) run.push(i);
      else runs.push([i]);
    });
    const runLine = (run: number[]) =>
      run.map((i, k) => `${k ? "L" : "M"}${x(i).toFixed(1)},${y(points[i].value ?? 0).toFixed(1)}`).join("");
    const line = runs.map(runLine).join("");
    const area = runs
      .map((run) => `${runLine(run)}L${x(run[run.length - 1]).toFixed(1)},${y(0)}L${x(run[0]).toFixed(1)},${y(0)}Z`)
      .join("");

    // One label per month, at the 1st (or the first day shown).
    const months = points.flatMap((p, i) => {
      const date = new Date(p.day * 1000);
      return i === 0 || date.getUTCDate() === 1 ? [{ i, label: formatDay(p.day, { month: "short" }) }] : [];
    });
    // Skip the opening label if the 1st of the next month would collide with it.
    const monthTicks = months.filter((m, k) => !(k === 0 && months[1] && x(months[1].i) - x(m.i) < 56));

    return { innerW, ticks, x, y, line, area, monthTicks };
  }, [points, width]);

  const handleMove = (event: PointerEvent<SVGSVGElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const rel = (event.clientX - rect.left - PAD.left) / geometry.innerW;
    const i = Math.round(rel * (points.length - 1));
    setHover(Math.min(Math.max(i, 0), points.length - 1));
  };

  const active = hover !== null ? points[hover] : null;
  const activeX = hover !== null ? geometry.x(hover) : 0;

  return (
    <div className="fees-chart" ref={wrapRef}>
      <svg
        aria-label={ariaLabel}
        height={HEIGHT}
        onPointerLeave={() => setHover(null)}
        onPointerMove={handleMove}
        role="img"
        width={width}
      >
        {geometry.ticks.map((t) => (
          <g key={t}>
            <line className="fees-chart-grid" x1={PAD.left} x2={width - PAD.right} y1={geometry.y(t)} y2={geometry.y(t)} />
            <text className="fees-chart-axis" textAnchor="end" x={PAD.left - 8} y={geometry.y(t) + 4}>
              {formatTick(t)}
            </text>
          </g>
        ))}
        {geometry.monthTicks.map((m) => (
          <text className="fees-chart-axis" key={m.i} textAnchor="middle" x={geometry.x(m.i)} y={HEIGHT - 8}>
            {m.label}
          </text>
        ))}
        <path className="fees-chart-area" d={geometry.area} />
        <path className="fees-chart-line" d={geometry.line} />
        {active && (
          <>
            <line className="fees-chart-crosshair" x1={activeX} x2={activeX} y1={PAD.top} y2={HEIGHT - PAD.bottom} />
            {active.value !== null && (
              <circle className="fees-chart-dot" cx={activeX} cy={geometry.y(active.value)} r={5} />
            )}
          </>
        )}
      </svg>
      {active && (
        <div
          className="fees-chart-tooltip"
          style={{
            left: activeX,
            transform: `translateX(${activeX > width / 2 ? "calc(-100% - 12px)" : "12px"})`,
          }}
        >
          <span>{formatDay(active.day, { month: "short", day: "numeric", year: "numeric" })}</span>
          <strong>{active.value === null ? "—" : formatValue(active.value)}</strong>
          <small>{valueLabel}</small>
          {active.details.length > 0 && (
            <div className="fees-chart-tooltip-split">
              {active.details.map((line) => (
                <span key={line}>{line}</span>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
