import { config, getModelPricing } from "./config";
import { getBorrower, getDailySpent, reserveBalance, refundReservation, settleUsage } from "./db";

export interface UsageData {
  model: string;
  promptTokens: number;
  completionTokens: number;
  cacheTokens: number;
  requestId?: string;
}

export interface MeteringResult {
  allowed: boolean;
  costUsd: number;
  chargedUsd: number;
  protocolFee: number;
  error?: string;
}

export interface PreflightResult {
  allowed: boolean;
  reservedUsd: number;
  error?: string;
}

/**
 * Estimate the max cost for a request (used for pre-flight reservation).
 * Uses a conservative upper bound based on model's output pricing and a
 * generous token estimate. No discount applied — reserves at full list price
 * so we never under-reserve.
 */
function estimateMaxCost(model: string): number {
  const pricing = getModelPricing(model);
  // Conservative estimate: 4K prompt + 4K completion + 2K cache reads
  const estimatedPromptCost = (4_000 / 1_000_000) * pricing.inputPer1M;
  const estimatedOutputCost = (4_000 / 1_000_000) * pricing.outputPer1M;
  const estimatedCacheCost = (2_000 / 1_000_000) * pricing.cachePer1M;
  const estimatedCost = estimatedPromptCost + estimatedOutputCost + estimatedCacheCost;
  // Floor at $0.01 to avoid reserving nothing on cheap models
  return Math.max(estimatedCost, 0.01);
}

/**
 * Compute actual cost from Venice usage data.
 * Venice list price = what Venice would charge. This is the reference price
 * that borrowers bought credits against at a discount.
 */
function computeCost(usage: UsageData): number {
  const pricing = getModelPricing(usage.model);
  const inputCost = (usage.promptTokens / 1_000_000) * pricing.inputPer1M;
  const outputCost = (usage.completionTokens / 1_000_000) * pricing.outputPer1M;
  const cacheCost = (usage.cacheTokens / 1_000_000) * pricing.cachePer1M;
  return inputCost + outputCost + cacheCost;
}

/**
 * H-1: Pre-flight check that atomically reserves balance.
 * Called before proxying to Venice. If this returns allowed=true,
 * the estimated cost has been deducted from the borrower's balance.
 * The caller MUST call settleOrRefund() after Venice responds.
 */
export function preflightCheck(borrower: string, model: string): PreflightResult {
  const b = getBorrower(borrower);
  if (!b) return { allowed: false, reservedUsd: 0, error: "Borrower not found" };
  if (!b.active) return { allowed: false, reservedUsd: 0, error: "Account suspended" };
  if (b.balance_usd <= 0) return { allowed: false, reservedUsd: 0, error: "Insufficient balance" };

  // M-5: Use shared daily reset logic
  const dailySpent = getDailySpent(borrower);
  if (dailySpent >= config.maxDailySpendUsd) {
    return { allowed: false, reservedUsd: 0, error: "Daily spending limit reached" };
  }

  // H-1: Atomically reserve estimated cost
  const estimatedCost = estimateMaxCost(model);
  const reserved = reserveBalance(borrower, estimatedCost);
  if (!reserved) {
    return { allowed: false, reservedUsd: 0, error: "Insufficient balance for estimated cost" };
  }

  return { allowed: true, reservedUsd: estimatedCost };
}

/**
 * Refund a reservation when Venice call fails.
 */
export function refundPreflight(borrower: string, reservedUsd: number): void {
  if (reservedUsd > 0) {
    refundReservation(borrower, reservedUsd);
  }
}

/**
 * H-1: Settle actual usage after a successful Venice API response.
 * Computes the real cost at Venice list price, then charges the borrower
 * at that same list price (the discount was already applied at purchase time
 * when credits were bought). Refunds the difference from the reservation.
 */
export function meterUsage(borrower: string, usage: UsageData, reservedUsd: number): MeteringResult {
  // Venice list price cost
  const costUsd = computeCost(usage);

  // Charge at list price — the borrower's discount was baked into the credit purchase.
  // E.g., borrower paid $0.85 for $1.00 of credits. When they use $0.05 of Venice compute,
  // we deduct $0.05 from their credit balance. Their effective cost was $0.05 * 0.85 = $0.0425.
  const chargedUsd = costUsd;

  // Protocol's cut
  const protocolFee = chargedUsd * (config.protocolFeeBps / 10_000);

  // Settle: refund difference and record usage
  settleUsage({
    borrower,
    model: usage.model,
    promptTokens: usage.promptTokens,
    completionTokens: usage.completionTokens,
    cacheTokens: usage.cacheTokens,
    costUsd,
    chargedUsd,
    protocolFee,
    requestId: usage.requestId,
    reservedUsd,
  });

  return { allowed: true, costUsd, chargedUsd, protocolFee };
}
