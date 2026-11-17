import { afterEach, describe, expect, it, vi } from "vitest";
import {
  advanceDotSpring,
  DOT_DEADBAND_PX,
  isSaccadeJump,
  leadTarget,
  scheduleGazeExpiry,
  shouldRetryCalibrationCapture
} from "./uiState";
import {
  Calibration,
  coastPosition,
  EyeValidity,
  isHeadTurned,
  OneEuroFilter,
  SaccadeAwareGazeFilter
} from "./inference/core";
import type { CalibrationIO, GazeFeature } from "./inference/core";
import type { BackendMessage } from "./global";

afterEach(() => {
  vi.useRealTimers();
});

// ---------------------------------------------------------------------------
// Flow tests: the product paths a person actually walks — a jittery ~14.5fps
// gaze stream driving a 60Hz dot, pause/unpause, dwell-lock, blink/head-away
// ghosting, and the calibration lifecycle. Every semantic decision runs
// through the same exported helpers the UI/runtime call:
//   SaccadeAwareGazeFilter.update  (webRuntime.ts:1059 — the shipped filter)
//   isSaccadeJump / leadTarget / advanceDotSpring  (App.tsx:533,1180)
//   EyeValidity / isHeadTurned / coastPosition     (webRuntime.ts:834-888)
//   Calibration pursuit/verify/commit              (webRuntime.ts:1177-1197)
//
// What is NOT real: App.tsx is the renderer entry point and exports nothing —
// updateGazeMotion (App.tsx:240), the GazePresence derivation (App.tsx:557),
// the opacity ladder (App.tsx:1201-1217), the stale watchdog cascade
// (App.tsx:439) and the onboarding gate (App.tsx:647) are module-private.
// The harness below mirrors that wiring verbatim (each site is cited) so the
// flows exercise real exported logic end-to-end; the mirrored seams are thin
// plumbing, never the asserted logic.
// ---------------------------------------------------------------------------

type Vec = [number, number];
const VIEW: Vec = [1920, 1080];
const GAZE_DT_MS = 1000 / 14.5; // real stream cadence ≈ 69ms
const FRAME_DT_SEC = 1 / 60;

function mulberry32(a: number): () => number {
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function gauss(rng: () => number): number {
  let u = 0;
  let v = 0;
  while (!u) u = rng();
  while (!v) v = rng();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

// --- Runtime-side mirror ---------------------------------------------------
// webRuntime.ts:1107 / inferenceWorker.ts:1231 — the emit sites translate the
// shipped filter's flags into the gaze_state field the UI reads.
function gazeStateOf(filter: SaccadeAwareGazeFilter): "saccade" | "dwell" | "fixation" {
  return filter.inSaccade ? "saccade" : filter.dwellLocked ? "dwell" : "fixation";
}

// --- Renderer-side mirror --------------------------------------------------
interface Presence {
  live: boolean;
  ghost: boolean;
  held: boolean;
  dwell: boolean;
}

// App.tsx:557-562 — presence facets are a pure read of the message fields.
function presenceOf(msg: { live: boolean; blink?: boolean; headTurned?: boolean; heldReason?: string; state?: string }): Presence {
  return {
    live: msg.live,
    ghost: msg.blink === true || msg.headTurned === true,
    held: Boolean(msg.heldReason),
    dwell: msg.state === "dwell"
  };
}

// App.tsx:1201-1217 — discrete opacity ladder for the dot.
function dotOpacity(p: Presence, paused: boolean, hasPos: boolean): number {
  if (paused) return hasPos ? 0.2 : 0;
  if (!p.live) return 0;
  if (p.ghost) return 0.18;
  if (p.held) return 0.4;
  return 1;
}

// The render-side dot pipeline, wired exactly as the gaze handler (App.tsx:520)
// and rAF loop (App.tsx:1158) do. The velocity estimate mirrors the
// module-private updateGazeMotion (App.tsx:240-282): finite difference on the
// capture cadence, EMA(0.5), speed cap 4 — everything else delegates to real
// exports.
class DotFlow {
  target: Vec | null = null;
  targetAtMs = 0;
  vel: Vec = [0, 0];
  display: Vec | null = null;
  springVel: Vec = [0, 0];
  paused = false;
  // A/B knob for the lead test — zero velocity into the same leadTarget call
  // is exactly "no feed-forward" (leadTarget(target, [0,0], t) === target).
  useLead = true;
  presence: Presence = { live: false, ghost: false, held: false, dwell: false };
  // Trace of every rendered position — the flow assertions read it.
  trace: Vec[] = [];

  onGaze(
    msg: { x: number; y: number; state?: string; blink?: boolean; headTurned?: boolean; heldReason?: string },
    capturedAtMs: number
  ): void {
    // App.tsx:249 — a non-finite frame is dropped before it can poison the
    // velocity EMA; the displayed dot is untouched.
    if (!Number.isFinite(msg.x) || !Number.isFinite(msg.y)) {
      this.vel = [0, 0];
      return;
    }
    const next: Vec = [msg.x, msg.y];
    const wasLive = this.presence.live;
    if (isSaccadeJump(msg.state, this.target, next)) {
      // App.tsx:538-543 — saccades teleport under suppression; both
      // velocities die so nothing coasts or chases across the jump.
      this.display = next;
      this.springVel = [0, 0];
      this.vel = [0, 0];
    } else if (this.target && this.targetAtMs > 0) {
      const dt = Math.max(0.001, (capturedAtMs - this.targetAtMs) / 1000);
      let vx = this.vel[0] + 0.5 * ((next[0] - this.target[0]) / dt - this.vel[0]);
      let vy = this.vel[1] + 0.5 * ((next[1] - this.target[1]) / dt - this.vel[1]);
      const speed = Math.hypot(vx, vy);
      if (speed > 4) {
        vx *= 4 / speed;
        vy *= 4 / speed;
      }
      this.vel = [vx, vy];
    }
    this.target = next;
    this.targetAtMs = capturedAtMs;
    // App.tsx:549-554 — a resuming stream re-seeds the dot instead of easing
    // over from wherever it faded.
    if (!wasLive && !this.paused) {
      this.display = null;
      this.springVel = [0, 0];
    }
    this.presence = presenceOf({
      live: true,
      blink: msg.blink,
      headTurned: msg.headTurned,
      heldReason: msg.heldReason,
      state: msg.state
    });
  }

  // handleGazeStale (App.tsx:439-455) — the watchdog cascade when the stream
  // stops: presence off, motion refs dropped, diagnostics hidden.
  expire(): void {
    this.target = null;
    this.targetAtMs = 0;
    this.vel = [0, 0];
    this.springVel = [0, 0];
    if (!this.paused) {
      this.display = null;
    }
    this.presence = { live: false, ghost: false, held: false, dwell: false };
  }

  onFrame(nowMs: number): void {
    // App.tsx:1152 — the rAF loop only runs while a live, unpaused stream has
    // motion to animate; a paused ghost or absent dot is static.
    if (this.paused || !this.presence.live) return;
    if (this.display === null) {
      if (!this.target) return;
      this.display = [...this.target];
      this.trace.push(this.display);
      return;
    }
    if (!this.target) return;
    // App.tsx:1179-1183 — lead the chase target by the sample's wall-clock
    // age (capped ~2 frames), then advance the critically damped spring.
    const sinceUpdate = Math.max(0, (nowMs - this.targetAtMs) / 1000);
    const led = leadTarget(this.target, this.useLead ? this.vel : [0, 0], sinceUpdate);
    const motion = advanceDotSpring(this.display, this.springVel, led, FRAME_DT_SEC, VIEW);
    this.display = motion.pos;
    this.springVel = motion.vel;
    this.trace.push(this.display);
  }
}

// A scripted gaze timeline: dwells with sensor jitter, instant saccades, a
// smooth-pursuit ramp — run through the REAL SaccadeAwareGazeFilter so the
// stream carries the same gaze_state marks the runtime emits.
interface ScriptedSample {
  at: number; // ms on the stream clock
  raw?: Vec; // undefined = a dropped/dead frame (the stream simply skips it)
  nan?: boolean;
}

function scriptStream(rng: () => number): ScriptedSample[] {
  const samples: ScriptedSample[] = [];
  let t = 0;
  const dwellAt = (pos: Vec, durationMs: number, jitter = 0.004) => {
    const end = t + durationMs;
    while (t < end) {
      samples.push({ at: t, raw: [pos[0] + gauss(rng) * jitter, pos[1] + gauss(rng) * jitter] });
      t += GAZE_DT_MS;
    }
  };
  // Look at A, saccade to B (single-frame jump — a real saccade completes
  // inside one 69ms frame), dwell long enough to dwell-lock, inject one NaN
  // frame mid-dwell, saccade to C, then smooth-pursuit rightward.
  dwellAt([0.3, 0.4], 1100);
  samples.push({ at: t, raw: [0.72, 0.62] });
  t += GAZE_DT_MS;
  const dwellBEnd = t + 900;
  const nanAt = t + 450;
  while (t < dwellBEnd) {
    if (Math.abs(t - nanAt) < GAZE_DT_MS / 2) {
      samples.push({ at: t, nan: true });
    } else {
      samples.push({ at: t, raw: [0.72 + gauss(rng) * 0.004, 0.62 + gauss(rng) * 0.004] });
    }
    t += GAZE_DT_MS;
  }
  samples.push({ at: t, raw: [0.2, 0.7] });
  t += GAZE_DT_MS;
  // Pursuit: 0.15 norm/s rightward — a slow enough glide that the dispersion
  // filter keeps it in the fixation class, as it does for real smooth pursuit.
  const pursuitEnd = t + 1200;
  let px = 0.2;
  while (t < pursuitEnd) {
    px += 0.15 * (GAZE_DT_MS / 1000);
    samples.push({ at: t, raw: [px + gauss(rng) * 0.003, 0.7 + gauss(rng) * 0.003] });
    t += GAZE_DT_MS;
  }
  // ...then the eye stops: a closing dwell so the stream ends quiet and the
  // dot can park inside the deadband.
  dwellAt([px, 0.7], 1400);
  return samples;
}

describe("flow: a live gaze stream drives the dot", () => {
  it("saccades snap, fixations settle inside the deadband, and a NaN frame never reaches the dot", () => {
    const rng = mulberry32(7);
    const samples = scriptStream(rng);
    const filter = new SaccadeAwareGazeFilter();
    const dot = new DotFlow();
    // Interleave the ~14.5fps message stream with the 60Hz render loop on one
    // virtual clock — captured_at lands 45ms behind the tick (pipeline +
    // transport latency), which is what the capped lead is for.
    let sampleIdx = 0;
    let saccadeSnap: Vec | null = null;
    let sawNan = false;
    let lastEmitted: Vec | null = null;
    const endMs = samples[samples.length - 1].at + 600;
    for (let now = 0; now <= endMs; now += FRAME_DT_SEC * 1000) {
      while (sampleIdx < samples.length && samples[sampleIdx].at <= now) {
        const s = samples[sampleIdx];
        sampleIdx += 1;
        if (s.nan || s.raw === undefined) {
          // Feed the dead frame through the real filter: it holds the last
          // output and stores nothing (core.ts:1387) — the emit that follows
          // is still finite. Also drop a raw NaN message at the dot level —
          // updateGazeMotion's non-finite guard must bin it before the spring.
          sawNan = true;
          const held = filter.update(Number.NaN, Number.NaN, s.at, Number.NaN, Number.NaN);
          expect(held.every(Number.isFinite)).toBe(true);
          dot.onGaze({ x: Number.NaN, y: 0.4, state: "fixation" }, s.at - 45); // corrupt emit: dropped
          dot.onGaze({ x: held[0], y: held[1], state: gazeStateOf(filter) }, s.at - 45);
          lastEmitted = [...held] as Vec;
          continue;
        }
        const [fx, fy] = filter.update(s.raw[0], s.raw[1], s.at, gauss(rng), gauss(rng));
        const state = gazeStateOf(filter);
        dot.onGaze({ x: fx, y: fy, state }, s.at - 45);
        lastEmitted = [fx, fy];
        if (state === "saccade") {
          saccadeSnap = [fx, fy];
        }
      }
      dot.onFrame(now);
      const p = dot.display;
      if (p) {
        // No frame may ever paint NaN — before or after the corrupt input.
        expect(p.every(Number.isFinite)).toBe(true);
      }
    }
    expect(sawNan).toBe(true);
    // The saccade frame teleported the dot straight onto the filtered landing —
    // no spring flight across the screen.
    expect(saccadeSnap).not.toBeNull();
    expect(dot.trace.some((p) => p[0] === saccadeSnap![0] && p[1] === saccadeSnap![1])).toBe(true);
    // The closing dwell dwell-locks the filter and parks the dot inside the
    // pixel deadband of the emitted target with zero velocity.
    expect(lastEmitted).not.toBeNull();
    const residualPx = Math.hypot((dot.display![0] - lastEmitted![0]) * VIEW[0], (dot.display![1] - lastEmitted![1]) * VIEW[1]);
    expect(residualPx).toBeLessThanOrEqual(DOT_DEADBAND_PX);
    expect(dot.springVel).toEqual([0, 0]);
  });

  it("the capped lead keeps the dot closer to a moving target than un-led pursuit", () => {
    // Same moving-target message stream through two pipelines that differ only
    // in the leadTarget call — the A/B isolates the feed-forward's real effect.
    const rng = mulberry32(11);
    const led = new DotFlow();
    const unled = new DotFlow();
    unled.useLead = false; // same wiring, feed-forward term zeroed
    const speed = 0.4; // norm/s — brisk smooth pursuit
    const ledErr: number[] = [];
    const unledErr: number[] = [];
    const msgTimes: number[] = [];
    for (let i = 0; i < 30; i += 1) msgTimes.push(i * GAZE_DT_MS);
    let idx = 0;
    const targetAt = (t: number): Vec => [0.25 + speed * (t / 1000), 0.5];
    const endMs = 30 * GAZE_DT_MS;
    for (let now = 0; now <= endMs; now += FRAME_DT_SEC * 1000) {
      while (idx < msgTimes.length && msgTimes[idx] <= now) {
        const at = msgTimes[idx];
        const t = targetAt(at);
        // Small capture jitter on the stream, like the filtered output carries.
        const msg = { x: t[0] + gauss(rng) * 0.001, y: t[1] + gauss(rng) * 0.001 };
        led.onGaze({ x: msg.x, y: msg.y, state: "fixation" }, at - 45);
        unled.onGaze({ x: msg.x, y: msg.y, state: "fixation" }, at - 45);
        idx += 1;
      }
      led.onFrame(now);
      unled.onFrame(now);
      if (led.display && unled.display) {
        const truth = targetAt(now);
        ledErr.push(Math.abs(led.display[0] - truth[0]));
        unledErr.push(Math.abs(unled.display[0] - truth[0]));
      }
    }
    const mean = (a: number[]) => a.reduce((s, v) => s + v, 0) / Math.max(1, a.length);
    // The led dot must track strictly closer to the live target on average —
    // that's the whole point of the capped feed-forward.
    expect(mean(ledErr)).toBeLessThan(mean(unledErr));
    // And it must lead in the direction of motion: ahead of the un-led dot
    // for most of the pursuit, never behind it on aggregate.
    expect(mean(ledErr)).toBeLessThan(mean(unledErr) * 0.9);
  });

  it("a paused stream freezes the dot; unpausing resumes toward the current target without a teleport", () => {
    const rng = mulberry32(3);
    const dot = new DotFlow();
    // Settle on A first.
    let now = 0;
    for (; now <= 800; now += FRAME_DT_SEC * 1000) {
      if (Math.abs(now % GAZE_DT_MS) < FRAME_DT_SEC * 500) {
        dot.onGaze({ x: 0.4 + gauss(rng) * 0.003, y: 0.4 + gauss(rng) * 0.003, state: "fixation" }, now - 45);
      }
      dot.onFrame(now);
    }
    const frozenAt = dot.display!;
    expect(dot.display).not.toBeNull();
    // Pause: the user keeps looking — gaze drifts toward B in fixation-scale
    // steps (no saccade), and the dot must not move a pixel.
    dot.paused = true;
    let px = 0.4;
    let py = 0.4;
    const pauseEnd = now + 1500;
    for (; now <= pauseEnd; now += FRAME_DT_SEC * 1000) {
      if (Math.abs(now % GAZE_DT_MS) < FRAME_DT_SEC * 500) {
        px += 0.012;
        py += 0.006;
        dot.onGaze({ x: px + gauss(rng) * 0.002, y: py + gauss(rng) * 0.002, state: "fixation" }, now - 45);
      }
      dot.onFrame(now);
      expect(dot.display).toEqual(frozenAt);
      expect(dotOpacity(dot.presence, true, dot.display !== null)).toBe(0.2);
    }
    // Target kept tracking under the paused ghost.
    const lastTarget = dot.target!;
    expect(lastTarget[0]).toBeGreaterThan(0.5);
    // Unpause: the stream resumes (the worker unparks with it) with the user
    // now fixating where the drift ended. The first frames must be
    // continuous — a resume spike would paint a jump across the frozen
    // distance (~0.15 norm ≈ 280px here).
    dot.paused = false;
    const resumeFrom = [...dot.display!] as Vec;
    let maxStep = 0;
    let framesToSettle = -1;
    let prev = resumeFrom;
    const resumeEnd = now + 1600;
    let frameN = 0;
    let lastMsg: Vec = lastTarget;
    for (; now <= resumeEnd; now += FRAME_DT_SEC * 1000) {
      if (Math.abs(now % GAZE_DT_MS) < FRAME_DT_SEC * 500) {
        lastMsg = [lastTarget[0] + gauss(rng) * 0.002, lastTarget[1] + gauss(rng) * 0.002];
        dot.onGaze({ x: lastMsg[0], y: lastMsg[1], state: "fixation" }, now - 45);
      }
      dot.onFrame(now);
      const stepPx = Math.hypot((dot.display![0] - prev[0]) * VIEW[0], (dot.display![1] - prev[1]) * VIEW[1]);
      maxStep = Math.max(maxStep, stepPx);
      prev = dot.display!;
      frameN += 1;
      if (framesToSettle < 0) {
        const rPx = Math.hypot((dot.display![0] - lastTarget[0]) * VIEW[0], (dot.display![1] - lastTarget[1]) * VIEW[1]);
        if (rPx <= DOT_DEADBAND_PX) framesToSettle = frameN;
      }
    }
    // Continuous flight, not a teleport: no single frame covered even a
    // quarter of the gap, and the dot visibly flew for dozens of frames.
    const gapPx = Math.hypot((lastTarget[0] - resumeFrom[0]) * VIEW[0], (lastTarget[1] - resumeFrom[1]) * VIEW[1]);
    expect(maxStep).toBeLessThan(gapPx * 0.25);
    expect(framesToSettle).toBeGreaterThan(10);
    // And it lands inside the deadband of the chase target — the 1px slack
    // covers the residual feed-forward lead still applied to the last frame.
    const residualPx = Math.hypot((dot.display![0] - lastMsg[0]) * VIEW[0], (dot.display![1] - lastMsg[1]) * VIEW[1]);
    expect(residualPx).toBeLessThanOrEqual(DOT_DEADBAND_PX + 1);
  });

  it("a stopped stream expires on the stale watchdog and resumes snapped to the new gaze", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-21T12:00:00.000Z"));
    const dot = new DotFlow();
    dot.onGaze({ x: 0.4, y: 0.4, state: "fixation" }, Date.now() - 45);
    // The renderer re-arms the real GAZE_STALE_MS watchdog per frame.
    const cancel = scheduleGazeExpiry(Date.now(), () => dot.expire());
    vi.advanceTimersByTime(1499);
    expect(dot.presence.live).toBe(true);
    vi.advanceTimersByTime(1);
    expect(dot.presence.live).toBe(false);
    expect(dot.display).toBeNull(); // expired dot is hidden, not frozen
    expect(dotOpacity(dot.presence, false, dot.display !== null)).toBe(0);
    cancel();
    // The stream resumes somewhere else — the dot re-seeds at the new point
    // instead of flying over from the stale position.
    dot.onGaze({ x: 0.8, y: 0.2, state: "fixation" }, Date.now() - 30);
    let now = 0;
    for (; now <= 200; now += FRAME_DT_SEC * 1000) {
      dot.onFrame(now);
    }
    expect(dot.display![0]).toBeCloseTo(0.8, 2);
    expect(dot.display![1]).toBeCloseTo(0.2, 2);
  });
});

describe("flow: dwell-lock marks intent", () => {
  // A fixation pattern the way the stream really looks: ~14.5fps, ±0.004
  // positional jitter, sub-degree angle noise.
  function fixation(
    filter: SaccadeAwareGazeFilter,
    rng: () => number,
    center: Vec,
    frames: number,
    startAt: number
  ): { out: Vec; at: number } {
    let out: Vec = center;
    let at = startAt;
    for (let i = 0; i < frames; i += 1) {
      out = filter.update(
        center[0] + gauss(rng) * 0.004,
        center[1] + gauss(rng) * 0.004,
        at,
        gauss(rng) * 0.8,
        gauss(rng) * 0.8
      );
      at += GAZE_DT_MS;
    }
    return { out, at };
  }

  it("a sustained stare freezes the output and reports gaze_state dwell", () => {
    const rng = mulberry32(5);
    const filter = new SaccadeAwareGazeFilter();
    const dot = new DotFlow();
    let at = 0;
    let firstLock: Vec | null = null;
    let dwellSawMove = false;
    // ~1.4s stare at a button — long enough for the lock.
    for (let i = 0; i < 20; i += 1) {
      const out = filter.update(0.6 + gauss(rng) * 0.004, 0.45 + gauss(rng) * 0.004, at, gauss(rng) * 0.8, gauss(rng) * 0.8);
      const state = gazeStateOf(filter);
      dot.onGaze({ x: out[0], y: out[1], state }, at - 45);
      if (filter.dwellLocked && firstLock === null) firstLock = [...out] as Vec;
      if (firstLock !== null && (out[0] !== firstLock[0] || out[1] !== firstLock[1])) dwellSawMove = true;
      at += GAZE_DT_MS;
    }
    expect(firstLock).not.toBeNull();
    expect(filter.dwellLocked).toBe(true);
    expect(dwellSawMove).toBe(false); // frozen anchor — identical output
    expect(dot.presence.dwell).toBe(true); // the ring state the UI renders
  });

  it("in-window jitter keeps the lock; a real re-look releases it in one frame", () => {
    const rng = mulberry32(9);
    const filter = new SaccadeAwareGazeFilter();
    let at = 0;
    const { out, at: endAt } = fixation(filter, rng, [0.5, 0.5], 12, at);
    at = endAt;
    expect(filter.dwellLocked).toBe(true);
    // Micro-jitter at the anchor's edge (< anchorBreak 0.1) never releases.
    for (let i = 0; i < 6; i += 1) {
      const held = filter.update(0.5 + (i % 2 === 0 ? 0.06 : -0.05), 0.5, at, 0.2, -0.3);
      at += GAZE_DT_MS;
      expect(held).toEqual(out); // frozen output, not just close
    }
    expect(filter.dwellLocked).toBe(true);
    // A genuine look away (>0.1 norm ≈ 190px) releases immediately and the
    // landing passes through unsmoothed — zero added latency on the saccade.
    const landing = filter.update(0.75, 0.6, at, 14, 9);
    expect(filter.dwellLocked).toBe(false);
    expect(filter.inSaccade).toBe(true);
    expect(gazeStateOf(filter)).toBe("saccade");
    expect(landing).toEqual([0.75, 0.6]);
  });

  it("with dwell_lock off the same stare never freezes, but jitter is still smoothed", () => {
    const rng = mulberry32(13);
    const filter = new SaccadeAwareGazeFilter();
    // App.tsx:743-745 → webRuntime.ts:1216 — the menu toggle flips anchorEnabled.
    filter.anchorEnabled = false;
    const ins: number[] = [];
    const outs: Vec[] = [];
    let at = 0;
    for (let i = 0; i < 20; i += 1) {
      const x = 0.5 + gauss(rng) * 0.006;
      ins.push(x);
      outs.push(filter.update(x, 0.5 + gauss(rng) * 0.006, at, gauss(rng) * 0.8, gauss(rng) * 0.8));
      at += GAZE_DT_MS;
    }
    expect(filter.dwellLocked).toBe(false);
    const std = (a: number[]) => {
      const m = a.reduce((s, v) => s + v, 0) / a.length;
      return Math.sqrt(a.reduce((s, v) => s + (v - m) * (v - m), 0) / a.length);
    };
    expect(std(outs.map((o) => o[0]))).toBeLessThan(std(ins));
  });
});

describe("flow: blink and head-away ghost the dot", () => {
  // The runtime's frozen path (webRuntime.ts:833-894): validity state +
  // head-pose gate decide whether a frame emits normally or as a held ghost
  // coasting on its last velocity.
  function emitFrame(opts: {
    eyeOpen: number;
    eyeSpanPx?: number;
    headWidthPx?: number;
    smoothed: Vec;
    vel: Vec;
    holdStartMs: number;
    now: number;
    validity: EyeValidity;
  }): { msg: { x: number; y: number; blink: boolean; headTurned: boolean; heldReason?: string }; validity: string } {
    const validity = opts.validity.update(opts.eyeOpen, opts.now);
    const blinking = validity === "closed";
    const headTurned = isHeadTurned(opts.eyeSpanPx ?? 80, opts.headWidthPx ?? 200);
    const frozen = opts.validity.holding || headTurned;
    if (frozen) {
      const coasted = coastPosition(opts.smoothed, opts.vel, opts.now - opts.holdStartMs);
      return {
        msg: {
          x: coasted[0],
          y: coasted[1],
          blink: blinking,
          headTurned,
          heldReason: headTurned ? "head_turned" : `eye_${validity}`
        },
        validity
      };
    }
    return { msg: { x: opts.smoothed[0], y: opts.smoothed[1], blink: false, headTurned: false }, validity };
  }

  it("a blink holds, then ghosts, then returns — and coasts within bounds", () => {
    const validity = new EyeValidity();
    const dot = new DotFlow();
    const smoothed: Vec = [0.5, 0.5];
    const vel: Vec = [2, 0]; // mid-gesture velocity — coast material
    let now = 0;
    const seen: { state: string; opacity: number }[] = [];
    // Open eyes.
    for (let i = 0; i < 4; i += 1) {
      const { msg } = emitFrame({ eyeOpen: 0.9, smoothed, vel, holdStartMs: 0, now, validity });
      dot.onGaze({ x: msg.x, y: msg.y, blink: msg.blink, headTurned: msg.headTurned, heldReason: msg.heldReason, state: "fixation" }, now - 45);
      seen.push({ state: "open", opacity: dotOpacity(dot.presence, false, true) });
      now += GAZE_DT_MS;
    }
    // Lid drops mid-band → closing (held ghost, not yet a blink).
    const holdStart = now;
    const closing = emitFrame({ eyeOpen: 0.4, smoothed, vel, holdStartMs: holdStart, now, validity });
    dot.onGaze({ x: closing.msg.x, y: closing.msg.y, heldReason: closing.msg.heldReason, state: "fixation" }, now - 45);
    seen.push({ state: closing.validity, opacity: dotOpacity(dot.presence, false, true) });
    now += GAZE_DT_MS;
    // Confirmed closed → blink ghost. Position may coast, bounded.
    let coastMax = 0;
    for (let i = 0; i < 2; i += 1) {
      const f = emitFrame({ eyeOpen: 0.2, smoothed, vel, holdStartMs: holdStart, now, validity });
      dot.onGaze({ x: f.msg.x, y: f.msg.y, blink: f.msg.blink, heldReason: f.msg.heldReason, state: "fixation" }, now - 45);
      coastMax = Math.max(coastMax, Math.abs(f.msg.x - smoothed[0]));
      seen.push({ state: f.validity, opacity: dotOpacity(dot.presence, false, true) });
      now += GAZE_DT_MS;
    }
    // Reopen: two ≥0.6 frames to leave closed, then ~140ms settle still held.
    for (let i = 0; i < 3; i += 1) {
      const f = emitFrame({ eyeOpen: 0.75, smoothed, vel, holdStartMs: holdStart, now, validity });
      dot.onGaze({ x: f.msg.x, y: f.msg.y, blink: f.msg.blink, heldReason: f.msg.heldReason, state: "fixation" }, now - 45);
      seen.push({
        state: f.validity === "tracking" && validity.holding ? "tracking+settle" : f.validity,
        opacity: dotOpacity(dot.presence, false, true)
      });
      now += GAZE_DT_MS;
    }
    // Past the settle window — clean tracking.
    now += 120;
    const clear = emitFrame({ eyeOpen: 0.9, smoothed, vel, holdStartMs: holdStart, now, validity });
    dot.onGaze({ x: clear.msg.x, y: clear.msg.y, state: "fixation" }, now - 45);
    seen.push({ state: clear.validity, opacity: dotOpacity(dot.presence, false, true) });

    expect(seen.map((s) => s.state)).toEqual([
      "open", "open", "open", "open",
      "closing", // held the instant the lid drops mid-band
      "closing", // first <0.28 frame: streak 1, not yet confirmed
      "closed", // streak 2 — the confirmed blink
      "closed", // first ≥0.6 frame: reopenStreak 1, still closed
      "tracking+settle", // reopenStreak 2 → tracking, ~140ms settle hold
      "tracking+settle",
      "tracking"
    ]);
    // Opacity ladder through the sequence: live → held → ghost → held → live.
    expect(seen[0].opacity).toBe(1);
    expect(seen[4].opacity).toBe(0.4); // eye_closing — held, not ghosted
    expect(seen[6].opacity).toBe(0.18); // confirmed blink — ghost
    expect(seen[7].opacity).toBe(0.18); // still closed through the first reopen frame
    expect(seen[8].opacity).toBe(0.4); // settle hold — eye_tracking reason
    expect(seen[seen.length - 1].opacity).toBe(1);
    // Coasted displacement never exceeds the 0.045 cap regardless of velocity.
    expect(coastMax).toBeLessThanOrEqual(0.045 + 1e-9);
  });

  it("a turned head ghosts the dot and returning restores tracking", () => {
    const validity = new EyeValidity();
    const dot = new DotFlow();
    let now = 0;
    // Normal tracking: eye span 80px in a 200px head (0.4 ratio > 0.2 gate).
    const open = emitFrame({ eyeOpen: 0.9, eyeSpanPx: 80, headWidthPx: 200, smoothed: [0.5, 0.5], vel: [0, 0], holdStartMs: 0, now, validity });
    dot.onGaze({ x: open.msg.x, y: open.msg.y, state: "fixation" }, now - 45);
    expect(dotOpacity(dot.presence, false, true)).toBe(1);
    now += GAZE_DT_MS;
    // Head rotates away: the eye span collapses under the gate.
    const turned = emitFrame({ eyeOpen: 0.9, eyeSpanPx: 30, headWidthPx: 200, smoothed: [0.5, 0.5], vel: [0, 0], holdStartMs: now, now, validity });
    expect(turned.msg.headTurned).toBe(true);
    expect(turned.msg.heldReason).toBe("head_turned");
    dot.onGaze({ x: turned.msg.x, y: turned.msg.y, headTurned: true, heldReason: turned.msg.heldReason, state: "fixation" }, now - 45);
    expect(dotOpacity(dot.presence, false, true)).toBe(0.18); // ghost, not held
    now += GAZE_DT_MS;
    // Head back — next clean frame returns full tracking.
    const back = emitFrame({ eyeOpen: 0.9, eyeSpanPx: 82, headWidthPx: 200, smoothed: [0.52, 0.5], vel: [0, 0], holdStartMs: now, now, validity });
    dot.onGaze({ x: back.msg.x, y: back.msg.y, state: "fixation" }, now - 45);
    expect(dotOpacity(dot.presence, false, true)).toBe(1);
  });
});

describe("flow: calibration lifecycle", () => {
  const GRID: [number, number][] = [
    [0.5, 0.5],
    [0.08, 0.08], [0.92, 0.08], [0.92, 0.92], [0.08, 0.92],
    [0.5, 0.08], [0.92, 0.5], [0.5, 0.92], [0.08, 0.5],
    [0.3, 0.3], [0.7, 0.3], [0.7, 0.7], [0.3, 0.7]
  ];

  // The required feature fields (core.ts:3614-3618 fail isUsableSample on
  // absent position-conditioned dims) — same construction core.test.ts uses.
  function featureAt(target: [number, number], rawPoint: [number, number] = target): GazeFeature {
    return {
      point: rawPoint,
      eyeCenterPx: [320, 240],
      leftEyePx: [300, 240],
      rightEyePx: [340, 240],
      leftYawDeg: 0,
      leftPitchDeg: 0,
      rightYawDeg: 0,
      rightPitchDeg: 0,
      headWidthPx: 160,
      irisDiameterPx: 30,
      eyeOpen: 0.9,
      distanceM: 0.6,
      appYawHeadFrameX: 0,
      appYawHeadFrameY: 0,
      appPitchHeadFrameX: 0,
      appPitchHeadFrameY: 0,
      appConfHeadFrameRadius: 0
    };
  }

  function makeIO(saved: { current: string | null } = { current: null }): { io: CalibrationIO; write: ReturnType<typeof vi.fn> } {
    const write = vi.fn(async (_path: string, payload: unknown) => {
      saved.current = JSON.stringify(payload);
      return { ok: true as const, path: "cal.json" };
    });
    return {
      io: {
        read: vi.fn(async () => (saved.current === null ? { ok: true as const, text: null } : { ok: true as const, text: saved.current })),
        write
      },
      write
    };
  }

  it("missing file → onboarding gate → pursuit → verify → saved → a reload reproduces the map", async () => {
    const saved = { current: null as string | null };
    const { io, write } = makeIO(saved);
    const emitted: BackendMessage[] = [];
    const calibration = new Calibration("cal.json", (m) => emitted.push(m), io);

    // First launch: no file on disk → "missing" → the first-run card shows
    // (App.tsx:647-652 gates it on !active && !accuracy && !dismissed).
    await calibration.load();
    expect(emitted.some((m) => m.type === "calibration" && m.status === "missing")).toBe(true);
    expect(calibration.matrix).toBeNull();
    expect(calibration.featureMap).toBeNull();

    // The pursuit run the UI drives: begin → per-frame captures while each
    // waypoint dwells → end → verify sweep → end. (App.tsx:948-1011 gates
    // capture to parked waypoints; ~4 labels per point lands 52 samples.)
    calibration.beginPursuit();
    for (const target of GRID) {
      for (let i = 0; i < 4; i += 1) {
        const jitter: [number, number] = [target[0] + (i - 1.5) * 0.002, target[1] + (i - 1.5) * 0.002];
        calibration.capturePursuit(featureAt(target, jitter), target);
      }
    }
    calibration.finishPursuit();
    expect(calibration.pendingMatrix).not.toBeNull(); // fit produced a candidate
    calibration.beginVerify();
    for (let i = 0; i < 40; i += 1) {
      const target = GRID[i % GRID.length];
      calibration.captureVerifyError(featureAt(target), target);
    }
    await calibration.finishVerify();

    // Commit path: written payload carries the fit + the verify verdict, and
    // the UI sees "saved" — the message that closes the modal, flashes the
    // check and dismisses onboarding for good (App.tsx:669-681).
    expect(write).toHaveBeenCalledOnce();
    const savedEmit = emitted.find((m) => m.type === "calibration" && m.status === "saved");
    expect(savedEmit).toBeTruthy();
    expect(savedEmit && "verdict" in savedEmit ? savedEmit.verdict : undefined).toBeTruthy();
    const payload = JSON.parse(saved.current!) as { feature_version?: number; verify_verdict?: { regions: Record<string, number | undefined> } };
    expect(payload.feature_version).toBe(2);
    expect(payload.verify_verdict?.regions.corner).toBeDefined();
    // Post-calibration tracking: the committed map reproduces the targets.
    const estimate = calibration.applyFeature(featureAt([0.3, 0.7]));
    expect(Math.hypot(estimate[0] - 0.3, estimate[1] - 0.7)).toBeLessThan(0.05);

    // Next launch: the same file loads as "loaded" and the map behaves the same.
    const relog: BackendMessage[] = [];
    const reloaded = new Calibration("cal.json", (m) => relog.push(m), {
      read: vi.fn(async () => ({ ok: true as const, text: saved.current })),
      write: vi.fn(async () => ({ ok: true as const, path: "cal.json" }))
    });
    await reloaded.load();
    expect(relog.some((m) => m.type === "calibration" && m.status === "loaded")).toBe(true);
    const reEstimate = reloaded.applyFeature(featureAt([0.6, 0.25]));
    expect(Math.hypot(reEstimate[0] - 0.6, reEstimate[1] - 0.25)).toBeLessThan(0.05);
    // "missing" must not re-fire — no second onboarding.
    expect(relog.some((m) => m.type === "calibration" && m.status === "missing")).toBe(false);
  });

  it("a display/context change invalidates the saved fit and re-prompts calibration", async () => {
    // Saved under a different display/camera context: the raw-space fit is
    // stale — load drops it and, with nothing else usable, emits "invalid".
    const fileText = JSON.stringify({
      raw_projection: "unclipped-v2",
      affine: [[1, 0], [0, 1], [0, 0]],
      source_bounds: { min: [0.1, 0.1], max: [0.9, 0.9] },
      context_fingerprint: "old-display",
      feature_version: 2
    });
    const emitted: BackendMessage[] = [];
    const calibration = new Calibration("cal.json", (m) => emitted.push(m), {
      read: vi.fn(async () => ({ ok: true as const, text: fileText })),
      write: vi.fn(async () => ({ ok: true as const, path: "cal.json" }))
    });
    calibration.contextFingerprint = "new-display";
    await calibration.load();
    expect(calibration.matrix).toBeNull(); // stale raw-space fit dropped
    expect(emitted.some((m) => m.type === "calibration" && m.status === "invalid")).toBe(true);
    // Same file under the matching context loads fine — the fingerprint is
    // the gate, not the data.
    const matched: BackendMessage[] = [];
    const okCal = new Calibration("cal.json", (m) => matched.push(m), {
      read: vi.fn(async () => ({ ok: true as const, text: fileText })),
      write: vi.fn(async () => ({ ok: true as const, path: "cal.json" }))
    });
    okCal.contextFingerprint = "old-display";
    await okCal.load();
    expect(okCal.matrix).not.toBeNull();
    expect(matched.some((m) => m.type === "calibration" && m.status === "loaded")).toBe(true);
  });

  it("a short pursuit rejects; a failed save surfaces the retryable status", async () => {
    // Abandoned run — 10 of the 16 waypoints, under the 24-sample floor.
    const { io } = makeIO();
    const emitted: BackendMessage[] = [];
    const cal = new Calibration("cal.json", (m) => emitted.push(m), io);
    cal.beginPursuit();
    for (const target of GRID.slice(0, 10)) {
      cal.capturePursuit(featureAt(target), target);
    }
    cal.finishPursuit();
    const rejected = emitted.find((m) => m.type === "calibration" && m.status === "rejected_fit");
    expect(rejected).toBeTruthy();
    expect(cal.pendingMatrix).toBeNull();
    // App.tsx:682-696 retries rejected_fit twice — a different path than
    // shouldRetryCalibrationCapture, which only covers the save write.
    expect(shouldRetryCalibrationCapture("rejected_fit")).toBe(false);

    // Verify passes but the disk write fails → save_failed → App shows the
    // retryable-capture notice (App.tsx:698-700 via the real predicate).
    const failingIO: CalibrationIO = {
      read: vi.fn(async () => ({ ok: true as const, text: null })),
      write: vi.fn(async () => ({ ok: false as const, error: "disk full" }))
    };
    const emitted2: BackendMessage[] = [];
    const cal2 = new Calibration("cal.json", (m) => emitted2.push(m), failingIO);
    cal2.beginPursuit();
    for (const target of GRID) {
      for (let i = 0; i < 4; i += 1) cal2.capturePursuit(featureAt(target), target);
    }
    cal2.finishPursuit();
    cal2.beginVerify();
    for (let i = 0; i < 36; i += 1) {
      const target = GRID[i % GRID.length];
      cal2.captureVerifyError(featureAt(target), target);
    }
    await cal2.finishVerify();
    const failed = emitted2.find((m) => m.type === "calibration" && m.status === "save_failed");
    expect(failed).toBeTruthy();
    expect(shouldRetryCalibrationCapture("save_failed")).toBe(true);
  });
});

describe("flow: filters under realistic streams", () => {
  it("the saccade filter suppresses fixation jitter but passes a saccade through unsmoothed", () => {
    const rng = mulberry32(17);
    const filter = new SaccadeAwareGazeFilter();
    const ins: Vec[] = [];
    const outs: Vec[] = [];
    let at = 0;
    // Fixation noise at ~14.5fps — inside fixRadius of the cluster mean.
    for (let i = 0; i < 10; i += 1) {
      const x = 0.4 + gauss(rng) * 0.006;
      const y = 0.5 + gauss(rng) * 0.006;
      ins.push([x, y]);
      outs.push(filter.update(x, y, at, gauss(rng) * 0.8, gauss(rng) * 0.8));
      at += GAZE_DT_MS;
    }
    // A real saccade: one frame to the new point + a coherent angle jump.
    const sx = 0.75;
    const sy = 0.35;
    const landed = filter.update(sx, sy, at, 22, -14);
    expect(filter.inSaccade).toBe(true);
    expect(gazeStateOf(filter)).toBe("saccade");
    // Zero added latency — the output IS the landing point.
    expect(landed).toEqual([sx, sy]);
    // Jitter suppression measured on the fixation segment (skip the first
    // frames' transient): output spread is a fraction of input spread.
    const spread = (pts: Vec[]) => {
      const mx = pts.reduce((s, p) => s + p[0], 0) / pts.length;
      const my = pts.reduce((s, p) => s + p[1], 0) / pts.length;
      return Math.sqrt(pts.reduce((s, p) => s + (p[0] - mx) ** 2 + (p[1] - my) ** 2, 0) / pts.length);
    };
    expect(spread(outs.slice(4))).toBeLessThan(spread(ins.slice(4)) * 0.7);
  });

  it("one-euro smooths a stationary stare without dragging a deliberate step", () => {
    const rng = mulberry32(23);
    const filter = new OneEuroFilter(1.0, 0.7, 1.0); // shipped defaults
    let at = 0;
    const ins: number[] = [];
    const outs: number[] = [];
    // ~1s of stationary jitter at render cadence (the filter runs at frame rate).
    for (let i = 0; i < 60; i += 1) {
      const x = 0.5 + gauss(rng) * 0.005;
      ins.push(x);
      outs.push(filter.filter(x, at));
      at += FRAME_DT_SEC;
    }
    const stdIn = Math.sqrt(ins.reduce((s, v) => s + (v - 0.5) ** 2, 0) / ins.length);
    const meanOut = outs.reduce((s, v) => s + v, 0) / outs.length;
    const stdOut = Math.sqrt(outs.reduce((s, v) => s + (v - meanOut) ** 2, 0) / outs.length);
    const maxExcursion = Math.max(...outs.map((o) => Math.abs(o - 0.5)));
    expect(stdOut).toBeLessThan(stdIn * 0.8); // jitter suppressed
    // …and in product terms: a ±0.005 stare never moves the output beyond
    // ~2% of the screen (~48px).
    expect(maxExcursion).toBeLessThan(0.025);
    // Deliberate move: the adaptive cutoff must track a step fast — >90% of
    // the way there within ~350ms, not the seconds a fixed low-pass takes.
    let settleFrames = -1;
    for (let i = 0; i < 60; i += 1) {
      const out = filter.filter(0.8 + gauss(rng) * 0.005, at);
      at += FRAME_DT_SEC;
      if (settleFrames < 0 && Math.abs(out - 0.8) < 0.03) settleFrames = i;
    }
    expect(settleFrames).toBeGreaterThanOrEqual(0);
    expect(settleFrames).toBeLessThan(22); // < ~370ms to the new point
  });
});
