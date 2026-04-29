"use client";

import { useState } from "react";
import type { ReactNode } from "react";

interface Tab {
  label: string;
  content: ReactNode;
}

interface DepositWithdrawTabsProps {
  // Originally fixed at 2 tabs (Stake/Withdraw); relaxed to N to support
  // the optional csDIEM Wrap tab without forking the component.
  tabs: readonly Tab[];
}

export function DepositWithdrawTabs({ tabs }: DepositWithdrawTabsProps) {
  const [active, setActive] = useState(0);

  return (
    <div className="mt-4 rounded-xl border border-border bg-card-inner p-4">
      <div className="mb-3 flex gap-1 rounded-lg bg-surface p-0.5">
        {tabs.map((tab, i) => (
          <button
            key={tab.label}
            onClick={() => setActive(i)}
            className={`flex-1 rounded-md py-1.5 text-xs font-medium transition ${
              active === i
                ? "bg-accent text-black"
                : "text-[#888] hover:text-gray-200"
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>
      {tabs[active].content}
    </div>
  );
}
