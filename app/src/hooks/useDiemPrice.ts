"use client";

import { useQuery } from "@tanstack/react-query";
import { DIEM_TOKEN } from "@/config/contracts";

const LLAMA_KEY = `base:${DIEM_TOKEN}`;
const LLAMA_URL = `https://coins.llama.fi/prices/current/${LLAMA_KEY}`;

export function useDiemPrice(): { priceUsd: number | null; isLoading: boolean } {
  const { data, isLoading } = useQuery({
    queryKey: ["diem-price", DIEM_TOKEN],
    queryFn: async () => {
      const res = await fetch(LLAMA_URL);
      if (!res.ok) throw new Error(`llama ${res.status}`);
      const json = (await res.json()) as {
        coins: Record<string, { price: number }>;
      };
      const price = json.coins?.[LLAMA_KEY]?.price;
      return typeof price === "number" && price > 0 ? price : null;
    },
    refetchInterval: 60_000,
    staleTime: 30_000,
  });

  return { priceUsd: data ?? null, isLoading };
}
