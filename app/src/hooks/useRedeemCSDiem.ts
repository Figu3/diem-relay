"use client";

import { useEffect } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { csDiemAbi } from "@/config/abis";
import { CSDIEM_ADDRESS } from "@/config/contracts";

// Standard ERC-4626 redeem() is disabled in csDIEM (returns 0 from
// maxRedeem and reverts in _withdraw). Exits use the async flow:
//
//   requestRedeem(shares) → 24h delay → completeRedeem()
//                                    or cancelRedeem()  (re-mints at CURRENT rate)

function useTxAction() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } =
    useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  return { writeContract, hash, isPending, isConfirming, isSuccess, error, reset };
}

export function useRequestRedeemCSDiem() {
  const tx = useTxAction();
  const requestRedeem = (shares: bigint) => {
    tx.writeContract({
      address: CSDIEM_ADDRESS,
      abi: csDiemAbi,
      functionName: "requestRedeem",
      args: [shares],
    });
  };
  return { requestRedeem, ...tx };
}

export function useCompleteRedeemCSDiem() {
  const tx = useTxAction();
  const completeRedeem = () => {
    tx.writeContract({
      address: CSDIEM_ADDRESS,
      abi: csDiemAbi,
      functionName: "completeRedeem",
    });
  };
  return { completeRedeem, ...tx };
}

export function useCancelRedeemCSDiem() {
  const tx = useTxAction();
  const cancelRedeem = () => {
    tx.writeContract({
      address: CSDIEM_ADDRESS,
      abi: csDiemAbi,
      functionName: "cancelRedeem",
    });
  };
  return { cancelRedeem, ...tx };
}
