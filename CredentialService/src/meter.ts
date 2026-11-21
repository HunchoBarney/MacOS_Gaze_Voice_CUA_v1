export interface MeterSettings {
  standbyWeight: number;
  activeCentsPerMinute: number;
  pausedCentsPerMinute: number;
  graceSeconds: number;
}

export interface SidebandSocket {
  send(data: string): void;
  close(): void;
}

export interface SidebandHandlers {
  message(data: string): void;
  closed(): void;
}

/** What the meter needs from where it runs: a Durable Object in production, fakes in tests. */
export interface MeterHost {
  now(): number;
  /** Opens the session's sideband: a socket, "gone" when the session no longer exists, or "failed" to retry. */
  attach(handlers: SidebandHandlers): Promise<SidebandSocket | "gone" | "failed">;
  /** Records the session's totals so far; the ledger counts only what it hasn't counted for this session. */
  report(usage: { weightedSeconds: number; cents: number; now: number }): Promise<{ capped: boolean }>;
  wakeAt(at: number | null): unknown;
  save(state: MeterState): unknown;
}

export interface MeterState {
  startedAt: number | null;
  seconds: number;
  active: number;
  paused: number;
  billed: { weighted: number; cents: number };
  snapshotAt: number | null;
  droppedAt: number | null;
  attempts: number;
  retryAt: number | null;
  standby: boolean;
  cap: { at: number; seconds: number; paused: boolean } | null;
  closeSent: boolean;
  done: boolean;
  wake: number | null;
  seen: string[];
}

const MAX_BACKOFF_MS = 30_000;
const DETACHED_LIMIT_MS = 86_400_000;
const WATCHDOG_MS = 300_000;
const SEEN_EVENTS = 256;

const amount = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/**
 * Meters one GPT-Live session from its sideband. `session.usage.updated`
 * and `session.closed` carry cumulative usage, so the meter keeps the
 * largest snapshot and bills only increases: replays, duplicates and
 * out-of-order events can't double-count. Seconds the snapshot doesn't split
 * into active and paused count as active. It reports session totals, so a
 * report replayed after a restart counts once. Once the ledger says the
 * install is capped, the current turn finishes: the meter sends
 * `session.close` at the next `session.paused` (or at once if Live is
 * already in Standby), or after the grace period of session time or clock
 * time. A dropped sideband is reattached with backoff until OpenAI says the
 * session is gone, or a day has passed; then the time from the last snapshot
 * to the drop is billed at the active rate.
 */
export class Meter {
  readonly state: MeterState;
  private socket: SidebandSocket | null = null;
  private generation = 0;
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly settings: MeterSettings, private readonly host: MeterHost, state?: MeterState) {
    this.state = state ?? {
      startedAt: null, seconds: 0, active: 0, paused: 0,
      billed: { weighted: 0, cents: 0 },
      snapshotAt: null, droppedAt: null, attempts: 0, retryAt: null, standby: false,
      cap: null, closeSent: false, done: false, wake: null, seen: [],
    };
  }

  start(): Promise<void> {
    return this.enqueue(async () => {
      this.state.startedAt ??= this.host.now();
      if (!this.socket) await this.connect();
    });
  }

  /** Runs when the host's wake time arrives: reattaches when due and applies the clock grace. */
  alarm(): Promise<void> {
    return this.enqueue(async () => {
      this.state.wake = null;
      if (!this.socket && (this.state.retryAt === null || this.host.now() >= this.state.retryAt)) await this.connect();
    });
  }

  /** Settles once every event received so far is handled. */
  async idle(): Promise<void> {
    let settled;
    do {
      settled = this.queue;
      await settled;
    } while (settled !== this.queue);
  }

  private enqueue(task: () => Promise<void>): Promise<void> {
    this.queue = this.queue.then(async () => {
      if (this.state.done) return;
      try {
        await task();
      } finally {
        this.checkClose();
        await this.schedule();
        await this.host.save(this.state);
      }
    }).catch(() => {});
    return this.queue;
  }

  private async connect(): Promise<void> {
    const generation = ++this.generation;
    const current = (task: () => Promise<void>) => {
      void this.enqueue(async () => {
        if (generation === this.generation) await task();
      });
    };
    const result = await this.host.attach({
      message: (data) => current(() => this.handle(data)),
      closed: () => current(() => this.dropped()),
    });
    if (result === "gone") return this.endedWhileDetached();
    if (result === "failed") {
      this.state.attempts += 1;
      const since = this.state.droppedAt ?? this.state.startedAt ?? this.host.now();
      if (this.host.now() - since >= DETACHED_LIMIT_MS) return this.endedWhileDetached();
      this.state.retryAt = this.host.now() + Math.min(1000 * 2 ** (this.state.attempts - 1), MAX_BACKOFF_MS);
      return;
    }
    this.socket = result;
    this.state.attempts = 0;
    this.state.retryAt = null;
    this.state.droppedAt = null;
  }

  private async dropped(): Promise<void> {
    this.socket = null;
    this.state.droppedAt = this.host.now();
    await this.connect();
  }

  private async handle(data: string): Promise<void> {
    let event: { type?: unknown; event_id?: unknown; usage?: Record<string, unknown> } | null;
    try { event = JSON.parse(data); } catch { return; }
    if (!event || typeof event !== "object") return;
    if (typeof event.event_id === "string") {
      if (this.state.seen.includes(event.event_id)) return;
      this.state.seen.push(event.event_id);
      if (this.state.seen.length > SEEN_EVENTS) this.state.seen.shift();
    }
    if (event.type === "session.paused") {
      this.state.standby = true;
      if (this.state.cap) this.state.cap.paused = true;
    } else if (event.type === "session.resumed") {
      this.state.standby = false;
    } else if (event.type === "session.usage.updated" || event.type === "session.closed") {
      await this.observe(event.usage);
      if (event.type === "session.closed") this.finish();
    }
  }

  private async observe(usage: Record<string, unknown> | undefined): Promise<void> {
    const total = amount(usage?.seconds);
    if (total === undefined) return;
    if (total > this.state.seconds) {
      this.state.seconds = total;
      this.state.snapshotAt = this.host.now();
    }
    const active = amount(usage?.active_seconds);
    const paused = amount(usage?.paused_seconds);
    if (active !== undefined && paused !== undefined) {
      this.state.active = Math.max(this.state.active, active);
      this.state.paused = Math.max(this.state.paused, paused);
    }
    await this.bill();
  }

  private async bill(): Promise<void> {
    const { state, settings } = this;
    const active = state.active + Math.max(0, state.seconds - state.active - state.paused);
    const weighted = active + settings.standbyWeight * state.paused;
    const cents = (active * settings.activeCentsPerMinute + state.paused * settings.pausedCentsPerMinute) / 60;
    if (weighted <= state.billed.weighted && cents <= state.billed.cents) return;
    const now = this.host.now();
    const { capped } = await this.host.report({ weightedSeconds: weighted, cents, now });
    state.billed = { weighted: Math.max(weighted, state.billed.weighted), cents: Math.max(cents, state.billed.cents) };
    if (capped && !state.cap) state.cap = { at: now, seconds: state.seconds, paused: state.standby };
  }

  private async endedWhileDetached(): Promise<void> {
    const { state } = this;
    const from = state.snapshotAt ?? state.startedAt;
    const extra = state.droppedAt !== null && from !== null ? Math.max(0, state.droppedAt - from) / 1000 : 0;
    state.seconds += extra;
    state.snapshotAt = state.droppedAt;
    await this.bill();
    this.finish();
  }

  private finish(): void {
    this.state.done = true;
    this.state.retryAt = null;
    this.socket?.close();
    this.socket = null;
  }

  private checkClose(): void {
    const { state, socket } = this;
    if (!state.cap || state.closeSent || state.done || !socket) return;
    const grace = this.settings.graceSeconds;
    if (state.cap.paused || state.seconds >= state.cap.seconds + grace || this.host.now() >= state.cap.at + grace * 1000) {
      socket.send(JSON.stringify({ type: "session.close" }));
      state.closeSent = true;
    }
  }

  private async schedule(): Promise<void> {
    const { state } = this;
    const now = this.host.now();
    const due = [state.retryAt, state.cap && !state.closeSent && this.socket ? state.cap.at + this.settings.graceSeconds * 1000 : null]
      .filter((at): at is number => at !== null);
    const at = state.done ? null
      : due.length ? Math.min(...due)
      : state.wake !== null && state.wake > now ? state.wake : now + WATCHDOG_MS;
    if (at === state.wake) return;
    state.wake = at;
    await this.host.wakeAt(at);
  }
}
