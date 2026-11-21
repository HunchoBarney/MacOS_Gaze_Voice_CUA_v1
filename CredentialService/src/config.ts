import type { Limits, Plans, Tier } from "./ledger.ts";

export interface Config {
  openAIKey: string;
  typeSafeKey: string;
  adminToken: string;
  openAIBaseURL: string;
  typeSafeURL: string;
  paused: boolean;
  realtimeModel: string;
  realtimeSecretSeconds: number;
  liveModel: string;
  maxLiveBytes: number;
  responsesModels: string[];
  jevModels: string[];
  maxOutputTokens: number;
  maxResponsesBytes: number;
  maxJevBytes: number;
  limits: Limits;
  prices: {
    realtimeSessionCents: number;
    liveSessionCents: number;
    responsesReserveCents: number;
    responsesInputCentsPerMTok: number;
    responsesOutputCentsPerMTok: number;
    jevCallCents: number;
  };
  metering: Plans & {
    enabled: boolean;
    standbyWeight: number;
    warnFraction: number;
    activeCentsPerMinute: number;
    pausedCentsPerMinute: number;
    graceSeconds: number;
  };
}

export const DEFAULT_TIERS: Record<string, Tier> = {
  jarvis: { liveMinutes: 300, tasks: 100, priceUSD: 30 },
  pro: { liveMinutes: 1000, tasks: 400, priceUSD: 100 },
};

/** Reads TIERS and DEFAULT_TIER. Throws when either is malformed. */
export function loadPlans(env: Record<string, unknown>): Plans {
  const raw = typeof env.TIERS === "string" ? env.TIERS.trim() : env.TIERS;
  const bad = new Error(
    "TIERS must be a JSON object of tiers, each { liveMinutes: number or null, tasks: whole number or null, priceUSD: number }.");
  let tiers: unknown = DEFAULT_TIERS;
  if (typeof raw === "string" && raw) {
    try { tiers = JSON.parse(raw); } catch { throw bad; }
  } else if (raw && typeof raw === "object") {
    tiers = raw;
  }
  const amount = (value: unknown, nullable: boolean) =>
    (nullable && value === null) || (typeof value === "number" && Number.isFinite(value) && value >= 0);
  if (!tiers || typeof tiers !== "object" || Array.isArray(tiers) || Object.keys(tiers).length === 0) throw bad;
  for (const tier of Object.values(tiers)) {
    const { liveMinutes, tasks, priceUSD } = (tier ?? {}) as Record<string, unknown>;
    if (!amount(liveMinutes, true) || !amount(tasks, true) || !(tasks === null || Number.isInteger(tasks))
      || !amount(priceUSD, false)) throw bad;
  }
  const defaultTier = typeof env.DEFAULT_TIER === "string" && env.DEFAULT_TIER.trim() ? env.DEFAULT_TIER.trim() : "jarvis";
  if (!Object.hasOwn(tiers, defaultTier)) throw new Error(`DEFAULT_TIER names no tier in TIERS: ${defaultTier}.`);
  return { tiers: tiers as Record<string, Tier>, defaultTier };
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
  const fraction = (name: string, fallback: number) => {
    const value = number(name, fallback);
    if (value > 1) throw new Error(`${name} must be a number from 0 to 1.`);
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
    liveModel: text("LIVE_MODEL") || "gpt-live-1.1",
    maxLiveBytes: number("MAX_LIVE_BYTES", 256 * 1024),
    responsesModels: list("RESPONSES_MODELS", ["gpt-6.1-terra"]),
    jevModels: list("JEV_MODELS", ["jev-latest", "jev-1.14.0"]),
    maxOutputTokens: number("MAX_OUTPUT_TOKENS", 4_000),
    maxResponsesBytes: number("MAX_RESPONSES_BYTES", 20 * 1024 * 1024),
    maxJevBytes: number("MAX_JEV_BYTES", 32 * 1024 * 1024),
    limits: {
      perMinute: {
        realtime: number("REALTIME_PER_MINUTE", 6),
        live: number("LIVE_PER_MINUTE", 6),
        responses: number("RESPONSES_PER_MINUTE", 20),
        jev: number("JEV_PER_MINUTE", 120),
      },
      installDailyCents: number("INSTALL_DAILY_CENTS", 100),
      globalDailyCents: number("GLOBAL_DAILY_CENTS", 500),
      registrationsPerIPPerDay: number("REGISTRATIONS_PER_IP_PER_DAY", 5),
      registrationsPerDay: number("REGISTRATIONS_PER_DAY", 500),
    },
    prices: {
      realtimeSessionCents: number("REALTIME_SESSION_CENTS", 5),
      liveSessionCents: number("LIVE_SESSION_CENTS", 8),
      responsesReserveCents: number("RESPONSES_RESERVE_CENTS", 5),
      responsesInputCentsPerMTok: number("RESPONSES_INPUT_CENTS_PER_MTOK", 200),
      responsesOutputCentsPerMTok: number("RESPONSES_OUTPUT_CENTS_PER_MTOK", 800),
      jevCallCents: number("JEV_CALL_CENTS", 0.5),
    },
    metering: {
      enabled: text("LIVE_METERING") === "1",
      ...loadPlans(env),
      standbyWeight: fraction("STANDBY_WEIGHT", 0.4),
      warnFraction: fraction("LIVE_WARN_FRACTION", 0.8),
      activeCentsPerMinute: number("LIVE_ACTIVE_CENTS_PER_MINUTE", 5),
      pausedCentsPerMinute: number("LIVE_PAUSED_CENTS_PER_MINUTE", 2),
      graceSeconds: number("CAP_GRACE_SECONDS", 60),
    },
  };
}
