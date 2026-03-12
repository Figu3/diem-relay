export const config = {
  veniceApiKey: process.env.VENICE_API_KEY ?? "",
  veniceBaseUrl: "https://api.venice.ai/api/v1",

  port: Number(process.env.PORT ?? 3100),
  host: process.env.HOST ?? "0.0.0.0",

  adminSecret: process.env.ADMIN_SECRET ?? "",

  // ── Credit pricing ──────────────────────────────────────────────────

  /** Advance buy: fixed discount for next-day credits (0.85 = 15% off Venice list) */
  advanceDiscountRate: Number(process.env.ADVANCE_DISCOUNT_RATE ?? 0.85),

  /** Dutch auction: same-day credits discount range. Ramps from min→max over the day. */
  dutchAuction: {
    /** Discount at 00:00 UTC (start of day). 0.90 = 10% off */
    minDiscountRate: Number(process.env.DUTCH_MIN_DISCOUNT ?? 0.90),
    /** Discount at cutoff (23:00 UTC). 0.25 = 75% off */
    maxDiscountRate: Number(process.env.DUTCH_MAX_DISCOUNT ?? 0.25),
  },

  /** UTC hour after which same-day credit sales stop (23 = 23:00 UTC, 1h before expiry) */
  saleCutoffHourUtc: Number(process.env.SALE_CUTOFF_HOUR ?? 23),

  /** Protocol fee in basis points (1000 = 10%) taken from revenue */
  protocolFeeBps: Number(process.env.PROTOCOL_FEE_BPS ?? 1000),

  // ── Venice model pricing ────────────────────────────────────────────

  /** Venice pricing per 1M tokens (USD). Updated manually for Phase 0. */
  pricing: {
    defaultInputPer1M: 1.10,
    defaultOutputPer1M: 3.00,
    /** Default cache read price (if model doesn't specify one) */
    defaultCachePer1M: 0.10,
    models: {
      "qwen3-4b": { inputPer1M: 0.10, outputPer1M: 0.10, cachePer1M: 0.01 },
      "llama-3.3-70b": { inputPer1M: 0.60, outputPer1M: 0.60, cachePer1M: 0.06 },
      "deepseek-ai-DeepSeek-R1": { inputPer1M: 1.10, outputPer1M: 3.00, cachePer1M: 0.11 },
      "mistral-31-24b": { inputPer1M: 0.30, outputPer1M: 0.30, cachePer1M: 0.03 },
      "qwen3-235b-a22b-instruct-2507": { inputPer1M: 1.10, outputPer1M: 3.00, cachePer1M: 0.11 },
      "zai-org-glm-4.7": { inputPer1M: 1.10, outputPer1M: 3.00, cachePer1M: 0.11 },
      "venice-uncensored": { inputPer1M: 0.30, outputPer1M: 0.30, cachePer1M: 0.03 },
    } as Record<string, ModelPricing>,
  },

  /** Session JWT expiry */
  sessionTtlSeconds: 3600, // 1 hour

  /** Max daily spend per borrower in USD (rate limit) */
  maxDailySpendUsd: 50,
};

// ── Types ──

export interface ModelPricing {
  inputPer1M: number;
  outputPer1M: number;
  /** Price for prompt cache reads per 1M tokens. Typically ~10% of input price. */
  cachePer1M?: number;
}

export function getModelPricing(model: string): Required<ModelPricing> {
  const m = config.pricing.models[model];
  return {
    inputPer1M: m?.inputPer1M ?? config.pricing.defaultInputPer1M,
    outputPer1M: m?.outputPer1M ?? config.pricing.defaultOutputPer1M,
    cachePer1M: m?.cachePer1M ?? config.pricing.defaultCachePer1M,
  };
}

// ── Pricing helpers ──

/**
 * Get today's date string in YYYY-MM-DD UTC format.
 */
export function todayUtc(): string {
  return new Date().toISOString().slice(0, 10);
}

/**
 * Get tomorrow's date string in YYYY-MM-DD UTC format.
 */
export function tomorrowUtc(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Current UTC hour (0-23).
 */
export function currentUtcHour(): number {
  return new Date().getUTCHours();
}

/**
 * Whether same-day credit sales are currently allowed (before cutoff).
 */
export function isSameDaySaleOpen(): boolean {
  return currentUtcHour() < config.saleCutoffHourUtc;
}

/**
 * Dutch auction discount rate for same-day credits.
 * Linear interpolation: minDiscount at 00:00 → maxDiscount at cutoff hour.
 * Lower rate = bigger discount for the buyer.
 */
export function currentDutchAuctionRate(): number {
  const hour = currentUtcHour();
  const cutoff = config.saleCutoffHourUtc;
  if (hour >= cutoff) return config.dutchAuction.maxDiscountRate; // shouldn't sell, but return max discount

  const progress = hour / cutoff; // 0.0 at midnight → 1.0 at cutoff
  const { minDiscountRate, maxDiscountRate } = config.dutchAuction;
  // Interpolate: starts at minDiscountRate (small discount), ends at maxDiscountRate (big discount)
  return minDiscountRate + (maxDiscountRate - minDiscountRate) * progress;
}

export function validateConfig() {
  if (!config.veniceApiKey) throw new Error("VENICE_API_KEY is required");
  if (!config.adminSecret) throw new Error("ADMIN_SECRET is required");
}
