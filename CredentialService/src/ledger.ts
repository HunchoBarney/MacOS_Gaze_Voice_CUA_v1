export type Route = "realtime" | "live" | "responses" | "jev";

export interface Limits {
  perMinute: Record<Route, number>;
  installDailyCents: number;
  globalDailyCents: number;
  registrationsPerIPPerDay: number;
  registrationsPerDay: number;
}

export interface Denial {
  status: number;
  code: string;
  message: string;
  retryAfter?: number;
}

export type SqlValue = string | number | null;

export interface Sql {
  all<Row = Record<string, SqlValue>>(query: string, ...params: SqlValue[]): Row[];
}

export interface Usage {
  day: string;
  paused: boolean;
  installs: number;
  revoked: number;
  globalCents: number;
  top: { installID: string; cents: number }[];
}

export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS installs (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
  )`,
  `CREATE TABLE IF NOT EXISTS counters (
    key TEXT PRIMARY KEY,
    bucket INTEGER NOT NULL,
    count INTEGER NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS spend (
    scope TEXT NOT NULL,
    day TEXT NOT NULL,
    cents REAL NOT NULL,
    PRIMARY KEY (scope, day)
  )`,
  `CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,
];

const DAY = 86_400_000;
const MINUTE = 60_000;

export const PAUSED: Denial = {
  status: 503,
  code: "paused",
  message: "Jarvis's service is paused by its owner.",
  retryAfter: 300,
};

const untilTomorrow = (now: number) => Math.ceil((DAY - (now % DAY)) / 1000);
const utcDay = (now: number) => new Date(now).toISOString().slice(0, 10);

/**
 * The service's state: installs, per-minute counters, daily spend and the
 * kill switch. Every method is synchronous, so inside one Durable Object
 * each call is atomic and two requests can't both take the last slot.
 */
export class Ledger {
  constructor(private readonly sql: Sql) {
    for (const statement of SCHEMA) sql.all(statement);
  }

  register(input: { installID: string; tokenHash: string; ipKey: string; limits: Limits; now: number }): Denial | null {
    const { installID, tokenHash, ipKey, limits, now } = input;
    if (this.paused()) return PAUSED;
    const day = Math.floor(now / DAY);
    const limited: Denial = {
      status: 429,
      code: "registration_limited",
      message: "Too many new installs today. Try again tomorrow.",
      retryAfter: untilTomorrow(now),
    };
    if (!this.hit(`register:ip:${ipKey}`, day, limits.registrationsPerIPPerDay)) return limited;
    if (!this.hit("register:all", day, limits.registrationsPerDay)) return limited;
    this.sql.all("INSERT INTO installs (id, token_hash, created_at) VALUES (?, ?, ?)", installID, tokenHash, now);
    return null;
  }

  /**
   * Checks the kill switch, the install, its budget and its rate, then
   * charges `reserveCents` at once, so requests in flight together can't
   * spend past a cap. The caller settles the difference with `charge`.
   */
  admit(input: { tokenHash: string; route: Route; reserveCents: number; limits: Limits; now: number }): { installID: string } | Denial {
    const { tokenHash, route, reserveCents, limits, now } = input;
    if (this.paused()) return PAUSED;
    const install = this.sql.all<{ id: string; revoked_at: number | null }>(
      "SELECT id, revoked_at FROM installs WHERE token_hash = ?", tokenHash)[0];
    if (!install) {
      return { status: 401, code: "unknown_install", message: "This install isn't registered." };
    }
    if (install.revoked_at !== null) {
      return { status: 403, code: "revoked", message: "This Mac's access to Jarvis's service was turned off." };
    }
    const day = utcDay(now);
    const overCap = (scope: string, cap: number) => {
      const spent = this.spent(scope, day);
      return spent >= cap || spent + reserveCents > cap;
    };
    if (overCap("global", limits.globalDailyCents)) {
      return {
        status: 503,
        code: "service_daily_limit",
        message: "Jarvis's service reached its daily limit. It resets at midnight UTC.",
        retryAfter: untilTomorrow(now),
      };
    }
    if (overCap(install.id, limits.installDailyCents)) {
      return {
        status: 429,
        code: "daily_limit",
        message: "This Mac reached today's limit. It resets at midnight UTC.",
        retryAfter: untilTomorrow(now),
      };
    }
    if (!this.hit(`rate:${install.id}:${route}`, Math.floor(now / MINUTE), limits.perMinute[route])) {
      return {
        status: 429,
        code: "rate_limited",
        message: "Too many requests. Try again in a moment.",
        retryAfter: Math.ceil((MINUTE - (now % MINUTE)) / 1000),
      };
    }
    this.charge({ installID: install.id, cents: reserveCents, now });
    return { installID: install.id };
  }

  /** Adds `cents` to the install's and the global spend for the day; negative refunds. */
  charge(input: { installID: string; cents: number; now: number }): void {
    if (!Number.isFinite(input.cents) || input.cents === 0) return;
    const day = utcDay(input.now);
    for (const scope of [input.installID, "global"]) {
      this.sql.all(
        "INSERT INTO spend (scope, day, cents) VALUES (?, ?, ?) ON CONFLICT (scope, day) DO UPDATE SET cents = cents + excluded.cents",
        scope, day, input.cents);
    }
  }

  setPaused(paused: boolean): void {
    this.sql.all(
      "INSERT INTO settings (key, value) VALUES ('paused', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
      paused ? "1" : "0");
  }

  setRevoked(input: { installID: string; revoked: boolean; now: number }): boolean {
    return this.sql.all("UPDATE installs SET revoked_at = ? WHERE id = ? RETURNING id",
      input.revoked ? input.now : null, input.installID).length > 0;
  }

  usage(now: number): Usage {
    const day = utcDay(now);
    const counts = this.sql.all<{ installs: number; revoked: number }>(
      "SELECT COUNT(*) AS installs, COUNT(revoked_at) AS revoked FROM installs")[0];
    const top = this.sql.all<{ scope: string; cents: number }>(
      "SELECT scope, cents FROM spend WHERE day = ? AND scope != 'global' ORDER BY cents DESC LIMIT 20", day);
    return {
      day,
      paused: this.paused(),
      installs: counts?.installs ?? 0,
      revoked: counts?.revoked ?? 0,
      globalCents: this.spent("global", day),
      top: top.map((row) => ({ installID: row.scope, cents: row.cents })),
    };
  }

  private paused(): boolean {
    return this.sql.all<{ value: string }>("SELECT value FROM settings WHERE key = 'paused'")[0]?.value === "1";
  }

  private spent(scope: string, day: string): number {
    return this.sql.all<{ cents: number }>("SELECT cents FROM spend WHERE scope = ? AND day = ?", scope, day)[0]?.cents ?? 0;
  }

  /** Counts one use of `key` in `bucket`; false, without counting, once `limit` is reached. */
  private hit(key: string, bucket: number, limit: number): boolean {
    const row = this.sql.all<{ bucket: number; count: number }>("SELECT bucket, count FROM counters WHERE key = ?", key)[0];
    const count = row && row.bucket === bucket ? row.count + 1 : 1;
    if (count > limit) return false;
    this.sql.all(
      "INSERT INTO counters (key, bucket, count) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET bucket = excluded.bucket, count = excluded.count",
      key, bucket, count);
    return true;
  }
}

/** How the app reaches a Ledger: a Durable Object stub in production, a local one in tests. */
export type LedgerClient = {
  [K in "register" | "admit" | "charge" | "setPaused" | "setRevoked" | "usage"]:
    (...args: Parameters<Ledger[K]>) => Promise<ReturnType<Ledger[K]>>;
};
