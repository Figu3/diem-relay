"use client";

import { useEffect } from "react";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { sDiemAbi } from "@/config/abis";
import { SDIEM_ADDRESS } from "@/config/contracts";

export function useRequestWithdraw() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const requestWithdraw = (amount: bigint) => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "requestWithdraw",
      args: [amount],
    });
  };

  return { requestWithdraw, isPending, isConfirming, isSuccess, error, hash, reset };
}

export function useCompleteWithdraw() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const completeWithdraw = () => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "completeWithdraw",
    });
  };

  return { completeWithdraw, isPending, isConfirming, isSuccess, error, hash, reset };
}

export function useCancelWithdraw() {
  const queryClient = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) queryClient.invalidateQueries();
  }, [isSuccess, queryClient]);

  const cancelWithdraw = () => {
    writeContract({
      address: SDIEM_ADDRESS,
      abi: sDiemAbi,
      functionName: "cancelWithdraw",
    });
  };

  return { cancelWithdraw, isPending, isConfirming, isSuccess, error, hash, reset };
}
