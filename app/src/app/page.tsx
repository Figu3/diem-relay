"use client";

import { Header } from "@/components/Header";
import { PortfolioSummary } from "@/components/PortfolioSummary";
import { SDiemCard } from "@/components/SDiemCard";

export const dynamic = "force-dynamic";

export default function Home() {
  return (
    <div className="mx-auto min-h-screen max-w-5xl">
      <Header />
      <PortfolioSummary />

      <div className="grid gap-6 px-6 pb-12 md:grid-cols-1 md:max-w-lg md:mx-auto">
        <SDiemCard />
      </div>
    </div>
  );
}
