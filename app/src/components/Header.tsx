"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  return (
    <header className="flex items-center justify-between px-6 py-4">
      <div className="flex items-center gap-1.5">
        <span className="font-mono text-sm font-bold text-accent">CheapTokens</span>
        <span className="font-mono text-sm font-bold text-[#555]">.ai</span>
        <span className="ml-2 rounded-full bg-[#e8a435] px-2 py-0.5 text-[10px] font-bold uppercase text-black">
          beta
        </span>
      </div>
      <ConnectButton
        showBalance={false}
        chainStatus="icon"
        accountStatus="address"
      />
    </header>
  );
}
