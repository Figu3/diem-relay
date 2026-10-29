"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { parseAbiItem } from "viem";
import { REVENUE_SPLITTER_HISTORY } from "@/config/contracts";
import { type Distribution } from "@/lib/fees";

const DISTRIBUTED_EVENT = parseAbiItem(
  "event Distributed(address indexed caller, uint256 platformCut, uint256 stakerCut, uint256 timestamp)"
);

/**
 * Every `Distributed` event from every RevenueSplitter since launch — one
 * full-range eth_getLogs per splitter (a few hundred events in total).
 * Alchemy serves the whole range; RPCs with a block-range cap (the
 * mainnet.base.org fallback) reject it and the page shows an error instead.
 */
export function useFeeHistory() {
  const client = usePublicClient();

  return useQuery({
    queryKey: ["fee-history"],
    enabled: !!client,
    // Distributions land once a day — no need to poll like the live reads.
    staleTime: 600_000,
    refetchInterval: 600_000,
    queryFn: async (): Promise<Distribution[]> => {
      if (!client) return [];
      const batches = await Promise.all(
        REVENUE_SPLITTER_HISTORY.map(({ address, fromBlock }) =>
          client.getLogs({ address, event: DISTRIBUTED_EVENT, fromBlock, toBlock: "latest" })
        )
      );
      return batches.flat().map((log) => ({
        timestamp: Number(log.args.timestamp ?? 0n),
        platform: log.args.platformCut ?? 0n,
        staker: log.args.stakerCut ?? 0n,
      }));
    },
  });
}
