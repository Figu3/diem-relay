"use client";

import { useEffect } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { sDiemAbi } from "@/config/abis";
import { SDIEM_ADDRESS } from "@/config/contracts";

export function useExit() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const exit = () => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "exit",
    });
  };

  return { exit, isPending, isConfirming, isSuccess, error, hash, reset };
}
