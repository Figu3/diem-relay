"use client";

import { useReadContracts, useAccount } from "wagmi";
import { parseUnits, zeroAddress } from "viem";
import { csDiemAbi } from "@/config/abis";
import { CSDIEM_ADDRESS, DIEM_DECIMALS } from "@/config/contracts";

const ONE_SHARE = parseUnits("1", DIEM_DECIMALS);

export const isCSDiemDeployed = CSDIEM_ADDRESS !== zeroAddress;

export function useCSDiem() {
  const { address } = useAccount();
  const user = address ?? zeroAddress;

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "totalAssets" },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "totalSupply" },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "convertToAssets", args: [ONE_SHARE] },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "paused" },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "balanceOf", args: [user] },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "redemptionRequests", args: [user] },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "canCompleteRedeem", args: [user] },
      { address: CSDIEM_ADDRESS, abi: csDiemAbi, functionName: "WITHDRAWAL_DELAY" },
    ],
    query: { enabled: isCSDiemDeployed, refetchInterval: 15_000 },
  });

  const get = <T,>(index: number): T | undefined =>
    data?.[index]?.status === "success"
      ? (data[index].result as T)
      : undefined;

  const userShares = address ? (get<bigint>(4) ?? 0n) : 0n;
  const sharePrice = get<bigint>(2) ?? ONE_SHARE;

  // userShares × sharePrice gives the DIEM-denominated value of the user's
  // position (sharePrice = DIEM per 1 csDIEM share, both 18-decimal scaled).
  const userAssetsValue =
    userShares > 0n ? (userShares * sharePrice) / ONE_SHARE : 0n;

  // redemptionRequests returns a tuple [assets, shares, requestedAt].
  const redemption = get<readonly [bigint, bigint, bigint]>(5) ?? [0n, 0n, 0n];

  return {
    deployed: isCSDiemDeployed,
    totalAssets: get<bigint>(0) ?? 0n,
    totalSupply: get<bigint>(1) ?? 0n,
    sharePrice,
    paused: get<boolean>(3) ?? false,
    userShares,
    userAssetsValue,
    pendingRedemption: {
      assets: redemption[0],
      shares: redemption[1],
      requestedAt: redemption[2],
    },
    canCompleteRedeem: get<boolean>(6) ?? false,
    withdrawalDelay: get<bigint>(7) ?? 0n,
    isLoading,
    refetch,
  };
}
