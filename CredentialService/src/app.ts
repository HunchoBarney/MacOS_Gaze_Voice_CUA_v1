import { Hono, type Context, type MiddlewareHandler } from "hono";
import type { Config } from "./config.ts";
import type { Denial, LedgerClient, Route } from "./ledger.ts";
import { PAUSED } from "./ledger.ts";

export interface Deps {
  config: Config;
  ledger: LedgerClient;
  upstream: (url: string, init: RequestInit) => Promise<Response>;
  clientIP: (c: Context) => string | undefined;
  now?: () => number;
}

type Env = { Variables: { installID: string; spentCents: number } };

const TOKEN = /^jv1_[A-Za-z0-9_-]{43}$/;
const RESPONSES_FIELDS_ALLOWED = new Set([
  "model", "input", "instructions", "reasoning", "max_output_tokens", "text", "store", "stream",
  "metadata", "temperature", "top_p", "truncation", "prompt_cache_key", "safety_identifier", "user",
]);
const LIVE_FIELDS_ALLOWED = new Set([
  "sdp", "instructions", "input", "voice", "idle_timeout_s", "wake_policy", "acknowledgement_delay_ms",
]);
const UNKNOWN_INSTALL: Denial = { status: 401, code: "unknown_install", message: "This install isn't registered." };

function fail(c: Context, denial: Denial): Response {
  if (denial.retryAfter !== undefined) c.header("Retry-After", String(denial.retryAfter));
  return c.json({ error: { code: denial.code, message: denial.message } }, denial.status as 400);
}

function upstreamFailure(status: number): Denial {
  return status === 429
    ? { status: 503, code: "upstream_busy", message: "The model provider is busy. Try again shortly.", retryAfter: 5 }
    : { status: 502, code: "upstream_error", message: `The model provider returned ${status}.` };
}

function bearer(c: Context): string {
  return /^Bearer\s+(\S+)$/i.exec(c.req.header("authorization") ?? "")?.[1] ?? "";
}

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

async function sha256Hex(text: string): Promise<string> {
  return [...(await sha256(text))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sameSecret(given: string, expected: string): Promise<boolean> {
  const [a, b] = await Promise.all([sha256(given), sha256(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return given.length > 0 && difference === 0;
}

/** The network a registration counts against: the address for IPv4, its /64 for IPv6. */
function network(ip: string): string {
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = [...left, ...Array(Math.max(8 - left.length - right.length, 0)).fill("0"), ...right];
  return groups.slice(0, 4).map((group) => parseInt(group, 16).toString(16)).join(":") + "::/64";
}

function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return "jv1_" + btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function readJSON(c: Context, maxBytes: number): Promise<{ denial: Denial } | { value: Record<string, unknown> }> {
  const tooLarge = { denial: { status: 413, code: "too_large", message: "The request is too large." } };
  if (Number(c.req.header("content-length") ?? 0) > maxBytes) return tooLarge;
  const bytes = await c.req.arrayBuffer();
  if (bytes.byteLength > maxBytes) return tooLarge;
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (value && typeof value === "object" && !Array.isArray(value)) return { value };
  } catch {}
  return { denial: { status: 400, code: "bad_request", message: "The request body must be a JSON object." } };
}

function tokens(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * The HTTP surface. Installs register for an opaque token, then mint
 * Realtime client secrets, open GPT-Live sessions and call Responses and
 * Jev through the service, which holds the owner's keys and never returns
 * them.
 */
export function createApp(deps: Deps) {
  const { config, ledger, upstream } = deps;
  const now = deps.now ?? Date.now;
  const app = new Hono<Env>();

  app.onError((_error, c) => fail(c, { status: 500, code: "internal", message: "The credential service hit an error." }));
  app.notFound((c) => fail(c, { status: 404, code: "not_found", message: "No such endpoint." }));

  app.get("/health", (c) => c.json({ ok: true }));

  app.use("/admin/*", async (c, next) => {
    if (!(await sameSecret(bearer(c), config.adminToken))) {
      return fail(c, { status: 401, code: "unauthorized", message: "Admin token required." });
    }
    await next();
  });
  app.post("/admin/pause", async (c) => {
    await ledger.setPaused(true);
    return c.json({ paused: true });
  });
  app.post("/admin/resume", async (c) => {
    await ledger.setPaused(false);
    return c.json({ paused: false });
  });
  for (const [action, revoked] of [["revoke", true], ["restore", false]] as const) {
    app.post(`/admin/installs/:id/${action}`, async (c) => {
      const found = await ledger.setRevoked({ installID: c.req.param("id"), revoked, now: now() });
      return found ? c.json({ installID: c.req.param("id"), revoked })
        : fail(c, { status: 404, code: "not_found", message: "No such install." });
    });
  }
  app.get("/admin/usage", async (c) => c.json(await ledger.usage(now())));

  app.use("/v1/*", async (c, next) => {
    if (config.paused) return fail(c, PAUSED);
    await next();
  });

  app.post("/v1/installs", async (c) => {
    const token = newToken();
    const installID = crypto.randomUUID();
    const denial = await ledger.register({
      installID,
      tokenHash: await sha256Hex(token),
      ipKey: await sha256Hex(`${config.adminToken}:${network(deps.clientIP(c) ?? "unknown")}`),
      limits: config.limits,
      now: now(),
    });
    if (denial) return fail(c, denial);
    return c.json({ installID, token }, 201);
  });

  /**
   * Admits an install for one call: reserves `reserveCents` before the
   * handler runs, then settles to what the handler recorded in
   * `spentCents`. A call that fails or is refused is refunded in full.
   */
  const admitted = (route: Route, reserveCents: number): MiddlewareHandler<Env> => async (c, next) => {
    const token = bearer(c);
    if (!TOKEN.test(token)) return fail(c, UNKNOWN_INSTALL);
    const admittedAt = now();
    const result = await ledger.admit({
      tokenHash: await sha256Hex(token), route, reserveCents, limits: config.limits, now: admittedAt,
    });
    if ("status" in result) return fail(c, result);
    c.set("installID", result.installID);
    c.set("spentCents", 0);
    try {
      await next();
    } finally {
      await ledger.charge({ installID: result.installID, cents: c.get("spentCents") - reserveCents, now: admittedAt });
    }
  };

  app.post("/v1/realtime/client_secret", admitted("realtime", config.prices.realtimeSessionCents), async (c) => {
    const reply = await upstream(`${config.openAIBaseURL}/v1/realtime/client_secrets`, {
      method: "POST",
      headers: { authorization: `Bearer ${config.openAIKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        expires_after: { anchor: "created_at", seconds: config.realtimeSecretSeconds },
        session: { type: "realtime", model: config.realtimeModel },
      }),
    });
    if (!reply.ok) return fail(c, upstreamFailure(reply.status));
    const secret = (await reply.json().catch(() => null)) as { value?: unknown; expires_at?: unknown } | null;
    if (typeof secret?.value !== "string") {
      return fail(c, { status: 502, code: "upstream_error", message: "The model provider returned no client secret." });
    }
    c.set("spentCents", config.prices.realtimeSessionCents);
    return c.json({ value: secret.value, expiresAt: secret.expires_at, model: config.realtimeModel });
  });

  /**
   * Opens a GPT-Live WebRTC session for the Mac's SDP offer and returns the
   * answer. The service fixes the model, client delegation (the app does
   * every action), no stored session and no Decisions triggers; the app
   * chooses only the conversation fields in LIVE_FIELDS_ALLOWED.
   */
  app.post("/v1/live/sessions", admitted("live", config.prices.liveSessionCents), async (c) => {
    const parsed = await readJSON(c, config.maxLiveBytes);
    if ("denial" in parsed) return fail(c, parsed.denial);
    const request = parsed.value;
    const field = Object.keys(request).find((name) => !LIVE_FIELDS_ALLOWED.has(name));
    if (field) return fail(c, { status: 400, code: "field_not_allowed", message: `\`${field}\` isn't allowed.` });
    if (typeof request.sdp !== "string" || !request.sdp.trim()) {
      return fail(c, { status: 400, code: "bad_request", message: "An SDP offer is required in `sdp`." });
    }
    const delegation: Record<string, unknown> = { type: "client" };
    if (request.acknowledgement_delay_ms !== undefined) delegation.acknowledgement_delay_ms = request.acknowledgement_delay_ms;
    const session: Record<string, unknown> = {
      model: config.liveModel,
      delegation,
      store: false,
      safety_identifier: c.get("installID"),
    };
    for (const name of ["instructions", "input", "idle_timeout_s", "wake_policy"]) {
      if (request[name] !== undefined) session[name] = request[name];
    }
    if (request.voice !== undefined) session.audio = { output: { voice: request.voice } };

    const reply = await upstream(`${config.openAIBaseURL}/v1/live/sessions`, {
      method: "POST",
      headers: { authorization: `Bearer ${config.openAIKey}`, "content-type": "application/json" },
      body: JSON.stringify({ session, transport: { type: "webrtc", sdp: request.sdp } }),
    });
    const text = await reply.text();
    if (reply.status === 400) return c.body(text, 400, { "content-type": "application/json" });
    if (!reply.ok) return fail(c, upstreamFailure(reply.status));
    let created: { session?: { id?: unknown }; transport?: { sdp?: unknown } } | undefined;
    try { created = JSON.parse(text); } catch {}
    if (typeof created?.session?.id !== "string" || typeof created.transport?.sdp !== "string") {
      return fail(c, { status: 502, code: "upstream_error", message: "The model provider returned no SDP answer." });
    }
    c.set("spentCents", config.prices.liveSessionCents);
    return c.json({ sessionID: created.session.id, sdp: created.transport.sdp, model: config.liveModel }, 201);
  });

  app.post("/v1/responses", admitted("responses", config.prices.responsesReserveCents), async (c) => {
    const parsed = await readJSON(c, config.maxResponsesBytes);
    if ("denial" in parsed) return fail(c, parsed.denial);
    const request = parsed.value;
    if (typeof request.model !== "string" || !config.responsesModels.includes(request.model)) {
      return fail(c, { status: 400, code: "model_not_allowed", message: "That model isn't offered." });
    }
    const field = Object.keys(request).find((name) => !RESPONSES_FIELDS_ALLOWED.has(name))
      ?? (request.stream !== undefined && request.stream !== false ? "stream" : undefined);
    if (field) return fail(c, { status: 400, code: "field_not_allowed", message: `\`${field}\` isn't allowed.` });
    request.store = false;
    const asked = tokens(request.max_output_tokens) || config.maxOutputTokens;
    request.max_output_tokens = Math.min(asked, config.maxOutputTokens);

    const reply = await upstream(`${config.openAIBaseURL}/v1/responses`, {
      method: "POST",
      headers: { authorization: `Bearer ${config.openAIKey}`, "content-type": "application/json" },
      body: JSON.stringify(request),
    });
    const text = await reply.text();
    if (reply.status === 400) return c.body(text, 400, { "content-type": "application/json" });
    if (!reply.ok) return fail(c, upstreamFailure(reply.status));
    let usage: { input_tokens?: unknown; output_tokens?: unknown } | undefined;
    try { usage = JSON.parse(text)?.usage; } catch {}
    const input = tokens(usage?.input_tokens);
    const output = usage ? tokens(usage.output_tokens) : (request.max_output_tokens as number);
    c.set("spentCents",
      (input * config.prices.responsesInputCentsPerMTok + output * config.prices.responsesOutputCentsPerMTok) / 1e6);
    return c.body(text, 200, { "content-type": "application/json" });
  });

  app.post("/v1/jev", admitted("jev", config.prices.jevCallCents), async (c) => {
    const parsed = await readJSON(c, config.maxJevBytes);
    if ("denial" in parsed) return fail(c, parsed.denial);
    const request = parsed.value;
    if (typeof request.model !== "string" || !config.jevModels.includes(request.model)) {
      return fail(c, { status: 400, code: "model_not_allowed", message: "That model isn't offered." });
    }
    const headers: Record<string, string> = {
      authorization: `Bearer ${config.typeSafeKey}`,
      "content-type": "application/json",
    };
    if (c.req.header("typesafe-danger-zone-images") === "true") headers["TypeSafe-Danger-Zone-Images"] = "true";
    const reply = await upstream(config.typeSafeURL, { method: "POST", headers, body: JSON.stringify(request) });
    const text = await reply.text();
    if (reply.status === 400 || reply.status === 422) {
      return c.body(text, reply.status, { "content-type": "application/json" });
    }
    if (!reply.ok) return fail(c, upstreamFailure(reply.status));
    c.set("spentCents", config.prices.jevCallCents);
    return c.body(text, 200, { "content-type": "application/json" });
  });

  return app;
}
