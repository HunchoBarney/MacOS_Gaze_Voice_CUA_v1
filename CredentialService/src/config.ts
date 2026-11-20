import type { Limits } from "./ledger.ts";

export interface Config {
  openAIKey: string;
  typeSafeKey: string;
  adminToken: string;
  openAIBaseURL: string;
  typeSafeURL: string;
  paused: boolean;
  realtimeModel: string;
  realtimeSecretSeconds: number;
  responsesModels: string[];
  jevModels: string[];
  maxOutputTokens: number;
  maxResponsesBytes: number;
  maxJevBytes: number;
  limits: Limits;
  prices: {
    realtimeSessionCents: number;
    responsesInputCentsPerMTok: number;
    responsesOutputCentsPerMTok: number;
    jevCallCents: number;
  };
}

/** Reads the Worker's secrets and vars. Throws when a required secret is missing. */
export function loadConfig(env: Record<string, unknown>): Config {
  const text = (name: string) => (typeof env[name] === "string" ? (env[name] as string).trim() : "");
  const secret = (name: string) => {
    const value = text(name);
    if (!value) throw new Error(`${name} is not set. Add it with: wrangler secret put ${name}`);
    return value;
  };
  const number = (name: string, fallback: number) => {
    const raw = text(name);
    if (!raw) return fallback;
    const value = Number(raw);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number.`);
    return value;
  };
  const list = (name: string, fallback: string[]) => {
    const raw = text(name);
    return raw ? raw.split(",").map((item) => item.trim()).filter(Boolean) : fallback;
  };
  return {
    openAIKey: secret("OPENAI_API_KEY"),
    typeSafeKey: secret("TYPESAFE_API_KEY"),
    adminToken: secret("ADMIN_TOKEN"),
    openAIBaseURL: (text("OPENAI_BASE_URL") || "https://api.openai.com").replace(/\/+$/, ""),
    typeSafeURL: text("TYPESAFE_URL") || "https://api.typesafe.ai/v1/systemone",
    paused: ["1", "true", "yes", "on"].includes(text("PAUSED").toLowerCase()),
    realtimeModel: text("REALTIME_MODEL") || "gpt-realtime-2.1",
    realtimeSecretSeconds: Math.min(Math.max(number("REALTIME_SECRET_SECONDS", 60), 10), 600),
    responsesModels: list("RESPONSES_MODELS", ["gpt-6.1-terra"]),
    jevModels: list("JEV_MODELS", ["jev-latest", "jev-1.14.0"]),
    maxOutputTokens: number("MAX_OUTPUT_TOKENS", 4_000),
    maxResponsesBytes: number("MAX_RESPONSES_BYTES", 20 * 1024 * 1024),
    maxJevBytes: number("MAX_JEV_BYTES", 32 * 1024 * 1024),
    limits: {
      perMinute: {
        realtime: number("REALTIME_PER_MINUTE", 6),
        responses: number("RESPONSES_PER_MINUTE", 20),
        jev: number("JEV_PER_MINUTE", 120),
      },
      installDailyCents: number("INSTALL_DAILY_CENTS", 100),
      globalDailyCents: number("GLOBAL_DAILY_CENTS", 2_000),
      registrationsPerIPPerDay: number("REGISTRATIONS_PER_IP_PER_DAY", 5),
      registrationsPerDay: number("REGISTRATIONS_PER_DAY", 500),
    },
    prices: {
      realtimeSessionCents: number("REALTIME_SESSION_CENTS", 25),
      responsesInputCentsPerMTok: number("RESPONSES_INPUT_CENTS_PER_MTOK", 200),
      responsesOutputCentsPerMTok: number("RESPONSES_OUTPUT_CENTS_PER_MTOK", 800),
      jevCallCents: number("JEV_CALL_CENTS", 0.5),
    },
  };
}
