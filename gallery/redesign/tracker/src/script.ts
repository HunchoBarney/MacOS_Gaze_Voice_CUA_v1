// The fixture script every direction plays. One scripted clock, no camera,
// no worker, no model. Times are milliseconds of product time. The point
// layout is the tracker's "standard" tier (EyeTracking/web/src/App.tsx,
// CALIBRATION_TIERS.standard) and the verify pass is VERIFY_WAYPOINTS, minus
// the centre bookends. Dwell is paced faster than a real 10 fps run so the
// whole flow fits in about 18 s of video.

import timeline from "./timeline.json";

export type Phase = "intro" | "look" | "ready" | "capture" | "verify" | "check" | "success" | "failure" | "done";
export type Scenario = "happy" | "fail";

export const POINTS: [number, number][] = [
  [0.5, 0.5],
  [0.09, 0.09], [0.5, 0.09], [0.91, 0.09],
  [0.91, 0.5], [0.91, 0.91], [0.5, 0.91],
  [0.09, 0.91], [0.09, 0.5]
];
export const VERIFY: [number, number][] = [[0.32, 0.3], [0.68, 0.3], [0.68, 0.7], [0.32, 0.7]];
// The fail scenario's verdict: the points the verify pass couldn't read.
export const WEAK = [7, 8];

export const T = timeline.T;

// Within a capture point: when its dwell runs (ms from the point's start).
export const dwellOf = (k: number) => (k === 0 ? { delay: 120, duration: 820 } : { delay: T.glide + 40, duration: T.point - T.glide - 80 });

export type ScriptState = { phase: Phase; k: number; pressed: "start" | "retry" | null; attempt: number };

export function at(t: number, scenario: Scenario): ScriptState {
  if (scenario === "fail" && t >= T.success) {
    if (t < T.retry) return { phase: "failure", k: -1, pressed: t >= T.failPress ? "retry" : null, attempt: 1 };
    const back = T.look + (t - T.retry);
    const s = at(Math.min(back, T.verify - 1), "happy");
    return { ...s, attempt: 2 };
  }
  if (t < T.look) return { phase: "intro", k: -1, pressed: t >= T.press ? "start" : null, attempt: 1 };
  if (t < T.ready) return { phase: "look", k: -1, pressed: null, attempt: 1 };
  if (t < T.capture) return { phase: "ready", k: 0, pressed: null, attempt: 1 };
  if (t < T.verify) return { phase: "capture", k: Math.floor((t - T.capture) / T.point), pressed: null, attempt: 1 };
  if (t < T.check) return { phase: "verify", k: Math.floor((t - T.verify) / T.verifyPoint), pressed: null, attempt: 1 };
  if (t < T.success) return { phase: "check", k: -1, pressed: null, attempt: 1 };
  if (t < T.done) return { phase: "success", k: -1, pressed: null, attempt: 1 };
  return { phase: "done", k: -1, pressed: null, attempt: 1 };
}

