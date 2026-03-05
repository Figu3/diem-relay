"use client";

import { useEffect } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { sDiemAbi } from "@/config/abis";
import { SDIEM_ADDRESS } from "@/config/contracts";

export function useClaimReward() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const claim = () => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "claimReward",
    });
  };

  return { claim, isPending, isConfirming, isSuccess, error, hash, reset };
}
