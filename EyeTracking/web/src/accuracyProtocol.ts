// JARA-27 gaze accuracy protocol v1 (Captain drive: handoffs/
// JARA-27-gaze-appendix.md) — the scoring half of --accuracy-test and
// --hit-test. Screen positions are display points; angles use
// θ = atan(e_mm / D) with D the tape-measured distance when the run was given
// one (--viewing-distance-cm), else the tracker's own median distance_m.
import { regionOfTarget } from "./inference/core";

export type Point = [number, number];
type Region = "center" | "edge" | "corner";

// Step 2: 16 held-out targets on a 4×4 grid at 10/37/63/90% of each axis.
export const ACCURACY_GRID: Point[] = [0.1, 0.37, 0.63, 0.9].flatMap((y) => [0.1, 0.37, 0.63, 0.9].map((x) => [x, y] as Point));
// Step 3: radii and repetitions; a hit is the filtered point inside the
// circle for HIT_HOLD_MS straight, completed within HIT_TIMEOUT_MS of onset.
export const HIT_RADII_DEG = [1, 1.5, 2, 2.5, 3];
export const HIT_TRIALS_PER_RADIUS = 15;
export const HIT_HOLD_MS = 300;
export const HIT_TIMEOUT_MS = 2000;

export function shuffled<T>(items: readonly T[], random: () => number = Math.random): T[] {
  const out = items.slice();
  for (let i = out.length - 1; i > 0; i -= 1) {
    const j = Math.floor(random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

export function mmPerPoint(displaySizeInch: number, widthPt: number, heightPt: number): number {
  return (displaySizeInch * 25.4) / Math.hypot(widthPt, heightPt);
}

export function degreesFor(errorPt: number, mmPerPt: number, distanceM: number): number {
  return (Math.atan((errorPt * mmPerPt) / (distanceM * 1000)) * 180) / Math.PI;
}

export function pointsForDegrees(deg: number, mmPerPt: number, distanceM: number): number {
  return (Math.tan((deg * Math.PI) / 180) * distanceM * 1000) / mmPerPt;
}

function quantile(values: number[], q: number): number | null {
  if (values.length === 0) return null;
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];
}

export function median(values: number[]): number | null {
  return quantile(values, 0.5);
}

// Accuracy is the offset of the mean gaze point from the target; precision
// is the RMS of successive sample-to-sample distances.
export function scoreTarget(targetPt: Point, samplesPt: Point[]): { accuracyPt: number; precisionRmsPt: number } | null {
  if (samplesPt.length === 0) return null;
  const mean: Point = [0, 0];
  for (const [x, y] of samplesPt) {
    mean[0] += x / samplesPt.length;
    mean[1] += y / samplesPt.length;
  }
  let sumSq = 0;
  for (let i = 1; i < samplesPt.length; i += 1) {
    sumSq += (samplesPt[i][0] - samplesPt[i - 1][0]) ** 2 + (samplesPt[i][1] - samplesPt[i - 1][1]) ** 2;
  }
  return {
    accuracyPt: Math.hypot(mean[0] - targetPt[0], mean[1] - targetPt[1]),
    precisionRmsPt: samplesPt.length > 1 ? Math.sqrt(sumSq / (samplesPt.length - 1)) : 0
  };
}

export interface HeldOutTarget {
  target: Point; // normalized
  samplesPt: Point[];
}

export interface Geometry {
  widthPt: number;
  heightPt: number;
  mmPerPt: number;
  distanceM: number;
}

export function heldOutReport(targets: HeldOutTarget[], geometry: Geometry) {
  const perTarget = targets.map(({ target, samplesPt }) => {
    const score = scoreTarget([target[0] * geometry.widthPt, target[1] * geometry.heightPt], samplesPt);
    return {
      target,
      region: regionOfTarget(target),
      samples: samplesPt.length,
      accuracy_pt: score?.accuracyPt ?? null,
      accuracy_deg: score ? degreesFor(score.accuracyPt, geometry.mmPerPt, geometry.distanceM) : null,
      precision_rms_pt: score?.precisionRmsPt ?? null,
      precision_rms_deg: score ? degreesFor(score.precisionRmsPt, geometry.mmPerPt, geometry.distanceM) : null
    };
  });
  const summarize = (rows: typeof perTarget) => {
    const deg = rows.map((r) => r.accuracy_deg).filter((v): v is number => v !== null);
    const precision = rows.map((r) => r.precision_rms_deg).filter((v): v is number => v !== null);
    return { targets: deg.length, median_deg: median(deg), p90_deg: quantile(deg, 0.9), precision_rms_median_deg: median(precision) };
  };
  const regions = {} as Record<Region, ReturnType<typeof summarize>>;
  for (const region of ["center", "edge", "corner"] as const) {
    regions[region] = summarize(perTarget.filter((r) => r.region === region));
  }
  return { overall: summarize(perTarget), regions, per_target: perTarget };
}

export interface HitTrial {
  radiusDeg: number;
  radiusPt: number;
  target: Point; // normalized
  hit: boolean | null;
  timeToHitMs: number | null;
}

// Uniform positions that keep the whole circle on screen.
export function buildHitTrials(geometry: Geometry, random: () => number = Math.random): HitTrial[] {
  const trials: HitTrial[] = [];
  for (const radiusDeg of HIT_RADII_DEG) {
    const radiusPt = pointsForDegrees(radiusDeg, geometry.mmPerPt, geometry.distanceM);
    for (let i = 0; i < HIT_TRIALS_PER_RADIUS; i += 1) {
      const mx = Math.min(0.5, radiusPt / geometry.widthPt);
      const my = Math.min(0.5, radiusPt / geometry.heightPt);
      trials.push({
        radiusDeg,
        radiusPt,
        target: [mx + random() * (1 - 2 * mx), my + random() * (1 - 2 * my)],
        hit: null,
        timeToHitMs: null
      });
    }
  }
  return shuffled(trials, random);
}

export function hitRateReport(trials: HitTrial[]) {
  const perRadius = HIT_RADII_DEG.map((radiusDeg) => {
    const rows = trials.filter((t) => t.radiusDeg === radiusDeg && t.hit !== null);
    const hits = rows.filter((t) => t.hit);
    return {
      radius_deg: radiusDeg,
      radius_pt: rows[0]?.radiusPt ?? null,
      trials: rows.length,
      hit_rate: rows.length ? hits.length / rows.length : null,
      median_time_to_hit_ms: median(hits.map((t) => t.timeToHitMs ?? 0))
    };
  });
  const s90 = perRadius.find((r) => r.hit_rate !== null && r.hit_rate >= 0.9)?.radius_deg ?? null;
  return { per_radius: perRadius, s90_deg: s90 };
}

// Advances one trial with one filtered gaze frame. A frame outside the
// circle (or held/blinking) restarts the dwell clock.
export function updateHitTrial(
  trial: HitTrial,
  state: { onset: number; insideSince: number | null },
  gazePt: Point | null,
  geometry: Geometry,
  now: number
): boolean {
  if (trial.hit !== null) return true;
  const centre: Point = [trial.target[0] * geometry.widthPt, trial.target[1] * geometry.heightPt];
  const inside = gazePt !== null && Math.hypot(gazePt[0] - centre[0], gazePt[1] - centre[1]) <= trial.radiusPt;
  if (!inside) {
    state.insideSince = null;
  } else {
    state.insideSince ??= now;
    if (now - state.insideSince >= HIT_HOLD_MS && now - state.onset <= HIT_TIMEOUT_MS) {
      trial.hit = true;
      trial.timeToHitMs = now - state.onset;
      return true;
    }
  }
  if (now - state.onset > HIT_TIMEOUT_MS) {
    trial.hit = false;
    return true;
  }
  return false;
}
