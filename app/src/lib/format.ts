import { formatUnits } from "viem";

export function formatDiem(value: bigint, decimals = 2): string {
  const formatted = formatUnits(value, 18);
  return Number(formatted).toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export function formatUsdc(value: bigint, decimals = 2): string {
  const formatted = formatUnits(value, 6);
  return Number(formatted).toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export function formatSharePrice(value: bigint): string {
  const formatted = formatUnits(value, 18);
  return Number(formatted).toLocaleString("en-US", {
    minimumFractionDigits: 4,
    maximumFractionDigits: 4,
  });
}

export function shortenHash(hash: string): string {
  return `${hash.slice(0, 6)}...${hash.slice(-4)}`;
}
