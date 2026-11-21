import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";
import { Ledger, type Sql } from "../src/ledger.ts";
import { Meter, type MeterHost, type SidebandHandlers } from "../src/meter.ts";

const START = Date.UTC(2026, 10, 20, 12, 0, 0);
const INSTALL = "install-fixture";
const TINY = JSON.stringify({ tiny: { liveMinutes: 1, tasks: 1, priceUSD: 0 } });

type Attach = "ok" | "failed" | "gone";
interface Step { at: number; event?: Record<string, unknown>; drop?: true }
interface Fixture {
  name: string;
  finalSeconds: number;
  finalActiveSeconds?: number;
  finalPausedSeconds?: number;
  attaches: Attach[];
  timeline: Step[];
}

const dir = new URL("./fixtures/live-usage/", import.meta.url);
const fixtures: [string, Fixture][] = readdirSync(dir).filter((file) => file.endsWith(".json")).sort()
  .map((file) => [file, JSON.parse(readFileSync(new URL(file, dir), "utf8"))]);

/** A meter on a fake clock and fake sideband, reporting to a real ledger on Node's SQLite. */
function rig(vars: Record<string, string> = {}, attaches: Attach[] = ["ok"]) {
  const config = loadConfig({ OPENAI_API_KEY: "a", TYPESAFE_API_KEY: "b", ADMIN_TOKEN: "c", ...vars });
  const db = new DatabaseSync(":memory:");
  const sql: Sql = { all: (query, ...params) => db.prepare(query).all(...params) as any };
  const ledger = new Ledger(sql, config.metering);
  ledger.register({ installID: INSTALL, tokenHash: "hash", ipKey: "ip", limits: config.limits, now: START });
  let clock = START;
  let wake: number | null = null;
  const pending = [...attaches];
  const attachedAt: number[] = [];
  const reports: number[] = [];
  const sent: unknown[] = [];
  let socket: SidebandHandlers | null = null;
  const host: MeterHost = {
    now: () => clock,
    attach: async (handlers) => {
      attachedAt.push(clock - START);
      const result = pending.shift() ?? "failed";
      if (result !== "ok") return result;
      socket = handlers;
      return {
        send: (data) => { if (socket === handlers) sent.push(JSON.parse(data)); },
        close: () => { if (socket === handlers) socket = null; },
      };
    },
    report: async (usage) => {
      reports.push(usage.weightedSeconds);
      return ledger.addLiveUsage({ installID: INSTALL, ...usage });
    },
    wakeAt: (at) => { wake = at; },
    save: () => {},
  };
  const meter = new Meter(config.metering, host);
  const advanceTo = async (at: number) => {
    for (let i = 0; i < 10_000 && wake !== null && wake <= START + at; i++) {
      clock = Math.max(clock, wake);
      wake = null;
      await meter.alarm();
    }
    clock = Math.max(clock, START + at);
  };
  const step = async ({ at, event, drop }: Step) => {
    await advanceTo(at);
    const current = socket;
    if (!current) return;
    if (drop) {
      socket = null;
      current.closed();
    } else {
      current.message(JSON.stringify(event));
    }
    await meter.idle();
  };
  return {
    meter, ledger, sent, reports, attachedAt, pending, advanceTo, step,
    socket: () => socket,
    wake: () => (wake === null ? null : wake - START),
    usage: (at: number, seconds: number, id = `u${seconds}`) =>
      step({ at, event: { type: "session.usage.updated", event_id: id, usage: { seconds } } }),
    event: (at: number, type: string, id: string) => step({ at, event: { type, event_id: id } }),
    liveSeconds: () => ledger.liveStatus(INSTALL, START).liveSeconds,
    cents: () => ledger.usage(START).globalCents,
  };
}

describe("Live usage fixtures", () => {
  it("has the corpus the metering rule is checked against", () => {
    expect(fixtures.length).toBeGreaterThanOrEqual(10);
  });

  for (const [file, fixture] of fixtures) {
    it(`${file}: ${fixture.name}`, async () => {
      const r = rig({}, fixture.attaches);
      await r.meter.start();
      for (const step of fixture.timeline) await r.step(step);
      await r.advanceTo(fixture.timeline.at(-1)!.at + 3_600_000);

      expect(r.meter.state.done).toBe(true);
      expect(r.pending).toEqual([]);
      expect(Math.abs(r.meter.state.seconds - fixture.finalSeconds) / fixture.finalSeconds).toBeLessThanOrEqual(0.02);
      const active = fixture.finalActiveSeconds ?? fixture.finalSeconds;
      const paused = fixture.finalPausedSeconds ?? 0;
      const weighted = active + 0.4 * paused;
      expect(Math.abs(r.liveSeconds() - weighted) / weighted).toBeLessThanOrEqual(0.02);
      expect(r.liveSeconds()).toBeCloseTo(r.meter.state.billed.weighted, 6);
      expect(r.reports.every((seconds) => seconds > 0)).toBe(true);
      const cents = (active * 5 + paused * 2) / 60;
      expect(Math.abs(r.cents() - cents) / cents).toBeLessThanOrEqual(0.02);
      expect(r.sent).toEqual([]);
    });
  }
});

describe("the cap", () => {
  it("lets the turn finish and closes only at the next session.paused", async () => {
    const r = rig({ TIERS: TINY, DEFAULT_TIER: "tiny" });
    await r.meter.start();
    await r.event(0, "session.resumed", "r1");
    await r.usage(20_000, 20);
    await r.event(25_000, "session.paused", "p1");
    await r.event(30_000, "session.resumed", "r2");
    for (let s = 35; s <= 60; s += 5) await r.usage(s * 1000, s);
    expect(r.meter.state.cap).toEqual({ at: START + 60_000, seconds: 60, paused: false });
    expect(r.sent).toEqual([]);
    await r.usage(65_000, 65);
    await r.event(66_000, "session.paused", "p1");
    await r.usage(70_000, 70);
    expect(r.sent).toEqual([]);
    await r.event(72_000, "session.paused", "p2");
    expect(r.sent).toEqual([{ type: "session.close" }]);
    await r.step({ at: 73_000, event: { type: "session.closed", event_id: "c1", reason: "close_requested", usage: { seconds: 73 } } });
    expect(r.meter.state.done).toBe(true);
    expect(r.liveSeconds()).toBe(73);
    expect(r.sent).toHaveLength(1);
  });

  it("closes once the grace period of session time has passed by snapshot", async () => {
    const r = rig({ TIERS: TINY, DEFAULT_TIER: "tiny", CAP_GRACE_SECONDS: "60" });
    await r.meter.start();
    await r.usage(60_000, 60);
    expect(r.meter.state.cap).not.toBeNull();
    await r.usage(61_000, 115);
    expect(r.sent).toEqual([]);
    await r.usage(62_000, 120);
    expect(r.sent).toEqual([{ type: "session.close" }]);
  });

  it("closes once the grace period has passed by the clock when no pause or snapshot comes", async () => {
    const r = rig({ TIERS: TINY, DEFAULT_TIER: "tiny", CAP_GRACE_SECONDS: "60" });
    await r.meter.start();
    await r.usage(60_000, 60);
    expect(r.wake()).toBe(120_000);
    await r.advanceTo(119_999);
    expect(r.sent).toEqual([]);
    await r.advanceTo(120_000);
    expect(r.sent).toEqual([{ type: "session.close" }]);
  });

  it("closes at once when the cap arrives while Live is already in Standby", async () => {
    const r = rig({ TIERS: TINY, DEFAULT_TIER: "tiny" });
    await r.meter.start();
    await r.usage(40_000, 40);
    await r.event(45_000, "session.paused", "p1");
    expect(r.sent).toEqual([]);
    await r.usage(60_000, 60);
    expect(r.sent).toEqual([{ type: "session.close" }]);
  });

  it("waits for the next reattach, not a past alarm, when the grace runs out while detached", async () => {
    const r = rig({ TIERS: TINY, DEFAULT_TIER: "tiny", CAP_GRACE_SECONDS: "60" },
      ["ok", "failed", "failed", "failed", "failed", "failed", "failed", "ok"]);
    await r.meter.start();
    await r.usage(60_000, 60);
    expect(r.wake()).toBe(120_000);
    await r.step({ at: 70_000, drop: true });
    await r.advanceTo(125_000);
    expect(r.wake()).toBe(131_000);
    expect(r.sent).toEqual([]);
    await r.advanceTo(131_000);
    expect(r.attachedAt).toEqual([0, 70_000, 71_000, 73_000, 77_000, 85_000, 101_000, 131_000]);
    expect(r.sent).toEqual([{ type: "session.close" }]);
  });
});

describe("reattaching", () => {
  it("backs off on the injected clock, then bills to the drop once it gives up", async () => {
    const r = rig({}, ["ok"]);
    await r.meter.start();
    await r.usage(10_000, 10);
    await r.step({ at: 12_000, drop: true });
    await r.advanceTo(600_000);
    expect(r.attachedAt).toEqual([0, 12_000, 13_000, 15_000, 19_000, 27_000, 43_000, 73_000, 103_000]);
    expect(r.meter.state.done).toBe(true);
    expect(r.meter.state.seconds).toBe(12);
    expect(r.liveSeconds()).toBe(12);
    expect(r.wake()).toBeNull();
  });

  it("ignores a stale socket's events after a reattach", async () => {
    const r = rig({}, ["ok", "ok"]);
    await r.meter.start();
    await r.usage(5_000, 5);
    const first = r.socket()!;
    await r.step({ at: 6_000, drop: true });
    await r.usage(8_000, 8);
    first.message(JSON.stringify({ type: "session.usage.updated", event_id: "stale", usage: { seconds: 500 } }));
    first.closed();
    await r.meter.idle();
    expect(r.attachedAt).toEqual([0, 6_000]);
    expect(r.liveSeconds()).toBe(8);
  });
});
