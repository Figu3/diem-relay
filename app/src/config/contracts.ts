import { type Address } from "viem";

export const DIEM_TOKEN = "0xf4d97f2da56e8c3098f3a8d538db630a2606a024" as Address;
export const USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;

// Deployed on Base mainnet — override via NEXT_PUBLIC_SDIEM_ADDRESS env var
export const SDIEM_ADDRESS = (process.env.NEXT_PUBLIC_SDIEM_ADDRESS ??
  "0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2") as Address;
export const CSDIEM_ADDRESS = (process.env.NEXT_PUBLIC_CSDIEM_ADDRESS ??
  "0x0000000000000000000000000000000000000000") as Address;

export const DIEM_DECIMALS = 18;
export const USDC_DECIMALS = 6;
