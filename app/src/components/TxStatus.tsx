"use client";

import { shortenHash } from "@/lib/format";

interface TxStatusProps {
  isPending: boolean;
  isConfirming: boolean;
  isSuccess: boolean;
  error: Error | null;
  hash?: `0x${string}`;
  onReset?: () => void;
}

const BASESCAN = "https://basescan.org/tx/";

export function TxStatus({
  isPending,
  isConfirming,
  isSuccess,
  error,
  hash,
  onReset,
}: TxStatusProps) {
  if (!isPending && !isConfirming && !isSuccess && !error) return null;

  return (
    <div className="mt-2 rounded-lg bg-card-inner px-3 py-2 text-xs">
      {isPending && <span className="text-gray-400">Confirm in wallet...</span>}
      {isConfirming && (
        <span className="text-gold">
          Confirming...{" "}
          {hash && (
            <a
              href={`${BASESCAN}${hash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="underline"
            >
              {shortenHash(hash)}
            </a>
          )}
        </span>
      )}
      {isSuccess && (
        <span className="text-green-400">
          Success!{" "}
          {hash && (
            <a
              href={`${BASESCAN}${hash}`}
              target="_blank"
              rel="noopener noreferrer"
              className="underline"
            >
              {shortenHash(hash)}
            </a>
          )}
        </span>
      )}
      {error && (
        <div className="flex items-center justify-between">
          <span className="text-red-400 truncate max-w-[80%]">
            {error.message?.slice(0, 80) ?? "Transaction failed"}
          </span>
          {onReset && (
            <button
              onClick={onReset}
              className="ml-2 text-gray-400 hover:text-gray-200"
            >
              Dismiss
            </button>
          )}
        </div>
      )}
    </div>
  );
}
