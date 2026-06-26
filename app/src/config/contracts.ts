import { type Address } from "viem";

export const DIEM_TOKEN = "0xf4d97f2da56e8c3098f3a8d538db630a2606a024" as Address;
export const USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;

// sDIEM: transferable ERC-20 + EIP-2612 permit, Synthetix rewards on _update.
// csDIEM: canonical ERC-4626 wrapper over sDIEM (asset() = sDIEM),
// synchronous redeem, maxRedeem == balanceOf, depositDIEM zap for raw DIEM.
// Override via NEXT_PUBLIC_SDIEM_V2_ADDRESS / NEXT_PUBLIC_CSDIEM_V2_ADDRESS.
export const SDIEM_V2_ADDRESS = (process.env.NEXT_PUBLIC_SDIEM_V2_ADDRESS ??
  "0x8065228a8156590A8BFca30678394e9db91f80Ee") as Address;
export const CSDIEM_V2_ADDRESS = (process.env.NEXT_PUBLIC_CSDIEM_V2_ADDRESS ??
  "0x78B8726929911044748374178CB2D417A54319e5") as Address;
export const REVENUE_SPLITTER_ADDRESS = "0x213c8d7434E2ae7AA1C392767c5120778D413215" as Address;

export const SDIEM_ADDRESS = SDIEM_V2_ADDRESS;
export const CSDIEM_ADDRESS = CSDIEM_V2_ADDRESS;

export const DIEM_DECIMALS = 18;
export const USDC_DECIMALS = 6;
