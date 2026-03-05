"use client";

import { useAccount } from "wagmi";
import { useSDiem } from "@/hooks/useSDiem";
import { useCSDiem } from "@/hooks/useCSDiem";
import { useDiemToken } from "@/hooks/useDiemToken";
import { formatDiem, formatUsdc } from "@/lib/format";

export function PortfolioSummary() {
  const { isConnected } = useAccount();
  const { userStaked, earned } = useSDiem();
  const { userAssetsValue } = useCSDiem();
  const { balance } = useDiemToken();

  if (!isConnected) return null;

  const stats = [
    { label: "Wallet", value: `${formatDiem(balance)} DIEM` },
    { label: "Staked (sDIEM)", value: `${formatDiem(userStaked)} DIEM` },
    { label: "Vault (csDIEM)", value: `${formatDiem(userAssetsValue)} DIEM` },
    { label: "USDC Earned", value: `${formatUsdc(earned)} USDC` },
  ];

  return (
    <div className="mx-6 mb-6 grid grid-cols-2 gap-3 rounded-xl border border-border bg-card p-4 sm:grid-cols-4">
      {stats.map((s) => (
        <div key={s.label}>
          <p className="text-xs text-gray-500">{s.label}</p>
          <p className="text-sm font-medium text-gray-100">{s.value}</p>
        </div>
      ))}
    </div>
  );
}
