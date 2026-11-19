import { describe, expect, it } from "vitest";
import {
  ACCURACY_GRID,
  buildHitTrials,
  degreesFor,
  heldOutReport,
  hitRateReport,
  HIT_RADII_DEG,
  HIT_TRIALS_PER_RADIUS,
  mmPerPoint,
  pointsForDegrees,
  scoreTarget,
  shuffled,
  updateHitTrial,
  type Geometry
} from "./accuracyProtocol";

// MacBookPro17,1: 13.3" at 1440×900 pt — the protocol's rig.
const rig: Geometry = { widthPt: 1440, heightPt: 900, mmPerPt: mmPerPoint(13.3, 1440, 900), distanceM: 0.5 };

function seeded(seed = 1): () => number {
  let s = seed;
  return () => {
    s = (s * 16807) % 2147483647;
    return (s - 1) / 2147483646;
  };
}

describe("accuracy protocol v1", () => {
  it("matches the appendix conversions on the owner's rig", () => {
    expect(rig.mmPerPt).toBeCloseTo(0.199, 3);
    expect(pointsForDegrees(1, rig.mmPerPt, 0.5)).toBeCloseTo(44, 0);
    expect(pointsForDegrees(1, rig.mmPerPt, 0.6)).toBeCloseTo(53, 0);
    expect(degreesFor(pointsForDegrees(2.5, rig.mmPerPt, 0.6), rig.mmPerPt, 0.6)).toBeCloseTo(2.5, 9);
  });

  it("lays out the 4x4 held-out grid at 10/37/63/90% with 4 center, 8 edge, 4 corner targets", () => {
    expect(ACCURACY_GRID).toHaveLength(16);
    const report = heldOutReport(
      ACCURACY_GRID.map((target) => ({ target, samplesPt: [] })),
      rig
    );
    expect(report.regions.center.targets).toBe(0);
    const regions = report.per_target.map((r) => r.region);
    expect(regions.filter((r) => r === "center")).toHaveLength(4);
    expect(regions.filter((r) => r === "edge")).toHaveLength(8);
    expect(regions.filter((r) => r === "corner")).toHaveLength(4);
  });

  it("scores accuracy as the mean offset and precision as sample-to-sample RMS", () => {
    const score = scoreTarget([100, 100], [
      [110, 100],
      [114, 100],
      [110, 100],
      [114, 100]
    ])!;
    expect(score.accuracyPt).toBeCloseTo(12, 9);
    expect(score.precisionRmsPt).toBeCloseTo(4, 9);
    expect(scoreTarget([0, 0], [])).toBeNull();
  });

  it("reports median and p90 angular error overall and per region", () => {
    const offsetPt = pointsForDegrees(2, rig.mmPerPt, rig.distanceM);
    const report = heldOutReport(
      ACCURACY_GRID.map((target) => ({ target, samplesPt: [[target[0] * 1440 + offsetPt, target[1] * 900]] })),
      rig
    );
    expect(report.overall.median_deg).toBeCloseTo(2, 6);
    expect(report.overall.p90_deg).toBeCloseTo(2, 6);
    expect(report.regions.corner.median_deg).toBeCloseTo(2, 6);
  });

  it("shuffles without losing or duplicating targets", () => {
    const order = shuffled(ACCURACY_GRID, seeded(7));
    expect(order).toHaveLength(16);
    expect(new Set(order.map((p) => p.join(",")))).toEqual(new Set(ACCURACY_GRID.map((p) => p.join(","))));
  });

  it("builds 15 on-screen trials per radius", () => {
    const trials = buildHitTrials(rig, seeded(3));
    expect(trials).toHaveLength(HIT_RADII_DEG.length * HIT_TRIALS_PER_RADIUS);
    for (const t of trials) {
      expect(t.target[0] * 1440 - t.radiusPt).toBeGreaterThanOrEqual(-1e-9);
      expect(t.target[0] * 1440 + t.radiusPt).toBeLessThanOrEqual(1440 + 1e-9);
      expect(t.target[1] * 900 - t.radiusPt).toBeGreaterThanOrEqual(-1e-9);
    }
  });

  it("needs 300 ms continuously inside within 2 s, and an exit restarts the clock", () => {
    const [trial] = buildHitTrials(rig, seeded(5));
    const centre: [number, number] = [trial.target[0] * 1440, trial.target[1] * 900];
    const state = { onset: 0, insideSince: null as number | null };
    expect(updateHitTrial(trial, state, centre, rig, 100)).toBe(false);
    expect(updateHitTrial(trial, state, [centre[0] + trial.radiusPt * 2, centre[1]], rig, 300)).toBe(false);
    expect(updateHitTrial(trial, state, centre, rig, 350)).toBe(false);
    expect(updateHitTrial(trial, state, centre, rig, 600)).toBe(false);
    expect(updateHitTrial(trial, state, centre, rig, 650)).toBe(true);
    expect(trial.hit).toBe(true);
    expect(trial.timeToHitMs).toBe(650);

    const [late] = buildHitTrials(rig, seeded(9));
    const lateState = { onset: 0, insideSince: null as number | null };
    expect(updateHitTrial(late, lateState, null, rig, 2001)).toBe(true);
    expect(late.hit).toBe(false);
  });

  it("reports hit rate per radius and S90 as the smallest radius with ≥90% hits", () => {
    const trials = buildHitTrials(rig, seeded(11));
    for (const t of trials) t.hit = t.radiusDeg >= 2 || t === trials.find((x) => x.radiusDeg === 1.5);
    const report = hitRateReport(trials);
    expect(report.per_radius.find((r) => r.radius_deg === 1)?.hit_rate).toBe(0);
    expect(report.s90_deg).toBe(2);
  });
});
