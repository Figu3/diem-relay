export const config = {
  veniceApiKey: process.env.VENICE_API_KEY ?? "",
  veniceBaseUrl: "https://api.venice.ai/api/v1",

  port: Number(process.env.PORT ?? 3100),
  host: process.env.HOST ?? "0.0.0.0",

  adminSecret: process.env.ADMIN_SECRET ?? "",

  /** Borrowers pay this fraction of Venice's list price (0.85 = 15% discount) */
  discountRate: Number(process.env.DISCOUNT_RATE ?? 0.85),

  /** Protocol fee in basis points (1000 = 10%) taken from revenue */
  protocolFeeBps: Number(process.env.PROTOCOL_FEE_BPS ?? 1000),

  /** Venice pricing per 1M tokens (USD). Updated manually for Phase 0. */
  pricing: {
    // Defaults based on Venice docs — override per model if needed
    defaultInputPer1M: 1.10,
    defaultOutputPer1M: 3.00,
    models: {
      "qwen3-4b": { inputPer1M: 0.10, outputPer1M: 0.10 },
      "llama-3.3-70b": { inputPer1M: 0.60, outputPer1M: 0.60 },
      "deepseek-ai-DeepSeek-R1": { inputPer1M: 1.10, outputPer1M: 3.00 },
      "mistral-31-24b": { inputPer1M: 0.30, outputPer1M: 0.30 },
      "qwen3-235b-a22b-instruct-2507": { inputPer1M: 1.10, outputPer1M: 3.00 },
      "zai-org-glm-4.7": { inputPer1M: 1.10, outputPer1M: 3.00 },
      "venice-uncensored": { inputPer1M: 0.30, outputPer1M: 0.30 },
    } as Record<string, { inputPer1M: number; outputPer1M: number }>,
  },

  /** Session JWT expiry */
  sessionTtlSeconds: 3600, // 1 hour

  /** Max daily spend per borrower in USD (rate limit) */
  maxDailySpendUsd: 50,
} as const;

export function getModelPricing(model: string) {
  const m = config.pricing.models[model];
  if (m) return m;
  return {
    inputPer1M: config.pricing.defaultInputPer1M,
    outputPer1M: config.pricing.defaultOutputPer1M,
  };
}

export function validateConfig() {
  if (!config.veniceApiKey) throw new Error("VENICE_API_KEY is required");
  if (!config.adminSecret) throw new Error("ADMIN_SECRET is required");
}
