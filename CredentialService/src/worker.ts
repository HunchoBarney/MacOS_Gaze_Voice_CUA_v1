import { DurableObject } from "cloudflare:workers";
import { createApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { Ledger, type LedgerClient, type Sql } from "./ledger.ts";

interface Env {
  LEDGER: DurableObjectNamespace;
  [name: string]: unknown;
}

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
    this.ledger = new Ledger(sql);
  }

  register(input: Parameters<Ledger["register"]>[0]) { return this.ledger.register(input); }
  admit(input: Parameters<Ledger["admit"]>[0]) { return this.ledger.admit(input); }
  charge(input: Parameters<Ledger["charge"]>[0]) { return this.ledger.charge(input); }
  setPaused(paused: boolean) { return this.ledger.setPaused(paused); }
  setRevoked(input: Parameters<Ledger["setRevoked"]>[0]) { return this.ledger.setRevoked(input); }
  usage(now: number) { return this.ledger.usage(now); }
}

export default {
  fetch(request: Request, env: Env, ctx: unknown): Response | Promise<Response> {
    let config;
    try {
      config = loadConfig(env);
    } catch (error) {
      return Response.json({ error: { code: "not_configured", message: (error as Error).message } }, { status: 503 });
    }
    const ledger = env.LEDGER.get(env.LEDGER.idFromName("ledger")) as unknown as LedgerClient;
    const app = createApp({
      config,
      ledger,
      upstream: (url, init) => fetch(url, init),
      clientIP: (c) => c.req.header("cf-connecting-ip"),
    });
    return app.fetch(request, env, ctx as never);
  },
};
