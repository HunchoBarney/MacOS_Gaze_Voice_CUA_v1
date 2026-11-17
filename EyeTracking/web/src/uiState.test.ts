import { afterEach, describe, expect, it, vi } from "vitest";
import { advanceDotSpring, headTilted, isSaccadeJump, leadTarget, scheduleGazeExpiry, shouldRetryCalibrationCapture, DOT_EXTRAPOLATE_MAX_SEC, HEAD_TILT_LIMIT_DEG, TILT_CLEAR_MS } from "./uiState";

afterEach(() => {
  vi.useRealTimers();
});

describe("calibration UI state", () => {
  it("retries the current capture when saving the calibration fails", () => {
    expect(shouldRetryCalibrationCapture("save_failed")).toBe(true);
    expect(shouldRetryCalibrationCapture("saved")).toBe(false);
  });
});

describe("gaze UI state", () => {
  it("expires a gaze sample after tracking stops", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-21T00:00:00.000Z"));
    const onExpired = vi.fn();

    const cancel = scheduleGazeExpiry(Date.now(), onExpired);
    vi.advanceTimersByTime(1499);
    expect(onExpired).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(onExpired).toHaveBeenCalledOnce();
    cancel();
  });
});

describe("saccade detection", () => {
  it("snaps on a stream-flagged saccade regardless of distance", () => {
    expect(isSaccadeJump("saccade", [0.1, 0.1], [0.15, 0.1])).toBe(true);
  });

  it("snaps on a large geometric jump without a flag", () => {
    expect(isSaccadeJump(undefined, [0.1, 0.1], [0.5, 0.5])).toBe(true);
  });

  it("does not snap on fixation-scale jitter or first frame", () => {
    expect(isSaccadeJump("fixation", [0.1, 0.1], [0.102, 0.101])).toBe(false);
    expect(isSaccadeJump(undefined, null, [0.5, 0.5])).toBe(false);
  });
});

describe("feed-forward lead", () => {
  it("leads the target along velocity by the sample age, capped", () => {
    const led = leadTarget([0.5, 0.5], [2, 0], 0.02);
    expect(led[0]).toBeCloseTo(0.54, 6);
    // Past the cap the lead stops growing — ~2 frames max, not 100ms.
    const capped = leadTarget([0.5, 0.5], [2, 0], 5);
    expect(capped[0]).toBeCloseTo(0.5 + 2 * DOT_EXTRAPOLATE_MAX_SEC, 6);
    expect(leadTarget([0.5, 0.5], [2, 0], -1)).toEqual([0.5, 0.5]);
  });
});

describe("dot spring", () => {
  const view: [number, number] = [1000, 1000];

  it("converges to the target within the pixel deadband", () => {
    // Real cadence: 60Hz dt — the regime the render loop actually runs in.
    let motion = { pos: [0.1, 0.1] as [number, number], vel: [0, 0] as [number, number] };
    for (let i = 0; i < 240; i += 1) {
      motion = advanceDotSpring(motion.pos, motion.vel, [0.5, 0.5], 1 / 60, view);
    }
    expect(Math.abs(motion.pos[0] - 0.5) * view[0]).toBeLessThanOrEqual(1.5);
    expect(Math.abs(motion.pos[1] - 0.5) * view[1]).toBeLessThanOrEqual(1.5);
  });

  it("converges within the deadband at high refresh rates", () => {
    // 240Hz: the deadband must still park within its own radius.
    let motion = { pos: [0.1, 0.1] as [number, number], vel: [0, 0] as [number, number] };
    for (let i = 0; i < 960; i += 1) {
      motion = advanceDotSpring(motion.pos, motion.vel, [0.5, 0.5], 1 / 240, view);
    }
    expect(Math.abs(motion.pos[0] - 0.5) * view[0]).toBeLessThanOrEqual(1.5);
  });

  it("never overshoots a retarget — critically damped", () => {
    // Step target mid-flight: the dot must approach monotonically, never
    // cross past the goal. Overshoot here reads as visible saccade jitter.
    let motion = { pos: [0.1, 0.1] as [number, number], vel: [0, 0] as [number, number] };
    for (let i = 0; i < 60; i += 1) {
      motion = advanceDotSpring(motion.pos, motion.vel, [0.3, 0.3], 1 / 60, view);
    }
    // Retarget to a point back the way we came, mid-velocity.
    for (let i = 0; i < 120; i += 1) {
      motion = advanceDotSpring(motion.pos, motion.vel, [0.15, 0.15], 1 / 60, view);
      expect(motion.pos[0]).toBeGreaterThanOrEqual(0.15 - 0.002);
    }
  });

  it("keeps motion continuous across a retarget — no velocity kick", () => {
    // The exponential chase recomputed a fresh step each frame; the spring's
    // per-frame delta must vary smoothly instead of jumping at retarget.
    let motion = { pos: [0.1, 0.1] as [number, number], vel: [0, 0] as [number, number] };
    for (let i = 0; i < 30; i += 1) {
      motion = advanceDotSpring(motion.pos, motion.vel, [0.5, 0.5], 1 / 60, view);
    }
    const before = motion.pos[0];
    motion = advanceDotSpring(motion.pos, motion.vel, [0.6, 0.5], 1 / 60, view);
    // First frame after a retarget moves <5px — no impulse discontinuity.
    expect(Math.abs(motion.pos[0] - before) * view[0]).toBeLessThan(5);
  });

  it("parks inside the deadband once quiet", () => {
    const motion = advanceDotSpring([0.5, 0.5], [0, 0], [0.5005, 0.5003], 1 / 60, view);
    expect(motion.pos).toEqual([0.5, 0.5]);
    expect(motion.vel).toEqual([0, 0]);
  });
});

describe("head tilt gate", () => {
  it("flags yaw or pitch beyond the default limit, either direction", () => {
    expect(headTilted(HEAD_TILT_LIMIT_DEG + 0.1, 0)).toBe(true);
    expect(headTilted(-(HEAD_TILT_LIMIT_DEG + 0.1), 0)).toBe(true);
    expect(headTilted(0, HEAD_TILT_LIMIT_DEG + 0.1)).toBe(true);
    expect(headTilted(0, -(HEAD_TILT_LIMIT_DEG + 0.1))).toBe(true);
    // One bad axis is enough — the other being level doesn't rescue it.
    expect(headTilted(40, 2)).toBe(true);
  });

  it("does not flag pose at or inside the limit", () => {
    // Boundary is exclusive: exactly the limit is still clean.
    expect(headTilted(HEAD_TILT_LIMIT_DEG, HEAD_TILT_LIMIT_DEG)).toBe(false);
    expect(headTilted(-HEAD_TILT_LIMIT_DEG, -HEAD_TILT_LIMIT_DEG)).toBe(false);
    expect(headTilted(0, 0)).toBe(false);
    expect(headTilted(11.9, -11.9)).toBe(false);
  });

  it("never blocks on absent telemetry", () => {
    expect(headTilted()).toBe(false);
    expect(headTilted(undefined, undefined)).toBe(false);
    // A missing angle on one axis doesn't mask a real tilt on the other.
    expect(headTilted(undefined, 30)).toBe(true);
    expect(headTilted(30, undefined)).toBe(true);
    expect(headTilted(undefined, 5)).toBe(false);
  });

  it("treats non-finite angles as absent rather than tilted", () => {
    // Garbage telemetry must not stall a calibration run.
    expect(headTilted(NaN, 0)).toBe(false);
    expect(headTilted(0, NaN)).toBe(false);
    expect(headTilted(Number.POSITIVE_INFINITY, 0)).toBe(false);
    expect(headTilted(0, Number.NEGATIVE_INFINITY)).toBe(false);
  });

  it("honors a custom threshold", () => {
    expect(headTilted(20, 0)).toBe(true);
    expect(headTilted(20, 0, { thresholdDeg: 25 })).toBe(false);
    expect(headTilted(0, -30, { thresholdDeg: 25 })).toBe(true);
    expect(headTilted(0, -25, { thresholdDeg: 25 })).toBe(false);
  });

  it("exports a positive settle window for the hold hysteresis", () => {
    // The App-side gate reopens only after this much level pose.
    expect(TILT_CLEAR_MS).toBeGreaterThanOrEqual(200);
    expect(TILT_CLEAR_MS).toBeLessThanOrEqual(1000);
  });
});
