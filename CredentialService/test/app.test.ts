import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.ts";
import { loadConfig } from "../src/config.ts";
import { Ledger, type LedgerClient, type Sql } from "../src/ledger.ts";

const OPENAI_KEY = "sk-owner-openai-fixture";
const TYPESAFE_KEY = "ts-owner-typesafe-fixture";
const ADMIN = "admin-fixture-token";

const body = (response: Response): Promise<any> => response.json();

interface Call { url: string; headers: Record<string, string>; body: any }

function harness(vars: Record<string, string> = {}) {
  const db = new DatabaseSync(":memory:");
  const sql: Sql = { all: (query, ...params) => db.prepare(query).all(...params) as any };
  const local = new Ledger(sql);
  const ledger = Object.fromEntries(
    (["register", "admit", "charge", "setPaused", "setRevoked", "usage"] as const)
      .map((name) => [name, async (...args: any[]) => (local[name] as any)(...args)]),
  ) as LedgerClient;
  const calls: Call[] = [];
  let reply: (call: Call) => Response = (call) => {
    if (call.url.endsWith("/v1/realtime/client_secrets")) {
      return Response.json({ value: "ek_fixture", expires_at: 1_900_000_000, session: {} });
    }
    if (call.url.endsWith("/v1/responses")) {
      return Response.json({ output: [], usage: { input_tokens: 1_000_000, output_tokens: 100_000 } });
    }
    return Response.json({ answers: {} });
  };
  let clock = Date.UTC(2026, 10, 20, 12, 0, 0);
  let ip = "203.0.113.7";
  const config = loadConfig({
    OPENAI_API_KEY: OPENAI_KEY, TYPESAFE_API_KEY: TYPESAFE_KEY, ADMIN_TOKEN: ADMIN, ...vars,
  });
  const app = createApp({
    config,
    ledger,
    now: () => clock,
    clientIP: () => ip,
    upstream: async (url, init) => {
      const call = { url, headers: init.headers as Record<string, string>, body: JSON.parse(String(init.body)) };
      calls.push(call);
      return reply(call);
    },
  });
  const request = (path: string, init: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}) =>
    app.request(path, {
      method: init.method ?? "POST",
      headers: {
        ...(init.token ? { authorization: `Bearer ${init.token}` } : {}),
        ...(init.body !== undefined ? { "content-type": "application/json" } : {}),
        ...init.headers,
      },
      body: init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
    });
  const register = async () => {
    const response = await request("/v1/installs");
    expect(response.status).toBe(201);
    return (await body(response)) as { installID: string; token: string };
  };
  return {
    db, calls, request, register, config,
    setReply: (next: typeof reply) => { reply = next; },
    advance: (ms: number) => { clock += ms; },
    setIP: (next: string) => { ip = next; },
    admin: (path: string, method = "POST") => request(path, { method, token: ADMIN }),
  };
}

const terra = { model: "gpt-6.1-terra", input: [], max_output_tokens: 1000 };
const jev = { model: "jev-1.14.0", state: {}, questions: {} };

describe("registration", () => {
  it("returns a token the service stores only as a hash", async () => {
    const h = harness();
    const { installID, token } = await h.register();
    expect(token).toMatch(/^jv1_[A-Za-z0-9_-]{43}$/);
    const rows = h.db.prepare("SELECT * FROM installs").all();
    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe(installID);
    expect(JSON.stringify(rows)).not.toContain(token);
  });

  it("limits new installs per network per day", async () => {
    const h = harness({ REGISTRATIONS_PER_IP_PER_DAY: "2" });
    await h.register();
    await h.register();
    const third = await h.request("/v1/installs");
    expect(third.status).toBe(429);
    expect((await body(third)).error.code).toBe("registration_limited");
    h.setIP("198.51.100.4");
    await h.register();
    h.setIP("203.0.113.7");
    h.advance(86_400_000);
    await h.register();
  });

  it("caps new installs across all networks", async () => {
    const h = harness({ REGISTRATIONS_PER_DAY: "1" });
    await h.register();
    h.setIP("198.51.100.4");
    expect((await h.request("/v1/installs")).status).toBe(429);
  });
});

describe("realtime client secrets", () => {
  it("mints a short-lived secret for the pinned model with the owner's key", async () => {
    const h = harness();
    const { token } = await h.register();
    const response = await h.request("/v1/realtime/client_secret", { token });
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ value: "ek_fixture", expiresAt: 1_900_000_000, model: "gpt-realtime-2.1" });
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0].url).toBe("https://api.openai.com/v1/realtime/client_secrets");
    expect(h.calls[0].headers.authorization).toBe(`Bearer ${OPENAI_KEY}`);
    expect(h.calls[0].body).toEqual({
      expires_after: { anchor: "created_at", seconds: 60 },
      session: { type: "realtime", model: "gpt-realtime-2.1" },
    });
  });

  it("refuses unknown and malformed tokens without calling upstream", async () => {
    const h = harness();
    for (const token of [undefined, "jv1_" + "A".repeat(43), "not-a-token"]) {
      const response = await h.request("/v1/realtime/client_secret", { token });
      expect(response.status).toBe(401);
      expect((await body(response)).error.code).toBe("unknown_install");
    }
    expect(h.calls).toHaveLength(0);
  });

  it("maps an upstream rejection without passing it through", async () => {
    const h = harness();
    const { token } = await h.register();
    h.setReply(() => Response.json({ error: { message: "Incorrect API key provided: sk-owner" } }, { status: 401 }));
    const response = await h.request("/v1/realtime/client_secret", { token });
    expect(response.status).toBe(502);
    const text = await response.text();
    expect(text).not.toContain("sk-owner");
    expect(JSON.parse(text).error.code).toBe("upstream_error");
  });
});

describe("limits", () => {
  it("rate-limits each install per route per minute", async () => {
    const h = harness({ REALTIME_PER_MINUTE: "2", REALTIME_SESSION_CENTS: "0" });
    const { token } = await h.register();
    const other = await h.register();
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    const limited = await h.request("/v1/realtime/client_secret", { token });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("60");
    expect((await body(limited)).error.code).toBe("rate_limited");
    expect((await h.request("/v1/realtime/client_secret", { token: other.token })).status).toBe(200);
    expect((await h.request("/v1/jev", { token, body: jev })).status).toBe(200);
    h.advance(60_000);
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    expect(h.calls.filter((call) => call.url.includes("realtime"))).toHaveLength(4);
  });

  it("stops an install at its daily spend and resets at midnight UTC", async () => {
    const h = harness({ INSTALL_DAILY_CENTS: "50", REALTIME_SESSION_CENTS: "25" });
    const { token } = await h.register();
    const other = await h.register();
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    const over = await h.request("/v1/realtime/client_secret", { token });
    expect(over.status).toBe(429);
    expect((await body(over)).error.code).toBe("daily_limit");
    expect((await h.request("/v1/realtime/client_secret", { token: other.token })).status).toBe(200);
    h.advance(12 * 3_600_000);
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
  });

  it("stops every install at the global daily cap", async () => {
    const h = harness({ GLOBAL_DAILY_CENTS: "50", REALTIME_SESSION_CENTS: "25" });
    const first = await h.register();
    const second = await h.register();
    await h.request("/v1/realtime/client_secret", { token: first.token });
    await h.request("/v1/realtime/client_secret", { token: second.token });
    const capped = await h.request("/v1/realtime/client_secret", { token: (await h.register()).token });
    expect(capped.status).toBe(503);
    expect((await body(capped)).error.code).toBe("service_daily_limit");
    expect(h.calls).toHaveLength(2);
  });

  it("charges Responses calls by the tokens they used", async () => {
    const h = harness({ RESPONSES_INPUT_CENTS_PER_MTOK: "200", RESPONSES_OUTPUT_CENTS_PER_MTOK: "800" });
    const { installID, token } = await h.register();
    expect((await h.request("/v1/responses", { token, body: terra })).status).toBe(200);
    const usage = await body(await h.admin("/admin/usage", "GET"));
    expect(usage.top).toEqual([{ installID, cents: 280 }]);
    expect(usage.globalCents).toBe(280);
  });
});

describe("kill switch", () => {
  it("pauses and resumes every install from the admin endpoint", async () => {
    const h = harness();
    const { token } = await h.register();
    expect((await h.admin("/admin/pause")).status).toBe(200);
    for (const path of ["/v1/realtime/client_secret", "/v1/installs"]) {
      const response = await h.request(path, { token });
      expect(response.status).toBe(503);
      expect((await body(response)).error.code).toBe("paused");
    }
    expect((await h.admin("/admin/resume")).status).toBe(200);
    expect((await h.request("/v1/realtime/client_secret", { token })).status).toBe(200);
    expect(h.calls).toHaveLength(1);
  });

  it("pauses everything from the PAUSED variable", async () => {
    const h = harness({ PAUSED: "1" });
    expect((await h.request("/v1/installs")).status).toBe(503);
  });

  it("revokes and restores one install", async () => {
    const h = harness();
    const { installID, token } = await h.register();
    expect((await h.admin(`/admin/installs/${installID}/revoke`)).status).toBe(200);
    const revoked = await h.request("/v1/jev", { token, body: jev });
    expect(revoked.status).toBe(403);
    expect((await body(revoked)).error.code).toBe("revoked");
    expect((await h.admin(`/admin/installs/${installID}/restore`)).status).toBe(200);
    expect((await h.request("/v1/jev", { token, body: jev })).status).toBe(200);
    expect((await h.admin("/admin/installs/nobody/revoke")).status).toBe(404);
  });

  it("refuses admin calls without the admin token", async () => {
    const h = harness();
    const { token } = await h.register();
    for (const auth of [undefined, token, ADMIN + "x"]) {
      expect((await h.request("/admin/pause", { token: auth })).status).toBe(401);
    }
  });
});

describe("Responses proxy", () => {
  it("forwards an allowed request with store off and output capped", async () => {
    const h = harness({ MAX_OUTPUT_TOKENS: "500" });
    const { token } = await h.register();
    const response = await h.request("/v1/responses", { token, body: { ...terra, store: true } });
    expect(response.status).toBe(200);
    expect(h.calls[0].url).toBe("https://api.openai.com/v1/responses");
    expect(h.calls[0].headers.authorization).toBe(`Bearer ${OPENAI_KEY}`);
    expect(h.calls[0].body).toEqual({ ...terra, store: false, max_output_tokens: 500 });
  });

  it("refuses other models, tools, streaming and stored state", async () => {
    const h = harness();
    const { token } = await h.register();
    for (const body of [
      { ...terra, model: "gpt-6.2-astra" },
      { ...terra, tools: [{ type: "web_search" }] },
      { ...terra, stream: true },
      { ...terra, previous_response_id: "resp_1" },
      [terra],
      "not json",
    ]) {
      expect((await h.request("/v1/responses", { token, body })).status).toBe(400);
    }
    expect(h.calls).toHaveLength(0);
  });

  it("refuses an oversized body before calling upstream", async () => {
    const h = harness({ MAX_RESPONSES_BYTES: "100" });
    const { token } = await h.register();
    const response = await h.request("/v1/responses", { token, body: { ...terra, instructions: "x".repeat(200) } });
    expect(response.status).toBe(413);
    expect(h.calls).toHaveLength(0);
  });

  it("passes a provider's 400 through so the app can read it", async () => {
    const h = harness();
    const { token } = await h.register();
    h.setReply(() => Response.json({ error: { message: "Invalid schema" } }, { status: 400 }));
    const response = await h.request("/v1/responses", { token, body: terra });
    expect(response.status).toBe(400);
    expect((await body(response)).error.message).toBe("Invalid schema");
  });
});

describe("Jev proxy", () => {
  it("forwards to TypeSafe with the owner's key and the image header", async () => {
    const h = harness();
    const { token } = await h.register();
    const response = await h.request("/v1/jev", {
      token, body: jev, headers: { "TypeSafe-Danger-Zone-Images": "true" },
    });
    expect(response.status).toBe(200);
    expect(h.calls[0].url).toBe("https://api.typesafe.ai/v1/systemone");
    expect(h.calls[0].headers.authorization).toBe(`Bearer ${TYPESAFE_KEY}`);
    expect(h.calls[0].headers["TypeSafe-Danger-Zone-Images"]).toBe("true");
    expect(h.calls[0].body).toEqual(jev);
  });

  it("refuses a model that isn't offered", async () => {
    const h = harness();
    const { token } = await h.register();
    expect((await h.request("/v1/jev", { token, body: { ...jev, model: "jev-2-preview" } })).status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it("maps provider throttling to a retryable 503", async () => {
    const h = harness();
    const { token } = await h.register();
    h.setReply(() => new Response("slow down", { status: 429 }));
    const response = await h.request("/v1/jev", { token, body: jev });
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
  });
});

describe("configuration", () => {
  it("names the missing secret", () => {
    expect(() => loadConfig({ OPENAI_API_KEY: "a", TYPESAFE_API_KEY: "b" })).toThrow(/ADMIN_TOKEN/);
  });

  it("rejects a negative limit", () => {
    expect(() => loadConfig({ OPENAI_API_KEY: "a", TYPESAFE_API_KEY: "b", ADMIN_TOKEN: "c", INSTALL_DAILY_CENTS: "-1" }))
      .toThrow(/INSTALL_DAILY_CENTS/);
  });

  it("never returns the owner's keys", async () => {
    const h = harness();
    const { token } = await h.register();
    const bodies = await Promise.all([
      h.request("/v1/realtime/client_secret", { token }),
      h.request("/v1/responses", { token, body: terra }),
      h.request("/v1/jev", { token, body: jev }),
      h.admin("/admin/usage", "GET"),
      h.request("/health", { method: "GET" }),
    ].map(async (response) => (await response).text()));
    for (const body of bodies) {
      expect(body).not.toContain(OPENAI_KEY);
      expect(body).not.toContain(TYPESAFE_KEY);
      expect(body).not.toContain(ADMIN);
    }
  });
});
