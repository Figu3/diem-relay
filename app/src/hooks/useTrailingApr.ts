"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { type Abi } from "viem";
import { sDiemAbi, sDiemV2Abi } from "@/config/abis";
import { useContracts } from "./useContracts";

// Base mainnet has a fixed 2-second block time; good enough to locate the
// block ~N days back. The exact window is then measured from the real block
// timestamps, so this estimate only shifts the window edges, never the math.
const BLOCKS_PER_DAY = 43_200n;

interface TrailingWindow {
  /** rewardPerToken() growth over the window (raw Synthetix units). */
  delta: bigint;
  /** Actual elapsed seconds between the two sampled blocks. */
  windowSeconds: bigint;
}

export interface TrailingYield {
  week: TrailingWindow | null;
  month: TrailingWindow | null;
}

/**
 * Trailing 7d / 30d reward accrual, from rewardPerToken() sampled at
 * historical blocks. Needs an archive-capable RPC (Alchemy is; the
 * mainnet.base.org fallback may not be) — on failure, or when the contract
 * is younger than the window, that window resolves to null and the UI
 * hides it.
 */
export function useTrailingApr(): TrailingYield & { isLoading: boolean } {
  const client = usePublicClient();
  const { sdiem, isV2 } = useContracts();

  const abi: Abi = isV2 ? (sDiemV2Abi as unknown as Abi) : (sDiemAbi as unknown as Abi);

  const { data, isLoading } = useQuery({
    queryKey: ["trailing-apr", sdiem],
    enabled: !!client,
    // Archive reads are heavier than the 15s live polls — refresh every 5 min.
    staleTime: 300_000,
    refetchInterval: 300_000,
    queryFn: async (): Promise<TrailingYield> => {
      if (!client) return { week: null, month: null };

      const latest = await client.getBlock();
      const readAt = (blockNumber?: bigint) =>
        client.readContract({
          address: sdiem,
          abi,
          functionName: "rewardPerToken",
          blockNumber,
        }) as Promise<bigint>;

      const nowRpt = await readAt();

      const sample = async (days: bigint): Promise<TrailingWindow | null> => {
        const blockNumber = latest.number - days * BLOCKS_PER_DAY;
        if (blockNumber <= 0n) return null;
        try {
          const [pastRpt, pastBlock] = await Promise.all([
            readAt(blockNumber),
            client.getBlock({ blockNumber }),
          ]);
          if (nowRpt < pastRpt) return null;
          return {
            delta: nowRpt - pastRpt,
            windowSeconds: latest.timestamp - pastBlock.timestamp,
          };
        } catch {
          // Pre-deployment block (zero-data revert) or non-archive RPC.
          return null;
        }
      };

      const [week, month] = await Promise.all([sample(7n), sample(30n)]);
      return { week, month };
    },
  });

  return {
    week: data?.week ?? null,
    month: data?.month ?? null,
    isLoading,
  };
}
