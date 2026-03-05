"use client";

import { useEffect } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { sDiemAbi } from "@/config/abis";
import { SDIEM_ADDRESS } from "@/config/contracts";

export function useStake() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const stake = (amount: bigint) => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "stake",
      args: [amount],
    });
  };

  return { stake, isPending, isConfirming, isSuccess, error, hash, reset };
}
