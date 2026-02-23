import { config, getModelPricing } from "./config";
import { getBorrower, getDailySpent, reserveBalance, refundReservation, settleUsage } from "./db";

export interface UsageData {
  model: string;
  promptTokens: number;
  completionTokens: number;
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
 * generous token estimate.
 */
function estimateMaxCost(model: string): number {
  const pricing = getModelPricing(model);
  // Conservative estimate: 4K prompt + 4K completion (most requests are much smaller)
  const estimatedPromptCost = (4_000 / 1_000_000) * pricing.inputPer1M;
  const estimatedOutputCost = (4_000 / 1_000_000) * pricing.outputPer1M;
  const estimatedCost = (estimatedPromptCost + estimatedOutputCost) * config.discountRate;
  // Floor at $0.01 to avoid reserving nothing on cheap models
  return Math.max(estimatedCost, 0.01);
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
 * Computes the real cost, refunds the difference from the reservation,
 * and records the usage log.
 */
export function meterUsage(borrower: string, usage: UsageData, reservedUsd: number): MeteringResult {
  const pricing = getModelPricing(usage.model);

  // Venice cost (what Venice charges at list price)
  const inputCost = (usage.promptTokens / 1_000_000) * pricing.inputPer1M;
  const outputCost = (usage.completionTokens / 1_000_000) * pricing.outputPer1M;
  const costUsd = inputCost + outputCost;

  // What we charge borrower (discounted)
  const chargedUsd = costUsd * config.discountRate;

  // Protocol's cut
  const protocolFee = chargedUsd * (config.protocolFeeBps / 10_000);

  // Settle: refund difference and record usage
  settleUsage({
    borrower,
    model: usage.model,
    promptTokens: usage.promptTokens,
    completionTokens: usage.completionTokens,
    costUsd,
    chargedUsd,
    protocolFee,
    requestId: usage.requestId,
    reservedUsd,
  });

  return { allowed: true, costUsd, chargedUsd, protocolFee };
}
