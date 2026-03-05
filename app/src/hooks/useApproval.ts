"use client";

import { useEffect } from "react";
import {
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { type Address, maxUint256 } from "viem";
import { useQueryClient } from "@tanstack/react-query";
import { erc20Abi } from "@/config/abis";

export function useApproval(tokenAddress: Address, spenderAddress: Address) {
  const queryClient = useQueryClient();
  const {
    writeContract,
    data: hash,
    isPending,
    error,
    reset,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } =
    useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      queryClient.invalidateQueries();
    }
  }, [isSuccess, queryClient]);

  const approve = () => {
    writeContract({
      address: tokenAddress,
      abi: erc20Abi,
      functionName: "approve",
      args: [spenderAddress, maxUint256],
    });
  };

  return { approve, isPending, isConfirming, isSuccess, error, hash, reset };
}
