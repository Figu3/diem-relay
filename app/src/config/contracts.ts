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

// Every splitter that has ever distributed revenue, oldest first, with its
// deploy block so fee history log scans start where each contract was born.
// v1 fed sDIEM v1, v2 (100 USDC floor) and v3 feed sDIEM v2.
export const REVENUE_SPLITTER_HISTORY: ReadonlyArray<{ address: Address; fromBlock: bigint }> = [
  { address: "0xd185138CEA135E60CA6E567BE53DEC81D89Ce7D6", fromBlock: 44_691_017n },
  { address: "0x96DAE834f7276D50a09149D938e998b1766AFCDa", fromBlock: 46_309_601n },
  { address: REVENUE_SPLITTER_ADDRESS, fromBlock: 47_276_576n },
];

// sDIEM deployments with their deploy blocks, for staked-DIEM history scans.
export const SDIEM_V1_DEPLOYMENT = {
  address: "0xdbF05AF4fdAA518AC9c4dc5aA49399b8dd0B4be2" as Address,
  fromBlock: 43_534_355n,
};
export const SDIEM_V2_DEPLOYMENT = { address: SDIEM_V2_ADDRESS, fromBlock: 46_251_126n };

export const SDIEM_ADDRESS = SDIEM_V2_ADDRESS;
export const CSDIEM_ADDRESS = CSDIEM_V2_ADDRESS;

export const DIEM_DECIMALS = 18;
export const USDC_DECIMALS = 6;
