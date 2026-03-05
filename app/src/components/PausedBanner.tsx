"use client";

export function PausedBanner() {
  return (
    <div className="rounded-lg border border-yellow-600/40 bg-yellow-900/20 px-4 py-2 text-center text-sm text-yellow-300">
      Contract is paused — deposits and withdrawals are temporarily disabled.
    </div>
  );
}
