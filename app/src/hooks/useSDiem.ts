"use client";

import { useReadContracts, useAccount } from "wagmi";
import { zeroAddress } from "viem";
import { sDiemAbi } from "@/config/abis";
import { SDIEM_ADDRESS } from "@/config/contracts";

export function useSDiem() {
  const { address } = useAccount();
  const user = address ?? zeroAddress;

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "totalStaked" },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "rewardRate" },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "periodFinish" },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "paused" },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "balanceOf", args: [user] },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "earned", args: [user] },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "withdrawalRequests", args: [user] },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "canCompleteWithdraw", args: [user] },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "WITHDRAWAL_DELAY" },
      { address: SDIEM_ADDRESS, abi: sDiemAbi, functionName: "MIN_WITHDRAW" },
    ],
    query: { refetchInterval: 15_000 },
  });

  const get = <T,>(index: number): T | undefined =>
    data?.[index]?.status === "success"
      ? (data[index].result as T)
      : undefined;

  const withdrawalData = get<readonly [bigint, bigint]>(6);

  return {
    totalStaked: get<bigint>(0) ?? 0n,
    rewardRate: get<bigint>(1) ?? 0n,
    periodFinish: get<bigint>(2) ?? 0n,
    paused: get<boolean>(3) ?? false,
    userStaked: address ? (get<bigint>(4) ?? 0n) : 0n,
    earned: address ? (get<bigint>(5) ?? 0n) : 0n,
    pendingWithdrawAmount: address ? (withdrawalData?.[0] ?? 0n) : 0n,
    pendingWithdrawRequestedAt: address ? (withdrawalData?.[1] ?? 0n) : 0n,
    canComplete: address ? (get<boolean>(7) ?? false) : false,
    withdrawalDelay: get<bigint>(8) ?? 86400n,
    minWithdraw: get<bigint>(9) ?? 0n,
    isLoading,
    refetch,
  };
}
