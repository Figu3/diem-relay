"use client";

import { useReadContracts, useAccount } from "wagmi";
import { type Address } from "viem";
import { erc20Abi } from "@/config/abis";
import { DIEM_TOKEN } from "@/config/contracts";

const contract = { address: DIEM_TOKEN, abi: erc20Abi } as const;

export function useDiemToken(spender?: Address) {
  const { address } = useAccount();

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      ...(address
        ? [
            { ...contract, functionName: "balanceOf" as const, args: [address] as const },
            ...(spender
              ? [
                  {
                    ...contract,
                    functionName: "allowance" as const,
                    args: [address, spender] as const,
                  },
                ]
              : []),
          ]
        : []),
    ],
    query: {
      enabled: !!address,
      refetchInterval: 15_000,
    },
  });

  const get = <T,>(index: number): T | undefined =>
    data?.[index]?.status === "success"
      ? (data[index].result as T)
      : undefined;

  return {
    balance: get<bigint>(0) ?? 0n,
    allowance: spender ? (get<bigint>(1) ?? 0n) : 0n,
    isLoading,
    refetch,
  };
}
