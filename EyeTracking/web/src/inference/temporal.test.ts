import { describe, expect, it, vi } from "vitest";
import { Calibration, GazeAngleSmoother } from "./core";
import type { GazeFeature } from "./core";
import { estimateOf, expectSmootherBeatsLegacy, type Quad } from "./temporalMeasure";

// Recorded calibration pool, when this checkout has one. The file is
// gitignored local state, so the glob stays empty elsewhere and the replay
// test is reported as skipped.
const fixtureTexts = import.meta.glob("../../../.gaze_calibration.json", { query: "?raw", import: "default", eager: true }) as Record<
  string,
  string
>;
const fixtureText = Object.values(fixtureTexts)[0];

describe("temporal estimate smoother — measured", () => {
  // A few seeds of the corpus temporal.slow.test.ts runs at 16.
  it("median-window + coherent snap beats the legacy EMA on a 4-seed corpus", () => {
    expectSmootherBeatsLegacy(4);
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
  it.skipIf(fixtureText === undefined)("does not regress real recorded dwell samples", async () => {
    const payload = JSON.parse(fixtureText!);
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
