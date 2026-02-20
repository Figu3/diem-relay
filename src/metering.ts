import { config, getModelPricing } from "./config";
import { getBorrower, recordUsage } from "./db";

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

/**
 * Check if borrower can afford this request (pre-flight).
 * Called before proxying to Venice.
 * We do a rough estimate based on model — actual cost is computed after response.
 */
export function preflightCheck(borrower: string, model: string): { allowed: boolean; error?: string } {
  const b = getBorrower(borrower);
  if (!b) return { allowed: false, error: "Borrower not found" };
  if (!b.active) return { allowed: false, error: "Account suspended" };
  if (b.balance_usd <= 0) return { allowed: false, error: "Insufficient balance" };

  // Check daily limit
  const now = Math.floor(Date.now() / 1000);
  const dayStart = now - (now % 86400);
  const dailySpent = b.daily_reset >= dayStart ? b.daily_spent : 0;
  if (dailySpent >= config.maxDailySpendUsd) {
    return { allowed: false, error: "Daily spending limit reached" };
  }

  return { allowed: true };
}

/**
 * Compute cost and record usage after a successful Venice API response.
 * Returns the cost breakdown so we can include it in response headers.
 */
export function meterUsage(borrower: string, usage: UsageData): MeteringResult {
  const pricing = getModelPricing(usage.model);

  // Venice cost (what Venice charges at list price)
  const inputCost = (usage.promptTokens / 1_000_000) * pricing.inputPer1M;
  const outputCost = (usage.completionTokens / 1_000_000) * pricing.outputPer1M;
  const costUsd = inputCost + outputCost;

  // What we charge borrower (discounted)
  const chargedUsd = costUsd * config.discountRate;

  // Protocol's cut
  const protocolFee = chargedUsd * (config.protocolFeeBps / 10_000);

  // Check borrower has enough balance
  const b = getBorrower(borrower);
  if (!b || b.balance_usd < chargedUsd) {
    return {
      allowed: false,
      costUsd,
      chargedUsd,
      protocolFee,
      error: "Insufficient balance for this request",
    };
  }

  // Record usage (deducts from balance)
  recordUsage({
    borrower,
    model: usage.model,
    promptTokens: usage.promptTokens,
    completionTokens: usage.completionTokens,
    costUsd,
    chargedUsd,
    protocolFee,
    requestId: usage.requestId,
  });

  return { allowed: true, costUsd, chargedUsd, protocolFee };
}
