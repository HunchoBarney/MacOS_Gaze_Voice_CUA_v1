import { describe, expect, it, vi } from "vitest";
import {
  applyImplicitLabel,
  BOOTSTRAP_MIN_LABELS,
  Calibration,
  DriftMonitor,
  implicitAcceptGate,
  LEARNING_POOL_TARGET,
  type GazeFeature,
  type ImplicitLabelKind,
  type TimedFeature
} from "./core";

// A person whose raw geometric projection is off by a scale, an offset and
// a mild warp — what an uncalibrated webcam gaze looks like. Yaw/pitch carry
// the true direction so the feature map has something to learn from.
function personFeature(bias: { sx: number; sy: number; ox: number; oy: number; kappaYaw: number; kappaPitch: number }) {
  return ([tx, ty]: [number, number]): GazeFeature => {
    const warp = 0.3 * (tx - 0.5) * (ty - 0.5);
    const yaw = (tx - 0.5) * 30 + bias.kappaYaw;
    const pitch = (ty - 0.5) * 20 + bias.kappaPitch;
    return {
      point: [bias.ox + bias.sx * tx + warp, bias.oy + bias.sy * ty - warp],
      eyeCenterPx: [320, 240],
      leftEyePx: [300, 240],
      rightEyePx: [340, 240],
      leftYawDeg: yaw,
      leftPitchDeg: pitch,
      rightYawDeg: yaw,
      rightPitchDeg: pitch,
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
  };
}

// Each person also carries their own visual-axis offset (angle kappa).
const noise = rng(3);
const owner = personFeature({ sx: 0.75, sy: 0.7, ox: 0.18, oy: 0.12, kappaYaw: 2.5, kappaPitch: -1.5 });
const someoneElse = personFeature({ sx: 0.85, sy: 0.8, ox: 0.05, oy: 0.2, kappaYaw: -1.5, kappaPitch: 1 });

// Deterministic pseudo-random sequence so the curves are reproducible.
function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

function makeCalibration() {
  const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
  const calibration = new Calibration("c.json", vi.fn(), { read: vi.fn().mockResolvedValue({ ok: true, text: null }), write });
  return { calibration, write };
}

// The label-replay tests are CPU-bound simulations with no timers to fake.
// Unloaded they take 0.2–0.4 s; under a loaded local-ci run (#569) the prior
// test took 5.3 s and tripped vitest's 5 s default. 20 s keeps ~4x headroom
// over that worst case without changing what they measure.
const SIMULATION_TIMEOUT_MS = 20_000;

const HELD_OUT: [number, number][] = [];
for (let i = 0; i < 5; i += 1) {
  for (let j = 0; j < 5; j += 1) {
    HELD_OUT.push([0.1 + 0.2 * i, 0.1 + 0.2 * j]);
  }
}

function medianError(calibration: Calibration, featureAt: (t: [number, number]) => GazeFeature): number {
  const errors = HELD_OUT.map((t) => {
    const p = calibration.applyFeature(featureAt(t));
    return Math.hypot(p[0] - t[0], p[1] - t[1]);
  }).sort((a, b) => a - b);
  return errors[Math.floor(errors.length / 2)];
}

// One label of `kind` at `target`; with probability `lookAway` the eyes were
// somewhere else (a click made without looking), the noise every implicit
// source carries.
async function label(
  calibration: Calibration,
  monitor: DriftMonitor,
  featureAt: (t: [number, number]) => GazeFeature,
  target: [number, number],
  now: number,
  kind: ImplicitLabelKind,
  lookAt: [number, number] = target
): Promise<boolean> {
  // Webcam features jitter: ~1° on the eye angles, ~0.015 on the raw point.
  const clean = featureAt(lookAt);
  const jitter = () => (noise() + noise() + noise() - 1.5) * 1.4;
  const feature: GazeFeature = {
    ...clean,
    point: [clean.point[0] + jitter() * 0.015, clean.point[1] + jitter() * 0.015],
    leftYawDeg: clean.leftYawDeg + jitter(),
    rightYawDeg: clean.rightYawDeg + jitter(),
    leftPitchDeg: clean.leftPitchDeg + jitter(),
    rightPitchDeg: clean.rightPitchDeg + jitter()
  };
  const recent: TimedFeature[] = [0, 100, 200, 300, 400, 500, 600, 700].map((ago) => ({ feature, at: now - ago }));
  const outcome = applyImplicitLabel(calibration, recent, target[0], target[1], kind, now, monitor);
  return (await outcome?.refit) ?? false;
}

async function useFor(
  calibration: Calibration,
  featureAt: (t: [number, number]) => GazeFeature,
  labels: number,
  startMs: number,
  seed = 7,
  lookAway = 0.2
): Promise<number> {
  const next = rng(seed);
  const monitor = new DriftMonitor();
  let now = startMs;
  for (let i = 0; i < labels; i += 1) {
    now += 4000;
    const target: [number, number] = [0.05 + 0.9 * next(), 0.05 + 0.9 * next()];
    const away = next() < lookAway;
    const lookAt: [number, number] = away ? [0.05 + 0.9 * next(), 0.05 + 0.9 * next()] : target;
    await label(calibration, monitor, featureAt, target, now, i % 2 === 0 ? "click" : "voice", lookAt);
  }
  return now;
}

describe("invisible calibration", () => {
  it("widens the accept gate with the learned error and starts wide while learning", () => {
    expect(implicitAcceptGate(null, true)).toBe(0.22);
    expect(implicitAcceptGate(null, false)).toBe(0.09);
    expect(implicitAcceptGate(0.02, false)).toBe(0.09);
    expect(implicitAcceptGate(0.06, true)).toBeCloseTo(0.15, 10);
    expect(implicitAcceptGate(0.1, true)).toBe(0.22);
  });

  it("lets a badly wrong map accept the labels that would correct it", () => {
    // The owner's map missed by 0.4 of the screen; a 0.22 gate rejected
    // every label far enough away to fix it, so the pool only confirmed it.
    expect(implicitAcceptGate(0.2, true)).toBeCloseTo(0.3, 10);
    expect(implicitAcceptGate(0.4, false)).toBe(0.5);
    expect(implicitAcceptGate(0.9, false)).toBe(0.5);
  });

  it("never learns from a resting cursor", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    const monitor = new DriftMonitor();
    for (let i = 0; i < 40; i += 1) {
      await label(calibration, monitor, owner, [0.05 + 0.022 * i, 0.9 - 0.02 * i], 20_000 * (i + 1), "cursor_rest");
    }
    expect(calibration.implicitSamples).toHaveLength(0);
    expect(calibration.learnedError).toBeNull();
    expect(calibration.featureMap === null && calibration.matrix === null).toBe(true);
  });

  it("scores a refit on labels each fold never saw", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    const next = rng(21);
    const point = (): [number, number] => [0.05 + 0.9 * next(), 0.05 + 0.9 * next()];
    const clean = Array.from({ length: 60 }, () => {
      const t = point();
      return [owner(t), t] as [GazeFeature, [number, number]];
    });
    // Each label sits up to ±0.12 from where the eyes were, like a cursor
    // parked near what was being read: a pool the map can memorise but not
    // learn from.
    const wobble = () => (next() - 0.5) * 0.24;
    const noise = clean.map(([f, t]) => [f, [t[0] + wobble(), t[1] + wobble()]] as [GazeFeature, [number, number]]);
    const internals = calibration as unknown as {
      fitOnce(pool: Array<[GazeFeature, [number, number]]>, min?: number): object | string;
      pendingEstimate(fit: object, feature: GazeFeature): [number, number];
    };
    const fit = internals.fitOnce(noise, 40);
    if (typeof fit === "string") throw new Error(fit);
    const inSample = noise.map(([f, t]) => {
      const p = internals.pendingEstimate(fit as object, f);
      return Math.hypot(p[0] - t[0], p[1] - t[1]);
    }).sort((a, b) => a - b)[30];
    const heldOutNoise = calibration.heldOutError(noise);
    console.info("in-sample vs held-out median", JSON.stringify({ inSample, heldOutNoise, heldOutClean: calibration.heldOutError(clean) }));
    expect(inSample).toBeLessThan(heldOutNoise * 0.8);
    expect(calibration.heldOutError(clean)).toBeLessThan(0.05);
    expect(heldOutNoise).toBeGreaterThan(calibration.heldOutError(clean) * 2);
  }, SIMULATION_TIMEOUT_MS);

  it("keeps every frame of a calibration point in one fold", () => {
    // A point run labels ~6 frames per target. If those frames sit in both
    // the training and the scored fold, the RBF learns each point's own miss
    // from its siblings and the "held-out" error is really in-sample.
    const { calibration } = makeCalibration();
    const next = rng(9);
    const pool: Array<[GazeFeature, [number, number]]> = [];
    const misses: number[] = [];
    for (let i = 0; i < 4; i += 1) {
      for (let j = 0; j < 4; j += 1) {
        const target: [number, number] = [0.1 + 0.8 * (i / 3), 0.1 + 0.8 * (j / 3)];
        const miss: [number, number] = [(next() - 0.5) * 0.2, (next() - 0.5) * 0.2];
        misses.push(Math.hypot(miss[0], miss[1]));
        for (let frame = 0; frame < 6; frame += 1) {
          const eyes: [number, number] = [target[0] + miss[0] + (next() - 0.5) * 0.004, target[1] + miss[1] + (next() - 0.5) * 0.004];
          pool.push([owner(eyes), target]);
        }
      }
    }
    const typicalMiss = misses.sort((a, b) => a - b)[Math.floor(misses.length / 2)];
    expect(calibration.heldOutError(pool)).toBeGreaterThan(typicalMiss * 0.5);
  }, SIMULATION_TIMEOUT_MS);

  it("keeps a fresh label's absorbed siblings out of the fit that scores it", () => {
    // After an adopt, earlier labels at a target sit in the durable pool while
    // a fresh label at the same target is scored. Folds keyed on the scored
    // entries alone would leave those siblings in training, and the score
    // would be in-sample again.
    const { calibration } = makeCalibration();
    const next = rng(11);
    const pool: Array<[GazeFeature, [number, number]]> = [];
    const fresh: Array<[GazeFeature, [number, number]]> = [];
    const misses: number[] = [];
    for (let i = 0; i < 4; i += 1) {
      for (let j = 0; j < 4; j += 1) {
        const target: [number, number] = [0.1 + 0.8 * (i / 3), 0.1 + 0.8 * (j / 3)];
        const miss: [number, number] = [(next() - 0.5) * 0.2, (next() - 0.5) * 0.2];
        misses.push(Math.hypot(miss[0], miss[1]));
        for (let frame = 0; frame < 6; frame += 1) {
          const eyes: [number, number] = [target[0] + miss[0] + (next() - 0.5) * 0.004, target[1] + miss[1] + (next() - 0.5) * 0.004];
          const entry: [GazeFeature, [number, number]] = [owner(eyes), [target[0], target[1]]];
          pool.push(entry);
          if (frame === 5) {
            fresh.push(entry);
          }
        }
      }
    }
    const typicalMiss = misses.sort((a, b) => a - b)[Math.floor(misses.length / 2)];
    expect(calibration.heldOutError(pool, fresh)).toBeGreaterThan(typicalMiss * 0.5);
  }, SIMULATION_TIMEOUT_MS);

  it("judges a refit against the live map, not the map it replaced", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    let now = await useFor(calibration, owner, BOOTSTRAP_MIN_LABELS + 30, 0, 7, 0);
    // The map that was live missed every label badly; a refit replaces it.
    for (let i = 0; i < 40; i += 1) {
      calibration.recordLabelError(0.45);
    }
    const next = rng(11);
    const addClean = (count: number) => {
      for (let i = 0; i < count; i += 1) {
        const t: [number, number] = [0.1 + 0.8 * next(), 0.1 + 0.8 * next()];
        calibration.addImplicitSample(owner(t), t);
      }
    };
    addClean(10);
    now += 120_000;
    expect(await calibration.refitWithImplicit(now)).toBe(true);
    // The next refit must score the live map on its own error, not the 0.45
    // its predecessor earned.
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    addClean(10);
    now += 120_000;
    await calibration.refitWithImplicit(now);
    const judged = info.mock.calls.find(([message]) => typeof message === "string" && message.startsWith("Implicit refit"));
    info.mockRestore();
    expect(judged).toBeDefined();
    expect(JSON.parse(String(judged?.[1])).oldError).toBeLessThan(0.1);
  }, SIMULATION_TIMEOUT_MS);

  it("scores the live map and the refit on the same fresh labels", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    let now = await useFor(calibration, owner, BOOTSTRAP_MIN_LABELS + 30, 0, 7, 0);
    // Older labels flattered the live map; the eyes have since moved 0.08 to
    // the right of where it puts them, and only the fresh labels show it.
    for (let i = 0; i < 40; i += 1) {
      calibration.recordLabelError(0.005);
    }
    const next = rng(13);
    for (let i = 0; i < 40; i += 1) {
      const t: [number, number] = [0.1 + 0.7 * next(), 0.1 + 0.8 * next()];
      calibration.addImplicitSample(owner([t[0] + 0.08, t[1]]), t);
    }
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    now += 120_000;
    await calibration.refitWithImplicit(now);
    const judged = info.mock.calls.find(([message]) => typeof message === "string" && message.startsWith("Implicit refit"));
    info.mockRestore();
    expect(judged).toBeDefined();
    expect(JSON.parse(String(judged?.[1])).oldError).toBeGreaterThan(0.05);
  }, SIMULATION_TIMEOUT_MS);

  it("keeps the live map when a refit would only memorise its pool", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    let now = await useFor(calibration, owner, BOOTSTRAP_MIN_LABELS + 30, 0, 7, 0);
    expect(calibration.learnedError).not.toBeNull();
    const liveMap = calibration.featureMap ?? calibration.matrix;
    const before = medianError(calibration, owner);
    // Labels up to ±0.12 from where the eyes were, like a cursor parked near
    // the text being read: the residual RBF can interpolate them exactly.
    const next = rng(5);
    for (let i = 0; i < 30; i += 1) {
      const eyes: [number, number] = [0.1 + 0.8 * next(), 0.1 + 0.8 * next()];
      calibration.addImplicitSample(owner(eyes), [eyes[0] + (next() - 0.5) * 0.24, eyes[1] + (next() - 0.5) * 0.24]);
    }
    now += 120_000;
    expect(await calibration.refitWithImplicit(now)).toBe(false);
    expect(calibration.featureMap ?? calibration.matrix).toBe(liveMap);
    expect(medianError(calibration, owner)).toBe(before);
  }, SIMULATION_TIMEOUT_MS);

  it("fits a first map from ordinary-use labels without a calibration screen", async () => {
    const { calibration, write } = makeCalibration();
    await calibration.load();
    const rawError = medianError(calibration, owner);
    expect(calibration.featureMap === null && calibration.matrix === null).toBe(true);

    await useFor(calibration, owner, BOOTSTRAP_MIN_LABELS + 14, 0);
    expect(calibration.featureMap !== null || calibration.matrix !== null).toBe(true);
    expect(write).toHaveBeenCalled();
    const learnedError = medianError(calibration, owner);
    expect(learnedError).toBeLessThan(rawError * 0.5);
    expect(learnedError).toBeLessThan(0.04);
  });

  it("keeps waiting while the labels cover only part of the screen", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    const monitor = new DriftMonitor();
    for (let i = 0; i < 40; i += 1) {
      await label(calibration, monitor, owner, [0.1 + 0.005 * i, 0.1 + 0.004 * i], 20_000 * (i + 1), "click");
    }
    expect(calibration.featureMap === null && calibration.matrix === null).toBe(true);
  });

  it("never lets a gaze-picked commit into the fit pool or a bootstrap", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    const monitor = new DriftMonitor();
    for (let i = 0; i < 30; i += 1) {
      await label(calibration, monitor, owner, [0.1 + 0.03 * i, 0.1 + 0.025 * i], 20_000 * (i + 1), "gaze_pick");
      await label(calibration, monitor, owner, [0.9 - 0.03 * i, 0.2 + 0.02 * i], 20_000 * (i + 1) + 5, "caret");
    }
    expect(calibration.implicitSamples).toHaveLength(0);
    expect(calibration.featureMap === null && calibration.matrix === null).toBe(true);
  });

  it("starts from a prior, never persists it, and lets personal labels take over", async () => {
    const { calibration, write } = makeCalibration();
    await calibration.load();
    const prior = HELD_OUT.flatMap((t) => [
      { feature: someoneElse(t), target: t },
      { feature: someoneElse([t[0] + 0.05, t[1] + 0.05]), target: [t[0] + 0.05, t[1] + 0.05] as [number, number] }
    ]);
    expect(calibration.seedPrior(prior, 0)).toBe(true);
    expect(calibration.priorActive).toBe(true);
    expect(write).not.toHaveBeenCalled();
    const fromPrior = medianError(calibration, owner);

    await useFor(calibration, owner, 80, 0);
    expect(calibration.priorActive).toBe(false);
    expect(medianError(calibration, owner)).toBeLessThan(fromPrior);
    expect(medianError(calibration, owner)).toBeLessThan(0.04);
    expect(calibration.samples.length).toBeLessThanOrEqual(80);
  }, SIMULATION_TIMEOUT_MS);

  it("keeps the drift monitor out while the map is still learning", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    await useFor(calibration, owner, BOOTSTRAP_MIN_LABELS + 10, 0);
    expect(calibration.learning).toBe(true);
    const monitor = new DriftMonitor();
    const record = vi.spyOn(monitor, "record");
    // A consistent offset that a settled map would read as a moved camera.
    for (let i = 0; i < 12; i += 1) {
      await label(calibration, monitor, (t) => owner([t[0] - 0.12, t[1] - 0.1]), [0.2 + 0.05 * i, 0.5], 1_000_000 + i * 20_000, "click");
    }
    expect(record).not.toHaveBeenCalled();
    expect(calibration.samples.length).toBeLessThan(LEARNING_POOL_TARGET);
  });

  it("reports a learned error that falls as labels accumulate", async () => {
    const { calibration } = makeCalibration();
    await calibration.load();
    const curve: number[] = [];
    let now = 0;
    for (let block = 0; block < 6; block += 1) {
      now = await useFor(calibration, owner, 15, now, 11 + block);
      curve.push(medianError(calibration, owner));
    }
    console.info("synthetic held-out median by 15-label block", JSON.stringify(curve.map((e) => Number(e.toFixed(4)))));
    expect(curve[curve.length - 1]).toBeLessThan(curve[0]);
    expect(calibration.learnedError).not.toBeNull();
  }, SIMULATION_TIMEOUT_MS);
});
