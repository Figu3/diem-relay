"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { parseAbiItem, zeroAddress } from "viem";
import { DIEM_TOKEN, SDIEM_V1_DEPLOYMENT, SDIEM_V2_DEPLOYMENT } from "@/config/contracts";
import { type StakeChange } from "@/lib/fees";

// Base produces a block every 2 seconds, so a log's timestamp follows from
// its block number and one reference block — no getBlock per log.
const BASE_BLOCK_SECONDS = 2n;

const STAKED = parseAbiItem("event Staked(address indexed user, uint256 amount)");
const REQUESTED = parseAbiItem("event WithdrawalRequested(address indexed user, uint256 amount)");
const CANCELLED = parseAbiItem("event WithdrawalCancelled(address indexed user, uint256 amount)");
const TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

const LLAMA_KEY = `base:${DIEM_TOKEN}`;

export interface StakeHistory {
  changes: StakeChange[];
  /** Daily DIEM prices from DefiLlama, oldest first. */
  prices: { timestamp: number; price: number }[];
}

/**
 * Inputs for the historical staker APR: every change to total staked DIEM
 * since launch, plus daily DIEM prices.
 *
 * sDIEM v1 tracks `totalStaked` directly: Staked adds, WithdrawalRequested
 * subtracts (including the bulk-exit path), WithdrawalCancelled adds back.
 * sDIEM v2's `totalStaked()` is its ERC-20 supply, so mints and burns are
 * the changes. Both reconcile exactly with on-chain `totalStaked()`.
 */
export function useStakeHistory(enabled: boolean) {
  const client = usePublicClient();

  return useQuery({
    queryKey: ["stake-history"],
    enabled: enabled && !!client,
    staleTime: 600_000,
    refetchInterval: 600_000,
    queryFn: async (): Promise<StakeHistory> => {
      if (!client) return { changes: [], prices: [] };

      const v1 = SDIEM_V1_DEPLOYMENT;
      const v2 = SDIEM_V2_DEPLOYMENT;
      const latest = await client.getBlock();
      const timestampOf = (blockNumber: bigint | null) =>
        Number(latest.timestamp - (latest.number - (blockNumber ?? latest.number)) * BASE_BLOCK_SECONDS);

      const priceStart = timestampOf(v1.fromBlock);
      const priceSpan = Math.ceil((Number(latest.timestamp) - priceStart) / 86_400) + 1;

      const [staked, requested, cancelled, minted, burned, prices] = await Promise.all([
        client.getLogs({ address: v1.address, event: STAKED, fromBlock: v1.fromBlock }),
        client.getLogs({ address: v1.address, event: REQUESTED, fromBlock: v1.fromBlock }),
        client.getLogs({ address: v1.address, event: CANCELLED, fromBlock: v1.fromBlock }),
        client.getLogs({ address: v2.address, event: TRANSFER, args: { from: zeroAddress }, fromBlock: v2.fromBlock }),
        client.getLogs({ address: v2.address, event: TRANSFER, args: { to: zeroAddress }, fromBlock: v2.fromBlock }),
        fetchDailyPrices(priceStart, priceSpan),
      ]);

      const change = (blockNumber: bigint | null, amount: bigint | undefined, sign: 1n | -1n): StakeChange => ({
        timestamp: timestampOf(blockNumber),
        delta: sign * (amount ?? 0n),
      });

      return {
        changes: [
          ...staked.map((log) => change(log.blockNumber, log.args.amount, 1n)),
          ...requested.map((log) => change(log.blockNumber, log.args.amount, -1n)),
          ...cancelled.map((log) => change(log.blockNumber, log.args.amount, 1n)),
          ...minted.map((log) => change(log.blockNumber, log.args.value, 1n)),
          ...burned.map((log) => change(log.blockNumber, log.args.value, -1n)),
        ],
        prices,
      };
    },
  });
}

async function fetchDailyPrices(start: number, span: number) {
  const res = await fetch(`https://coins.llama.fi/chart/${LLAMA_KEY}?start=${start}&span=${span}&period=1d`);
  if (!res.ok) throw new Error(`llama ${res.status}`);
  const json = (await res.json()) as {
    coins: Record<string, { prices: { timestamp: number; price: number }[] }>;
  };
  return json.coins?.[LLAMA_KEY]?.prices ?? [];
}
