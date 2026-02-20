import { config } from "./config";

const VENICE_BASE = config.veniceBaseUrl;

/**
 * Forward a chat completion request to Venice API.
 * Returns the raw Venice response so we can extract usage data from it.
 */
export async function forwardChatCompletion(body: ChatCompletionRequest): Promise<VeniceResponse> {
  // Force streaming off for Phase 0 — we need the full response to meter tokens.
  // Phase 1 will support streaming with chunk-level metering.
  const payload = { ...body, stream: false };

  const res = await fetch(`${VENICE_BASE}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.veniceApiKey}`,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const errorBody = await res.text();
    return {
      ok: false,
      status: res.status,
      error: errorBody,
      veniceBalanceDiem: res.headers.get("x-venice-balance-diem"),
      veniceBalanceUsd: res.headers.get("x-venice-balance-usd"),
    };
  }

  const data = (await res.json()) as OpenAIChatResponse;

  return {
    ok: true,
    status: 200,
    data,
    usage: data.usage
      ? {
          promptTokens: data.usage.prompt_tokens,
          completionTokens: data.usage.completion_tokens,
          totalTokens: data.usage.total_tokens,
        }
      : undefined,
    veniceBalanceDiem: res.headers.get("x-venice-balance-diem"),
    veniceBalanceUsd: res.headers.get("x-venice-balance-usd"),
  };
}

/**
 * List available models from Venice API.
 */
export async function listModels(): Promise<{ ok: boolean; data?: unknown; error?: string }> {
  const res = await fetch(`${VENICE_BASE}/models`, {
    headers: { Authorization: `Bearer ${config.veniceApiKey}` },
  });

  if (!res.ok) {
    return { ok: false, error: await res.text() };
  }
  return { ok: true, data: await res.json() };
}

// ── Types ──

export interface ChatCompletionRequest {
  model: string;
  messages: Array<{ role: string; content: string }>;
  temperature?: number;
  max_tokens?: number;
  stream?: boolean;
  [key: string]: unknown;
}

interface OpenAIChatResponse {
  id: string;
  object: string;
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: { role: string; content: string };
    finish_reason: string;
  }>;
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

export interface VeniceResponse {
  ok: boolean;
  status: number;
  data?: OpenAIChatResponse;
  error?: string;
  usage?: {
    promptTokens: number;
    completionTokens: number;
    totalTokens: number;
  };
  veniceBalanceDiem: string | null;
  veniceBalanceUsd: string | null;
}
