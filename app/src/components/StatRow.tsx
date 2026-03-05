"use client";

interface StatRowProps {
  label: string;
  value: string;
  sub?: string;
}

export function StatRow({ label, value, sub }: StatRowProps) {
  return (
    <div className="flex items-center justify-between py-2">
      <span className="text-sm text-gray-400">{label}</span>
      <div className="text-right">
        <span className="text-sm font-medium text-gray-100">{value}</span>
        {sub && <span className="ml-1.5 text-xs text-gray-500">{sub}</span>}
      </div>
    </div>
  );
}
