import { describe, expect, it } from "vitest";
import { CAPTURE_RUN, PointRun, VERIFY_RUN, easeOutQuint } from "./calibrationRun";

const NINE: [number, number][] = [
  [0.5, 0.5],
  [0.09, 0.09], [0.5, 0.09], [0.91, 0.09],
  [0.91, 0.5], [0.91, 0.91], [0.5, 0.91],
  [0.09, 0.91], [0.09, 0.5],
  [0.5, 0.5]
];

// Drives a run at the display's 60 Hz while a tracker captures one labelled
// frame every frameMs whenever the target is parked and the frame is usable.
function simulate(frameMs: number, usable: (frame: number) => boolean, options = CAPTURE_RUN) {
  let now = 0;
  const run = new PointRun(NINE, options, now);
  let captured = 0;
  let nextFrameAt = frameMs;
  let frame = 0;
  let parked = false;
  const perPoint: number[] = [];
  let lastProgress = 0;
  while (now < 120_000) {
    if (now >= nextFrameAt) {
      nextFrameAt += frameMs;
      frame += 1;
      if (parked && usable(frame)) captured += 1;
    }
    const step = run.step(now, captured);
    expect(step.progress).toBeGreaterThanOrEqual(lastProgress);
    lastProgress = step.progress;
    if (step.done) return { ms: now, captured, perPoint };
    if (parked && !step.parked) perPoint.push(captured);
    parked = step.parked;
    now += 1000 / 60;
  }
  throw new Error("run never finished");
}

describe("point calibration run", () => {
  it("collects enough frames at the owner's measured 10 fps to pass the 24-sample fit gate", () => {
    const { ms, captured } = simulate(100, () => true);
    expect(captured).toBeGreaterThanOrEqual(NINE.length * CAPTURE_RUN.samplesPerPoint);
    expect(captured).toBeGreaterThanOrEqual(24);
    // About fifteen seconds, not the old twenty-plus.
    expect(ms).toBeLessThan(16_000);
  });

  it("waits out stalls and dropped frames instead of running out of time", () => {
    // Two of every three frames fail the quality gates (blink, pose, stall).
    const { captured } = simulate(100, (frame) => frame % 3 === 0);
    expect(captured).toBeGreaterThanOrEqual(24);
  });

  it("skips a point that collects nothing instead of hanging", () => {
    const { ms, captured } = simulate(100, () => false);
    expect(captured).toBe(0);
    expect(ms).toBeLessThan(NINE.length * (CAPTURE_RUN.maxParkMs + CAPTURE_RUN.glideMs) + CAPTURE_RUN.leadInMs + 500);
  });

  it("stops the park clock while sampling is blocked", () => {
    const run = new PointRun([[0.2, 0.2], [0.8, 0.8]], VERIFY_RUN, 0);
    run.step(VERIFY_RUN.leadInMs, 0);
    for (let t = VERIFY_RUN.leadInMs; t < VERIFY_RUN.leadInMs + 10_000; t += 16) {
      expect(run.step(t, 0, true).pos).toEqual([0.2, 0.2]);
    }
  });

  it("steps straight to the next point when motion is reduced", () => {
    const run = new PointRun([[0.2, 0.2], [0.8, 0.8]], { ...VERIFY_RUN, glideMs: 0 }, 0);
    run.step(VERIFY_RUN.leadInMs, 0);
    expect(run.step(VERIFY_RUN.leadInMs + 16, VERIFY_RUN.samplesPerPoint).parked).toBe(false);
    const next = run.step(VERIFY_RUN.leadInMs + 16, VERIFY_RUN.samplesPerPoint);
    expect(next.pos).toEqual([0.8, 0.8]);
    expect(next.parked).toBe(true);
  });

  it("glides with a strong ease-out and never overshoots", () => {
    expect(easeOutQuint(0)).toBe(0);
    expect(easeOutQuint(0.2)).toBeGreaterThan(0.6);
    expect(easeOutQuint(1)).toBe(1);
    expect(easeOutQuint(2)).toBe(1);
  });
});
