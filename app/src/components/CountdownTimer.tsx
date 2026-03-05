"use client";

import { useState, useEffect } from "react";

interface CountdownTimerProps {
  periodFinish: bigint;
}

function formatTime(seconds: number): string {
  if (seconds <= 0) return "00:00:00";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return [h, m, s].map((v) => String(v).padStart(2, "0")).join(":");
}

export function CountdownTimer({ periodFinish }: CountdownTimerProps) {
  const [remaining, setRemaining] = useState(0);

  useEffect(() => {
    const update = () => {
      const now = Math.floor(Date.now() / 1000);
      const end = Number(periodFinish);
      setRemaining(Math.max(0, end - now));
    };
    update();
    const id = setInterval(update, 1000);
    return () => clearInterval(id);
  }, [periodFinish]);

  const expired = remaining <= 0;

  return (
    <div className="text-right">
      <span
        className={`font-mono text-sm ${expired ? "text-gray-500" : "text-gray-100"}`}
      >
        {formatTime(remaining)}
      </span>
      {expired && (
        <span className="ml-1.5 text-xs text-gray-500">expired</span>
      )}
    </div>
  );
}
