import { DurableObject } from "cloudflare:workers";
import { createApp } from "./app.ts";
import { type Config, loadConfig, loadPlans } from "./config.ts";
import { Ledger, type LedgerClient, type Sql } from "./ledger.ts";
import { Meter, type MeterState, type SidebandHandlers, type SidebandSocket } from "./meter.ts";

interface Env {
  LEDGER: DurableObjectNamespace;
  LIVE_METER: DurableObjectNamespace;
  [name: string]: unknown;
}

interface MeteredSession {
  sessionID: string;
  installID: string;
}

const ledgerOf = (env: Env) => env.LEDGER.get(env.LEDGER.idFromName("ledger")) as unknown as LedgerClient;

/**
 * One SQLite-backed Durable Object holds the ledger, so every limit check
 * and charge is strongly consistent. Upstream calls stay in the Worker;
 * only small ledger calls reach the object.
 */
export class LedgerObject extends DurableObject<Env> {
  private readonly ledger: Ledger;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql: Sql = {
      all: <Row>(query: string, ...params: (string | number | null)[]) =>
        ctx.storage.sql.exec(query, ...params).toArray() as Row[],
    };
    this.ledger = new Ledger(sql, loadPlans(env));
  }

  register(input: Parameters<Ledger["register"]>[0]) { return this.ledger.register(input); }
  admit(input: Parameters<Ledger["admit"]>[0]) { return this.ledger.admit(input); }
  charge(input: Parameters<Ledger["charge"]>[0]) { return this.ledger.charge(input); }
  setPaused(paused: boolean) { return this.ledger.setPaused(paused); }
  setRevoked(input: Parameters<Ledger["setRevoked"]>[0]) { return this.ledger.setRevoked(input); }
  usage(now: number) { return this.ledger.usage(now); }
  lookup(input: Parameters<Ledger["lookup"]>[0]) { return this.ledger.lookup(input); }
  setTier(input: Parameters<Ledger["setTier"]>[0]) { return this.ledger.setTier(input); }
  addLiveUsage(input: Parameters<Ledger["addLiveUsage"]>[0]) { return this.ledger.addLiveUsage(input); }
  liveStatus(installID: string, now: number) { return this.ledger.liveStatus(installID, now); }
}

/** Opens a session's sideband with the owner's key. "gone" when OpenAI no longer has the session. */
async function attachSideband(config: Config, sessionID: string, handlers: SidebandHandlers): Promise<SidebandSocket | "gone" | "failed"> {
  let response: Response;
  try {
    response = await fetch(`${config.openAIBaseURL}/v1/live/sessions/${encodeURIComponent(sessionID)}/attach`, {
      headers: { Upgrade: "websocket", Authorization: `Bearer ${config.openAIKey}` },
    });
  } catch {
    return "failed";
  }
  const socket = response.webSocket;
  if (!socket) return response.status === 404 || response.status === 410 ? "gone" : "failed";
  socket.accept();
  socket.addEventListener("message", (event) => {
    if (typeof event.data === "string") handlers.message(event.data);
  });
  socket.addEventListener("close", () => handlers.closed());
  socket.addEventListener("error", () => handlers.closed());
  return socket;
}

/**
 * Meters one GPT-Live session, one object per session id. It holds the
 * sideband socket, reports usage to the ledger and wakes on alarms to
 * reattach or to close a capped session after its grace period.
 */
export class LiveMeter extends DurableObject<Env> {
  private meter?: Meter;

  async start(session: MeteredSession) {
    if (!(await this.ctx.storage.get("session"))) await this.ctx.storage.put("session", session);
    await (await this.load())?.start();
  }

  async alarm() {
    await (await this.load())?.alarm();
  }

  private async load(): Promise<Meter | undefined> {
    if (this.meter) return this.meter;
    const storage = this.ctx.storage;
    const session = (await storage.get("session")) as MeteredSession | undefined;
    if (!session) return undefined;
    const config = loadConfig(this.env);
    const ledger = ledgerOf(this.env);
    this.meter = new Meter(config.metering, {
      now: Date.now,
      attach: (handlers) => attachSideband(config, session.sessionID, handlers),
      report: (usage) => ledger.addLiveUsage({ installID: session.installID, sessionID: session.sessionID, ...usage }),
      wakeAt: (at) => (at === null ? storage.deleteAlarm() : storage.setAlarm(at)),
      save: (state) => (state.done ? storage.deleteAll() : storage.put("state", state)),
    }, (await storage.get("state")) as MeterState | undefined);
    return this.meter;
  }
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Response | Promise<Response> {
    let config;
    try {
      config = loadConfig(env);
    } catch (error) {
      return Response.json({ error: { code: "not_configured", message: (error as Error).message } }, { status: 503 });
    }
    const app = createApp({
      config,
      ledger: ledgerOf(env),
      upstream: (url, init) => fetch(url, init),
      clientIP: (c) => c.req.header("cf-connecting-ip"),
      startMeter: (session) => {
        const meter = env.LIVE_METER.get(env.LIVE_METER.idFromName(session.sessionID)) as unknown as LiveMeter;
        ctx.waitUntil(meter.start(session));
      },
    });
    return app.fetch(request, env, ctx as never);
  },
};
