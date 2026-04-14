"use client";

import type { ReactNode } from "react";

interface VaultCardProps {
  title: string;
  subtitle: string;
  badge?: string;
  children: ReactNode;
}

export function VaultCard({ title, subtitle, badge, children }: VaultCardProps) {
  return (
    <div className="rounded-2xl border border-border bg-card p-5">
      <div className="mb-4 flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-gray-100">{title}</h2>
          <p className="text-xs text-[#555]">{subtitle}</p>
        </div>
        {badge && (
          <span className="rounded-full bg-accent/15 px-3 py-0.5 text-xs font-medium text-accent">
            {badge}
          </span>
        )}
      </div>
      <div className="space-y-1">{children}</div>
    </div>
  );
}
