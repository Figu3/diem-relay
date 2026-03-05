"use client";

import { Header } from "@/components/Header";
import { PortfolioSummary } from "@/components/PortfolioSummary";
import { SDiemCard } from "@/components/SDiemCard";
import { CSDiemCard } from "@/components/CSDiemCard";

export default function Home() {
  return (
    <div className="mx-auto min-h-screen max-w-5xl">
      <Header />
      <PortfolioSummary />

      <div className="grid gap-6 px-6 pb-12 md:grid-cols-2">
        <SDiemCard />
        <CSDiemCard />
      </div>
    </div>
  );
}
