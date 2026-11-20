import { describe, expect, it, vi } from "vitest";
import { Calibration, GazeAngleSmoother } from "./core";
import type { GazeEstimate, GazeFeature } from "./core";

// Recorded calibration pool, when this checkout has one — the file is
// gitignored local state, so the glob stays empty elsewhere and the replay
// test reports the skip instead of failing.
const fixtureTexts = import.meta.glob("../../../.gaze_calibration.json", { query: "?raw", import: "default", eager: true }) as Record<
  string,
  string
>;

// ---------------------------------------------------------------------------
// Wave-3 temporal-model spike: measurement for the estimate-path smoother.
// The live accuracy_report.json needs a human + camera; what's measurable
// here is (a) a seeded synthetic dwell/saccade/glitch stream through the real
// GazeAngleSmoother vs a reimplementation of the pre-spike EMA+snap behavior,
// and (b) a replay of the recorded calibration feature pool through the
// stored feature map.
// ---------------------------------------------------------------------------

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

type Quad = [number, number, number, number];

// The pre-spike behavior: plain EMA + unconditional snap at snapDeg. Kept
// local so the measurement compares shipped-vs-old, not shipped-vs-itself.
class LegacyAngleSmoother {
  private smoothed: Quad | null = null;
  constructor(private alpha = 0.5, private snapDeg = 12) {}
  update(raw: Quad): Quad {
    if (this.smoothed === null) {
      this.smoothed = raw.slice() as Quad;
    } else {
      const md = Math.max(...raw.map((v, i) => Math.abs(v - this.smoothed![i])));
      if (md > this.snapDeg) {
        this.smoothed = raw.slice() as Quad;
      } else {
        for (let i = 0; i < 4; i += 1) this.smoothed[i] += this.alpha * (raw[i] - this.smoothed[i]);
      }
    }
    return this.smoothed.slice() as Quad;
  }
}

function estimateOf(raw: Quad): GazeEstimate {
  return {
    yawDeg: (raw[0] + raw[2]) / 2,
    pitchDeg: (raw[1] + raw[3]) / 2,
    leftYawDeg: raw[0],
    leftPitchDeg: raw[1],
    rightYawDeg: raw[2],
    rightPitchDeg: raw[3],
    irisDiameterPx: 30,
    eyeOpen: 0.9,
    agreement: 1
  };
}

interface Stream {
  truth: Quad[];
  meas: Quad[];
  glitch: boolean[];
  seg: number[];
}

// Dwell segments (fixed gaze), every 4th segment a smooth-pursuit ramp, plus
// single-/double-frame glitches (80% one eye — the z-collapse signature).
function genStream(
  rng: () => number,
  { steps = 40, dwellMin = 30, dwellMax = 60, sigma = 2, glitchP = 0.08, glitchLenMax = 1 } = {}
): Stream {
  const truth: Quad[] = [];
  const meas: Quad[] = [];
  const glitch: boolean[] = [];
  const seg: number[] = [];
  for (let s = 0; s < steps; s += 1) {
    const dwell = dwellMin + Math.floor(rng() * (dwellMax - dwellMin));
    const yaw = -25 + rng() * 50;
    const pitch = -15 + rng() * 30;
    const pos: Quad = [yaw + gauss(rng) * 1.5, pitch + gauss(rng) * 1.5, yaw + gauss(rng) * 1.5, pitch + gauss(rng) * 1.5];
    const isRamp = s % 4 === 3;
    const prev = truth.length ? truth[truth.length - 1] : pos;
    let gRemain = 0;
    for (let i = 0; i < dwell; i += 1) {
      const k = isRamp ? i / dwell : 1;
      const cur = prev.map((p, c) => p + (pos[c] - p) * k) as Quad;
      truth.push(cur);
      seg.push(s);
      const m = cur.map((v) => v + gauss(rng) * sigma) as Quad;
      if (gRemain > 0 || rng() < glitchP) {
        gRemain = gRemain > 0 ? gRemain - 1 : Math.floor(rng() * glitchLenMax);
        const ch = Math.floor(rng() * 4);
        m[ch] += (rng() < 0.5 ? -1 : 1) * (8 + rng() * 12);
        glitch.push(true);
      } else {
        glitch.push(false);
      }
      meas.push(m);
    }
  }
  return { truth, meas, glitch, seg };
}

interface Metrics {
  median: number;
  p90: number;
  max: number;
  lag3Med: number;
  lag3P90: number;
  glitchMean: number;
  rampMed: number;
}

function evaluate(update: (raw: Quad) => Quad, stream: Stream, grace = 5): Metrics {
  const out = stream.meas.map((m) => update(m));
  const errs: number[] = [];
  const glitchErrs: number[] = [];
  const lag3: number[] = [];
  const rampErrs: number[] = [];
  let segStart = 0;
  for (let i = 0; i < stream.truth.length; i += 1) {
    const T = stream.truth[i];
    const e = Math.max(...out[i].map((v, k) => Math.abs(v - T[k])));
    if (i > 0 && stream.seg[i] !== stream.seg[i - 1]) {
      let s = 0;
      let n = 0;
      for (let j = i; j < Math.min(i + 3, stream.truth.length) && stream.seg[j] === stream.seg[i]; j += 1) {
        s += Math.max(...out[j].map((v, k) => Math.abs(v - stream.truth[i][k])));
        n += 1;
      }
      if (n) lag3.push(s / n);
      segStart = i;
    }
    if (i - segStart >= grace) errs.push(e);
    if (stream.glitch[i]) glitchErrs.push(e);
    if (stream.seg[i] % 4 === 3) rampErrs.push(e);
  }
  const med = (a: number[]) => a.slice().sort((x, y) => x - y)[Math.floor(a.length / 2)] ?? 0;
  const sorted = errs.slice().sort((a, b) => a - b);
  const lags = lag3.slice().sort((a, b) => a - b);
  return {
    median: med(errs),
    p90: sorted[Math.floor(sorted.length * 0.9)],
    max: sorted[sorted.length - 1],
    lag3Med: lags[Math.floor(lags.length / 2)] ?? 0,
    lag3P90: lags[Math.floor(lags.length * 0.9)] ?? 0,
    glitchMean: glitchErrs.reduce((s, e) => s + e, 0) / Math.max(1, glitchErrs.length),
    rampMed: med(rampErrs)
  };
}

function runSuite(glitchLenMax: number): Record<"old" | "new", Metrics> {
  const agg = { old: [] as Metrics[], new: [] as Metrics[] };
  for (let seed = 1; seed <= 16; seed += 1) {
    const stream = genStream(mulberry32(seed), { glitchLenMax });
    const legacy = new LegacyAngleSmoother();
    const modern = new GazeAngleSmoother();
    agg.old.push(evaluate((raw) => legacy.update(raw), stream));
    agg.new.push(evaluate((raw) => {
      const g = modern.update(estimateOf(raw), seed);
      return [g.leftYawDeg, g.leftPitchDeg, g.rightYawDeg, g.rightPitchDeg];
    }, stream));
  }
  const mean = (arr: Metrics[], k: keyof Metrics) => arr.reduce((s, m) => s + m[k], 0) / arr.length;
  const pack = (arr: Metrics[]): Metrics => ({
    median: mean(arr, "median"),
    p90: mean(arr, "p90"),
    max: mean(arr, "max"),
    lag3Med: mean(arr, "lag3Med"),
    lag3P90: mean(arr, "lag3P90"),
    glitchMean: mean(arr, "glitchMean"),
    rampMed: mean(arr, "rampMed")
  });
  return { old: pack(agg.old), new: pack(agg.new) };
}

describe("temporal estimate smoother — measured", () => {
  it("median-window + coherent snap beats the legacy EMA on dwell error without added lag", () => {
    for (const lenMax of [1, 2]) {
      const { old: o, new: n } = runSuite(lenMax);
      console.info(
        `[temporal-measure] glitchLen=${lenMax} ` +
          `median ${o.median.toFixed(3)}→${n.median.toFixed(3)} p90 ${o.p90.toFixed(3)}→${n.p90.toFixed(3)} ` +
          `max ${o.max.toFixed(1)}→${n.max.toFixed(1)} glitch ${o.glitchMean.toFixed(1)}→${n.glitchMean.toFixed(1)} ` +
          `lag3 ${o.lag3Med.toFixed(2)}→${n.lag3Med.toFixed(2)} ramp ${o.rampMed.toFixed(2)}→${n.rampMed.toFixed(2)}`
      );
      expect(n.median).toBeLessThan(o.median * 0.9);
      expect(n.p90).toBeLessThan(o.p90 * 0.8);
      expect(n.glitchMean).toBeLessThan(o.glitchMean * 0.5);
      // Step response: the win must not be bought with lag — coherent
      // saccades snap as fast as the legacy unconditional snap did.
      expect(n.lag3Med).toBeLessThanOrEqual(o.lag3Med + 1.5);
      // Slow-pursuit tracking must not degrade either.
      expect(n.rampMed).toBeLessThanOrEqual(o.rampMed * 1.15);
    }
  });

  it("single-frame per-eye collapse never reaches the output; coherent saccade snaps in one frame", () => {
    const s = new GazeAngleSmoother();
    const dwell: Quad = [4, 2, 4.5, 2.2];
    for (let i = 0; i < 12; i += 1) s.update(estimateOf(dwell), i * 33);
    const before = s.update(estimateOf(dwell), 400);
    // One-eye 18° spike — over snapDeg but incoherent: not a saccade.
    const glitch: Quad = [dwell[0] + 18, dwell[1], dwell[2], dwell[3]];
    const out = s.update(estimateOf(glitch), 433);
    expect(Math.abs(out.leftYawDeg - before.leftYawDeg)).toBeLessThan(2);
    const after = s.update(estimateOf(dwell), 466);
    expect(Math.abs(after.leftYawDeg - before.leftYawDeg)).toBeLessThan(2);
    // Coherent 20° saccade snaps immediately — no extra frame of lag.
    const saccade: Quad = [dwell[0] + 20, dwell[1] + 20, dwell[2] + 20, dwell[3] + 20];
    const snapped = s.update(estimateOf(saccade), 499);
    expect(snapped.leftYawDeg).toBeCloseTo(saccade[0], 6);
    // Incoherent-but-persistent move (real asymmetry) confirms on frame 2.
    const s2 = new GazeAngleSmoother();
    for (let i = 0; i < 12; i += 1) s2.update(estimateOf(dwell), i * 33);
    const moved: Quad = [dwell[0] + 16, dwell[1], dwell[2], dwell[3]];
    s2.update(estimateOf(moved), 400);
    const confirmed = s2.update(estimateOf(moved), 433);
    expect(confirmed.leftYawDeg).toBeCloseTo(moved[0], 6);
  });

  // Replay the persisted calibration pool through the stored feature map:
  // dwell runs of consecutive same-target frames are the closest recorded
  // analog of the accuracy test's stare windows.
  it("does not regress real recorded dwell samples", async () => {
    const text = Object.values(fixtureTexts)[0];
    if (text === undefined) {
      console.info("[temporal-measure] no recorded calibration fixture — skipping replay");
      return;
    }
    const payload = JSON.parse(text);
    const samples = (payload.feature_samples ?? []) as Array<{ feature: GazeFeature; target: [number, number] }>;
    if (samples.length === 0) return;
    const calibration = new Calibration("fixture", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "fixture" })
    });
    await calibration.load();
    expect(calibration.featureMap ?? calibration.matrix).not.toBeNull();
    // Group into consecutive same-target runs — dwell segments.
    const runs: Array<Array<{ feature: GazeFeature; target: [number, number] }>> = [];
    for (const s of samples) {
      const last = runs[runs.length - 1];
      if (last && Math.hypot(s.target[0] - last[0].target[0], s.target[1] - last[0].target[1]) < 0.01) {
        last.push(s);
      } else {
        runs.push([s]);
      }
    }
    const angleKeys = ["leftYawDeg", "leftPitchDeg", "rightYawDeg", "rightPitchDeg"] as const;
    const errorsBase: number[] = [];
    const errorsSmoothed: number[] = [];
    for (const run of runs) {
      if (run.length < 4) continue;
      const smoother = new GazeAngleSmoother();
      for (const { feature, target } of run) {
        const raw = angleKeys.map((k) => feature[k]) as Quad;
        const g = smoother.update(estimateOf(raw), 0);
        errorsBase.push(Math.hypot(calibration.applyFeature(feature)[0] - target[0], calibration.applyFeature(feature)[1] - target[1]));
        const smoothedFeature = { ...feature, leftYawDeg: g.leftYawDeg, leftPitchDeg: g.leftPitchDeg, rightYawDeg: g.rightYawDeg, rightPitchDeg: g.rightPitchDeg };
        errorsSmoothed.push(Math.hypot(calibration.applyFeature(smoothedFeature)[0] - target[0], calibration.applyFeature(smoothedFeature)[1] - target[1]));
      }
    }
    if (errorsBase.length === 0) return;
    const med = (a: number[]) => a.slice().sort((x, y) => x - y)[Math.floor(a.length / 2)];
    console.info(
      `[temporal-measure] fixture dwell replay n=${errorsBase.length} median ${med(errorsBase).toFixed(4)}→${med(errorsSmoothed).toFixed(4)}`
    );
    // The recorded features are already EMA-smoothed upstream, so this only
    // needs to show the extra temporal stage doesn't hurt real data.
    expect(med(errorsSmoothed)).toBeLessThanOrEqual(med(errorsBase) * 1.1 + 0.001);
  });
});
