"use client";

import { formatUnits } from "viem";

interface AmountInputProps {
  value: string;
  onChange: (v: string) => void;
  max: bigint;
  decimals?: number;
  symbol?: string;
  disabled?: boolean;
}

export function AmountInput({
  value,
  onChange,
  max,
  decimals = 18,
  symbol = "DIEM",
  disabled,
}: AmountInputProps) {
  const formatted = Number(formatUnits(max, decimals)).toLocaleString(
    undefined,
    { maximumFractionDigits: 4 },
  );

  return (
    <div className="rounded-lg bg-card-inner p-3">
      <div className="flex items-center gap-2">
        <input
          type="text"
          inputMode="decimal"
          placeholder="0.0"
          value={value}
          onChange={(e) => {
            const v = e.target.value;
            if (/^[0-9]*\.?[0-9]*$/.test(v)) onChange(v);
          }}
          disabled={disabled}
          className="w-full bg-transparent text-lg text-gray-100 outline-none placeholder:text-gray-600"
        />
        <button
          onClick={() => onChange(formatUnits(max, decimals))}
          disabled={disabled || max === 0n}
          className="shrink-0 rounded bg-gold/15 px-2 py-0.5 text-xs font-medium text-gold hover:bg-gold/25 disabled:opacity-40"
        >
          MAX
        </button>
      </div>
      <p className="mt-1 text-xs text-gray-500">
        Balance: {formatted} {symbol}
      </p>
    </div>
  );
}
