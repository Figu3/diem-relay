// Hand-curated ABIs from Foundry output — only functions the UI needs.
// Using `as const` for full wagmi type inference.

export const sDiemAbi = [
  {
    type: "function",
    name: "totalStaked",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "earned",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "rewardRate",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "periodFinish",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "rewardPerToken",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "paused",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "diem",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "usdc",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "stake",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "requestWithdraw",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "completeWithdraw",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdrawalRequests",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "amount", type: "uint256" },
      { name: "requestedAt", type: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "claimReward",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "exit",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "cancelWithdraw",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "canCompleteWithdraw",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "WITHDRAWAL_DELAY",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "MIN_WITHDRAW",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "stakedInfos",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "stakedAmount", type: "uint256" },
      { name: "cooldownEndTimestamp", type: "uint256" },
      { name: "pendingUnstakeAmount", type: "uint256" },
    ],
    stateMutability: "view",
  },
] as const;

// ── csDIEM ──────────────────────────────────────────────────────────────
//
// ERC-4626 auto-compounding wrapper over sDIEM. Deposits accept DIEM;
// standard withdraw/redeem are DISABLED — exits use the async
// requestRedeem → 24h delay → completeRedeem flow (mirrors sDIEM/Venice).

export const csDiemAbi = [
  // ── Views ─────────────────────────────────────────────────────────────
  { type: "function", name: "totalAssets", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalSupply", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "balanceOf", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "convertToAssets", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "convertToShares", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "previewDeposit", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "previewRedeem", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "paused", inputs: [], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { type: "function", name: "WITHDRAWAL_DELAY", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalPendingRedemptions", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  {
    type: "function",
    name: "redemptionRequests",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "assets", type: "uint256" },
      { name: "shares", type: "uint256" },
      { name: "requestedAt", type: "uint256" },
    ],
    stateMutability: "view",
  },
  { type: "function", name: "canCompleteRedeem", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { type: "function", name: "pendingHarvest", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },

  // ── Mutations ─────────────────────────────────────────────────────────
  { type: "function", name: "deposit", inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "nonpayable" },
  { type: "function", name: "requestRedeem", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ name: "assets", type: "uint256" }], stateMutability: "nonpayable" },
  { type: "function", name: "completeRedeem", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "cancelRedeem", inputs: [], outputs: [], stateMutability: "nonpayable" },
] as const;

// ── sDIEM v2 ────────────────────────────────────────────────────────────
//
// Same staking/withdrawal surface as v1 (24h Venice-cooldown delay
// preserved), but a transferable ERC-20 with EIP-2612 permit. Reward
// accounting is checkpointed inside the `_update` hook so transfers
// preserve accrued rewards.

export const sDiemV2Abi = [
  { type: "function", name: "totalStaked", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalSupply", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "balanceOf", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "earned", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "rewardRate", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "periodFinish", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "rewardPerToken", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "paused", inputs: [], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { type: "function", name: "diem", inputs: [], outputs: [{ name: "", type: "address" }], stateMutability: "view" },
  { type: "function", name: "usdc", inputs: [], outputs: [{ name: "", type: "address" }], stateMutability: "view" },
  { type: "function", name: "stake", inputs: [{ name: "amount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "requestWithdraw", inputs: [{ name: "amount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "completeWithdraw", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "claimReward", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "exit", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "cancelWithdraw", inputs: [], outputs: [], stateMutability: "nonpayable" },
  {
    type: "function",
    name: "withdrawalRequests",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "amount", type: "uint256" },
      { name: "requestedAt", type: "uint256" },
    ],
    stateMutability: "view",
  },
  { type: "function", name: "canCompleteWithdraw", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { type: "function", name: "veniceCooldownEnd", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalPendingNotInitiated", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "WITHDRAWAL_DELAY", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "MIN_WITHDRAW", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
] as const;

// ── csDIEM v2 ───────────────────────────────────────────────────────────
//
// Canonical ERC-4626 wrapper over sDIEM v2 (`asset() == sDIEM v2`).
//   - Standard sync `redeem(shares, receiver, owner)` returns sDIEM v2.
//   - `depositDIEM(diemAmount, receiver)` zap stakes raw DIEM into sDIEM v2
//     internally and mints csDIEM v2 shares against it.

export const csDiemV2Abi = [
  // ── Views ─────────────────────────────────────────────────────────────
  { type: "function", name: "totalAssets", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalSupply", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "balanceOf", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "convertToAssets", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "convertToShares", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "previewDeposit", inputs: [{ name: "assets", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "previewRedeem", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "maxRedeem", inputs: [{ name: "owner", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "paused", inputs: [], outputs: [{ name: "", type: "bool" }], stateMutability: "view" },
  { type: "function", name: "pendingHarvest", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "asset", inputs: [], outputs: [{ name: "", type: "address" }], stateMutability: "view" },

  // ── Mutations ─────────────────────────────────────────────────────────
  // Standard ERC-4626 deposit (caller must hold sDIEM v2 and approve).
  { type: "function", name: "deposit", inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "nonpayable" },
  // Standard ERC-4626 sync redeem (returns sDIEM v2 to receiver).
  { type: "function", name: "redeem", inputs: [{ name: "shares", type: "uint256" }, { name: "receiver", type: "address" }, { name: "owner", type: "address" }], outputs: [{ name: "", type: "uint256" }], stateMutability: "nonpayable" },
  // Zap: deposit raw DIEM, vault stakes into sDIEM internally and mints
  // csDIEM v2 shares against the result.
  { type: "function", name: "depositDIEM", inputs: [{ name: "diemAmount", type: "uint256" }, { name: "receiver", type: "address" }], outputs: [{ name: "shares", type: "uint256" }], stateMutability: "nonpayable" },
] as const;

export const revenueSplitterAbi = [
  { type: "function", name: "totalStakerPaid", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "minAmount", inputs: [], outputs: [{ name: "", type: "uint256" }], stateMutability: "view" },
] as const;
