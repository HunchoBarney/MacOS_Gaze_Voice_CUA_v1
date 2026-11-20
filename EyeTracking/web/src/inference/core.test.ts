import { describe, expect, it, vi } from "vitest";
import {
  AppearanceChannel,
  APPEARANCE_INPUT_SIZE,
  Calibration,
  calibrationContextFingerprint,
  createAppearanceInput,
  createGazeInput,
  decodeBinnedAngle,
  DisplayGeometry,
  EyeValidity,
  GazeAngleSmoother,
  GAZE_INPUT_SIZE,
  buildVerifyVerdict,
  coastPosition,
  DriftMonitor,
  regionOfTarget,
  GazeJumpGate,
  HeadPoseBaseline,
  HEAD_POSE_SUBSET_SIZE,
  OneEuroFilter,
  SaccadeAwareGazeFilter,
  ScreenProjector,
  applyPoseRotation,
  estimateHeadPoseFromMesh,
  featureDistanceM,
  fitResidualBias,
  isHeadTurned,
  createLipMotionInput,
  estimateGazeFromModelOutput,
  FEATURE_SCHEMA_VERSION,
  gazeFeatureVector,
  parseCameraResolution,
  parseRetinaFaceOutput,
  parseYoloOutput,
  residualBiasOffset
} from "./core";
import type { GazeEstimate, GazeFeature } from "./core";
import type { WebInferenceConfig } from "../global";

// The dedicated-worker path loads its models through runtimes.ts — stub them
// so the worker module can be exercised end-to-end without onnxruntime.
// workerModelsControl is read live inside the mock: a test can inject a
// dead session (detectError), a failing reload (createError / per-accelerator
// createErrorFor), a rebuilt session that dies on its probe run
// (warmupFailures), a dispose that never settles (disposeHang), or a detect
// held on a gate promise (detectGate) without re-mocking. createCalls records
// every requested accelerator so ladder order is assertable; detectInFlight /
// maxDetectInFlight prove frames never overlap a shared detect.
const workerModelsControl = vi.hoisted(() => ({
  detectError: null as Error | null,
  createError: null as Error | null,
  createErrorFor: {} as Record<string, Error | undefined>,
  warmupFailures: 0,
  disposeHang: false,
  detectGate: null as Promise<void> | null,
  // Override the canned detection wholesale — a head:null result is how the
  // no-face/away path is driven without re-mocking the module.
  detectResult: null as { head: unknown; eyes: unknown[]; mouth: unknown } | null,
  createCalls: [] as string[],
  detectCalls: 0,
  detectInFlight: 0,
  maxDetectInFlight: 0
}));

vi.mock("./runtimes", () => ({
  createRuntimeModels: vi.fn(async (_config: unknown, accelerator: string) => {
    workerModelsControl.createCalls.push(accelerator);
    const createError = workerModelsControl.createErrorFor[accelerator] ?? workerModelsControl.createError;
    if (createError) {
      throw createError;
    }
    return {
      accelerator,
      detectorProviders: [accelerator],
      gazeProviders: [accelerator],
      lipMotionProviders: [],
      detect: vi.fn(async () => {
        workerModelsControl.detectCalls += 1;
        workerModelsControl.detectInFlight += 1;
        workerModelsControl.maxDetectInFlight = Math.max(workerModelsControl.maxDetectInFlight, workerModelsControl.detectInFlight);
        try {
          const gate = workerModelsControl.detectGate;
          if (gate) {
            await gate;
          }
          if (workerModelsControl.detectError) {
            throw workerModelsControl.detectError;
          }
          if (workerModelsControl.detectResult !== null) {
            return workerModelsControl.detectResult;
          }
          return {
            head: { classId: 7, score: 0.9, x1: 240, y1: 120, x2: 400, y2: 380 },
            eyes: [
              { classId: 17, score: 0.8, x1: 270, y1: 210, x2: 310, y2: 230 },
              { classId: 17, score: 0.8, x1: 330, y1: 210, x2: 370, y2: 230 }
            ],
            mouth: null
          };
        } finally {
          workerModelsControl.detectInFlight -= 1;
        }
      }),
      estimate: vi.fn(async () => ({
        yawDeg: 0,
        pitchDeg: 0,
        leftYawDeg: 0,
        leftPitchDeg: 0,
        rightYawDeg: 0,
        rightPitchDeg: 0,
        irisDiameterPx: 30,
        eyeOpen: 0.9,
        agreement: 1,
        leftIrisCenterPx: [290, 220],
        rightIrisCenterPx: [350, 220]
      })),
      estimateLipMotion: vi.fn(async () => null),
      dispose: vi.fn(() => (workerModelsControl.disposeHang ? new Promise<void>(() => undefined) : Promise.resolve()))
    };
  }),
  warmupRuntimeModels: vi.fn(async () => {
    if (workerModelsControl.warmupFailures > 0) {
      workerModelsControl.warmupFailures -= 1;
      throw new Error("probe run failed");
    }
  }),
  // Real race semantics so dispose/create timeout paths run under fake
  // timers — a hung promise must lose to the deadline.
  withTimeout: <T>(operation: Promise<T>, ms: number, label: string): Promise<T> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    });
    return Promise.race([operation, timeout]).finally(() => {
      if (timer !== undefined) {
        clearTimeout(timer);
      }
    });
  },
  setGpuDeviceLostListener: vi.fn()
}));

function pointDistance(a: [number, number], b: [number, number]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

function makeFeature(point: [number, number], overrides: Partial<GazeFeature> = {}): GazeFeature {
  const feature: GazeFeature = {
    point,
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
    ...overrides
  };
  // Mirror the runtime feature-construction sites: the position-conditioned
  // appearance dims are derived at assembly, 0 when a factor is absent.
  const headFrameX = feature.headFrameX ?? 0;
  const headFrameY = feature.headFrameY ?? 0;
  feature.appYawHeadFrameX = feature.appYawHeadFrameX ?? (feature.appYawDeg ?? 0) * headFrameX;
  feature.appYawHeadFrameY = feature.appYawHeadFrameY ?? (feature.appYawDeg ?? 0) * headFrameY;
  feature.appPitchHeadFrameX = feature.appPitchHeadFrameX ?? (feature.appPitchDeg ?? 0) * headFrameX;
  feature.appPitchHeadFrameY = feature.appPitchHeadFrameY ?? (feature.appPitchDeg ?? 0) * headFrameY;
  feature.appConfHeadFrameRadius = feature.appConfHeadFrameRadius ?? (feature.appConf ?? 0) * Math.hypot(headFrameX, headFrameY);
  return feature;
}

describe("ScreenProjector", () => {
  const display = new DisplayGeometry(1920, 1080, 31.5);
  const projector = new ScreenProjector(display, false, false, 0.5, 0.5);
  const leftEye = { classId: 17, score: 1, x1: 296, y1: 236, x2: 304, y2: 244 };
  const rightEye = { classId: 17, score: 1, x1: 336, y1: 236, x2: 344, y2: 244 };
  const eyes = [leftEye, rightEye];
  const distanceM = 0.6;

  it("matches the legacy projection formula", () => {
    expect(projector.project([320, 240], 0, 0, distanceM)).toEqual([0.5, 0.5]);
  });

  it("preserves off-screen raw projection for calibration", () => {
    const point = projector.project([320, 240], 50, -50, distanceM);
    expect(point[0]).toBeGreaterThan(1);
    expect(point[1]).toBeLessThan(0);
  });

  it("uses camera FOV when computing focal length", () => {
    const narrowFovProjector = new ScreenProjector(display, true, true, 0.5, 0, 1, 0.25, 60);
    expect(narrowFovProjector.cameraFovDeg).toBe(60);
    expect(narrowFovProjector.focalPx).toBeGreaterThan(projector.focalPx);
  });

  it("uses selected camera dimensions for the camera center", () => {
    const fullHdProjector = new ScreenProjector(display, false, false, 0.5, 0.5, 1, 0.25, 90, 1920, 1080);
    expect(fullHdProjector.project([960, 540], 0, 0, distanceM)).toEqual([0.5, 0.5]);
  });

  it("re-bases projection when the delivered capture size differs from the request", () => {
    // The default 720p request can fall back to VGA after construction —
    // the projector must follow the actual frame or every raw point lands
    // scaled by the width ratio.
    const fallbackProjector = new ScreenProjector(display, false, false, 0.5, 0.5, 1, 0.25, 90, 1280, 720);
    fallbackProjector.setCameraSize(640, 480);
    expect(fallbackProjector.cameraWidth).toBe(640);
    expect(fallbackProjector.project([320, 240], 0, 0, distanceM)).toEqual([0.5, 0.5]);
    // Same request actually delivered at 720p is a no-op.
    fallbackProjector.setCameraSize(1280, 720);
    expect(fallbackProjector.project([640, 360], 0, 0, distanceM)).toEqual([0.5, 0.5]);
  });

  it("matches legacy when binocular-screen eye angles match", () => {
    const estimate: GazeEstimate = {
      yawDeg: 5,
      pitchDeg: 2,
      leftYawDeg: 5,
      leftPitchDeg: 2,
      rightYawDeg: 5,
      rightPitchDeg: 2,
      irisDiameterPx: 30,
      eyeOpen: 0.9,
      agreement: 1
    };
    const legacy = projector.project([320, 240], estimate.yawDeg, estimate.pitchDeg, distanceM);
    const result = projector.projectEstimate("binocular-screen", eyes, estimate, distanceM);
    expect(result.fallbackReason).toBeUndefined();
    expect(result.point[0]).toBeCloseTo(legacy[0], 7);
    expect(result.point[1]).toBeCloseTo(legacy[1], 7);
  });

  it("falls back for parallel binocular-convergence rays", () => {
    const estimate: GazeEstimate = {
      yawDeg: 0,
      pitchDeg: 0,
      leftYawDeg: 0,
      leftPitchDeg: 0,
      rightYawDeg: 0,
      rightPitchDeg: 0,
      irisDiameterPx: 30,
      eyeOpen: 0.9,
      agreement: 1
    };
    const result = projector.projectEstimate("binocular-convergence", eyes, estimate, distanceM);
    expect(result.fallbackReason).toBeTruthy();
    expect(result.point).toEqual(projector.project([320, 240], 0, 0, distanceM));
  });
});

describe("RetinaFace parser", () => {
  it("selects the highest scoring face and derives sorted eye boxes", () => {
    const rows = new Float32Array(17 * 2);
    rows.set([0, 0, 0.4, 10, 20, 110, 120, 80, 50, 40, 50, 0, 0, 0, 0, 0, 0], 0);
    rows.set([0, 0, 0.9, 100, 120, 300, 340, 240, 180, 160, 180, 0, 0, 0, 0, 0, 0], 17);
    const result = parseRetinaFaceOutput(rows, 0.5);
    expect(result.head?.score).toBeCloseTo(0.9);
    expect(result.eyes).toHaveLength(2);
    expect(result.eyes[0].x1).toBeLessThan(result.eyes[1].x1);
  });

  it("scales postprocessed RetinaFace output to selected camera dimensions", () => {
    const rows = new Float32Array(17);
    rows.set([0, 0, 0.9, 100, 120, 300, 340, 240, 180, 160, 180, 0, 0, 0, 0, 0, 0], 0);
    const result = parseRetinaFaceOutput(rows, 0.5, 1280, 720);
    expect(result.head?.x1).toBeCloseTo(200);
    expect(result.head?.y1).toBeCloseTo(180);
    expect(result.head?.x2).toBeCloseTo(600);
    expect(result.head?.y2).toBeCloseTo(510);
  });
});

describe("YOLO WholeBody28 parser", () => {
  function yoloOutput(candidateCount: number): Float32Array {
    return new Float32Array(32 * candidateCount);
  }

  function setYoloBox(output: Float32Array, candidateCount: number, index: number, cx: number, cy: number, width: number, height: number) {
    output[index] = cx;
    output[candidateCount + index] = cy;
    output[candidateCount * 2 + index] = width;
    output[candidateCount * 3 + index] = height;
  }

  function setYoloScore(output: Float32Array, candidateCount: number, index: number, classId: number, score: number) {
    output[candidateCount * (4 + classId) + index] = score;
  }

  it("maps class 7 to Head, class 17 to Eye, and scales direct-resize boxes", () => {
    const output = yoloOutput(3);
    setYoloBox(output, 3, 0, 320, 240, 200, 220);
    setYoloScore(output, 3, 0, 7, 0.8);
    setYoloBox(output, 3, 1, 270, 230, 30, 20);
    setYoloScore(output, 3, 1, 17, 0.21);
    setYoloBox(output, 3, 2, 370, 230, 30, 20);
    setYoloScore(output, 3, 2, 17, 0.22);

    const result = parseYoloOutput(output, 0.75, 1280, 720);

    expect(result.head?.classId).toBe(7);
    expect(result.head?.score).toBeCloseTo(0.8);
    expect(result.head?.x1).toBeCloseTo(440);
    expect(result.head?.y1).toBeCloseTo(195);
    expect(result.head?.x2).toBeCloseTo(840);
    expect(result.head?.y2).toBeCloseTo(525);
    expect(result.eyes).toHaveLength(2);
    expect(result.eyes[0].classId).toBe(17);
    expect(result.eyes[0].x1).toBeLessThan(result.eyes[1].x1);
  });

  it("uses the normal score threshold for Head and fixed 0.20 for Eye", () => {
    const output = yoloOutput(3);
    setYoloBox(output, 3, 0, 320, 240, 200, 220);
    setYoloScore(output, 3, 0, 7, 0.79);
    setYoloBox(output, 3, 1, 270, 230, 30, 20);
    setYoloScore(output, 3, 1, 17, 0.19);
    setYoloBox(output, 3, 2, 370, 230, 30, 20);
    setYoloScore(output, 3, 2, 17, 0.2);

    const noHead = parseYoloOutput(output, 0.8);
    const withHead = parseYoloOutput(output, 0.79);

    expect(noHead.head).toBeNull();
    expect(withHead.head?.score).toBeCloseTo(0.79);
    expect(withHead.eyes).toHaveLength(1);
    expect(withHead.eyes[0].score).toBeCloseTo(0.2);
  });

  it("applies class-specific NMS before selecting the eye pair inside the head", () => {
    const output = yoloOutput(5);
    setYoloBox(output, 5, 0, 320, 240, 220, 220);
    setYoloScore(output, 5, 0, 7, 0.9);
    setYoloBox(output, 5, 1, 322, 242, 220, 220);
    setYoloScore(output, 5, 1, 7, 0.85);
    setYoloBox(output, 5, 2, 260, 230, 30, 20);
    setYoloScore(output, 5, 2, 17, 0.7);
    setYoloBox(output, 5, 3, 262, 231, 30, 20);
    setYoloScore(output, 5, 3, 17, 0.6);
    setYoloBox(output, 5, 4, 380, 230, 30, 20);
    setYoloScore(output, 5, 4, 17, 0.65);

    const result = parseYoloOutput(output, 0.5);

    expect(result.head?.score).toBeCloseTo(0.9);
    expect(result.eyes).toHaveLength(2);
    expect(result.eyes[0].score).toBeCloseTo(0.7);
    expect(result.eyes[1].score).toBeCloseTo(0.65);
  });

  it("selects Mouth class 19 with the normal score threshold inside the head", () => {
    const lowOutput = yoloOutput(2);
    setYoloBox(lowOutput, 2, 0, 320, 240, 220, 220);
    setYoloScore(lowOutput, 2, 0, 7, 0.9);
    setYoloBox(lowOutput, 2, 1, 320, 300, 40, 20);
    setYoloScore(lowOutput, 2, 1, 19, 0.49);

    expect(parseYoloOutput(lowOutput, 0.5).mouth).toBeNull();

    const output = yoloOutput(5);
    setYoloBox(output, 5, 0, 320, 240, 220, 220);
    setYoloScore(output, 5, 0, 7, 0.9);
    setYoloBox(output, 5, 1, 320, 300, 40, 20);
    setYoloScore(output, 5, 1, 19, 0.19);
    setYoloBox(output, 5, 2, 320, 300, 40, 20);
    setYoloScore(output, 5, 2, 19, 0.6);
    setYoloBox(output, 5, 3, 322, 301, 40, 20);
    setYoloScore(output, 5, 3, 19, 0.5);
    setYoloBox(output, 5, 4, 600, 450, 40, 20);
    setYoloScore(output, 5, 4, 19, 0.95);

    const result = parseYoloOutput(output, 0.5);

    expect(result.mouth?.classId).toBe(19);
    expect(result.mouth?.score).toBeCloseTo(0.6);
  });

  it("creates RGB 0-1 lip motion crops with VSDLM margins in NCHW layout", () => {
    const data = new Uint8ClampedArray(4 * 4 * 4);
    for (let i = 0; i < 16; i += 1) {
      const offset = i * 4;
      data[offset] = i;
      data[offset + 1] = i + 16;
      data[offset + 2] = i + 32;
      data[offset + 3] = 255;
    }
    const frame = { data, width: 4, height: 4 } as ImageData;
    const mouth = { classId: 19, score: 1, x1: 1, y1: 1, x2: 3, y2: 3 };

    const nchw = createLipMotionInput(frame, mouth);

    expect(nchw).toHaveLength(3 * 30 * 48);
    expect(nchw[0]).toBeCloseTo(0 / 255);
    expect(nchw[30 * 48]).toBeCloseTo(16 / 255);
    expect(nchw[30 * 48 * 2]).toBeCloseTo(32 / 255);
  });
});

describe("Camera resolution parser", () => {
  it("accepts presets, aliases, and dimensions", () => {
    expect(parseCameraResolution("VGA")).toMatchObject({ name: "VGA", width: 640, height: 480 });
    expect(parseCameraResolution("Full HD")).toMatchObject({ name: "Full HD", width: 1920, height: 1080 });
    expect(parseCameraResolution("1080p")).toMatchObject({ name: "Full HD", width: 1920, height: 1080 });
    expect(parseCameraResolution("1280x720")).toEqual({ width: 1280, height: 720 });
  });

  it("rejects duplicate aliases and invalid values", () => {
    for (const value of ["2MP", "not-a-size", "1280x0"]) {
      expect(() => parseCameraResolution(value)).toThrow();
    }
  });

  it("returns a fresh copy, not the shared preset object", () => {
    const first = parseCameraResolution("VGA");
    first.width = 1;
    expect(parseCameraResolution("VGA").width).toBe(640);
  });
});

describe("Gaze output parser", () => {
  it("accepts [1, 962, 3] flattened output and splits both eyes", () => {
    const output = new Float32Array(962 * 3);
    for (let i = 0; i < 962; i += 1) {
      output[i * 3] = i % 481;
      output[i * 3 + 1] = i % 17;
      output[i * 3 + 2] = i % 31;
    }
    const estimate = estimateGazeFromModelOutput(output, { input: new Float32Array(1), inverseScale: 1, inverseTx: 0, inverseTy: 0 });
    expect(Number.isFinite(estimate.yawDeg)).toBe(true);
    expect(Number.isFinite(estimate.pitchDeg)).toBe(true);
  });

  it("carries the stable head-pose subset on the estimate", () => {
    const output = new Float32Array(962 * 3);
    for (let i = 0; i < 962; i += 1) {
      output[i * 3] = i % 481;
      output[i * 3 + 1] = i % 17;
      output[i * 3 + 2] = i % 31;
    }
    const estimate = estimateGazeFromModelOutput(output, { input: new Float32Array(1), inverseScale: 1, inverseTx: 0, inverseTy: 0 });
    expect(estimate.headPosePoints).toBeInstanceOf(Float32Array);
    expect(estimate.headPosePoints?.length).toBe(HEAD_POSE_SUBSET_SIZE * 3);
    expect([...estimate.headPosePoints!].every(Number.isFinite)).toBe(true);
  });
});

describe("metric head pose", () => {
  // A rigid "face" in camera coords — asymmetric blobs so every rotation
  // axis is observable (two eye rings, a brow ridge, a chin row).
  function syntheticHead(): Float32Array {
    const pts: number[] = [];
    for (const [cx, cy, cz] of [
      [-40, -6, 4],
      [40, -6, 4]
    ]) {
      for (let i = 0; i < 24; i += 1) {
        const a = (i / 24) * Math.PI * 2;
        pts.push(cx + Math.cos(a) * 14, cy + Math.sin(a) * 8, cz + Math.sin(a * 2) * 4);
      }
    }
    for (let i = 0; i < 16; i += 1) {
      pts.push(-50 + (100 * i) / 15, -42, 8 + ((i * 7) % 5));
      pts.push(-50 + (100 * i) / 15, 46, 10 + ((i * 11) % 5));
    }
    return new Float32Array(pts);
  }

  it("recovers known rotations within a fraction of a degree", () => {
    const reference = syntheticHead();
    for (const [yaw, pitch, roll] of [
      [18, -9, 6],
      [-24, 14, -10],
      [0, 0, 0],
      [35, 20, 15]
    ]) {
      const rotated = applyPoseRotation(reference, yaw, pitch, roll);
      // Distance/framing invariance: uniform scale + translation must be
      // absorbed by the rigid fit.
      for (let i = 0; i < rotated.length; i += 3) {
        rotated[i] = rotated[i] * 1.7 + 300;
        rotated[i + 1] = rotated[i + 1] * 1.7 + 220;
        rotated[i + 2] = rotated[i + 2] * 1.7 - 15;
      }
      const pose = estimateHeadPoseFromMesh(rotated, reference);
      expect(pose).not.toBeNull();
      expect(pose!.yawDeg).toBeCloseTo(yaw, 1);
      expect(pose!.pitchDeg).toBeCloseTo(pitch, 1);
      expect(pose!.rollDeg).toBeCloseTo(roll, 1);
    }
  });

  it("keeps the proxy sign conventions and a ~0 neutral pose", () => {
    // yaw > 0: a forward (-z) point tips toward image-right (+x) — the
    // direction the old headYawProxy went when the nose moved right of the
    // eye midpoint.
    const yawed = applyPoseRotation(new Float32Array([0, 0, -1]), 20, 0, 0);
    expect(yawed[0]).toBeGreaterThan(0);
    // pitch > 0: forward tips toward image-down (+y), matching the proxy's
    // nose-below-eye-line reading.
    const pitched = applyPoseRotation(new Float32Array([0, 0, -1]), 0, 20, 0);
    expect(pitched[1]).toBeGreaterThan(0);
    // roll > 0: the +x end of the eye line tips down (+y) — the same sense
    // as headRollRad's atan2(dy, dx).
    const rolled = applyPoseRotation(new Float32Array([1, 0, 0]), 0, 0, 20);
    expect(rolled[1]).toBeGreaterThan(0);
    const reference = syntheticHead();
    const pose = estimateHeadPoseFromMesh(reference, reference);
    expect(pose).not.toBeNull();
    expect(Math.max(Math.abs(pose!.yawDeg), Math.abs(pose!.pitchDeg), Math.abs(pose!.rollDeg))).toBeLessThan(0.01);
  });

  it("returns null on degenerate or malformed input instead of NaN pose", () => {
    const reference = syntheticHead();
    expect(estimateHeadPoseFromMesh(new Float32Array(reference.length), reference)).toBeNull();
    const nan = reference.slice();
    nan[4] = Number.NaN;
    expect(estimateHeadPoseFromMesh(nan, reference)).toBeNull();
    expect(estimateHeadPoseFromMesh(new Float32Array(6), reference)).toBeNull();
    expect(estimateHeadPoseFromMesh(reference, new Float32Array(6))).toBeNull();
  });

  it("baseline seeds on the first valid mesh and tracks later rotations", () => {
    const baseline = new HeadPoseBaseline();
    const reference = syntheticHead();
    expect(baseline.update(reference)).toEqual({ yawDeg: 0, pitchDeg: 0, rollDeg: 0 });
    const rotated = applyPoseRotation(reference, 20, -10, 5);
    const pose = baseline.update(rotated);
    expect(pose!.yawDeg).toBeCloseTo(20, 1);
    expect(pose!.pitchDeg).toBeCloseTo(-10, 1);
    expect(pose!.rollDeg).toBeCloseTo(5, 1);
    baseline.reset();
    expect(baseline.update(rotated)).toEqual({ yawDeg: 0, pitchDeg: 0, rollDeg: 0 });
  });

  it("baseline ignores malformed input without losing its reference", () => {
    const baseline = new HeadPoseBaseline();
    const reference = syntheticHead();
    baseline.update(reference);
    expect(baseline.update(new Float32Array([1, 2, 3]))).toBeNull();
    const rotated = applyPoseRotation(reference, 12, 0, 0);
    expect(baseline.update(rotated)!.yawDeg).toBeCloseTo(12, 1);
  });
});

describe("Calibration", () => {
  const GRID: [number, number][] = [
    [0.5, 0.5],
    [0.08, 0.08], [0.92, 0.08], [0.92, 0.92], [0.08, 0.92],
    [0.5, 0.08], [0.92, 0.5], [0.5, 0.92], [0.08, 0.5],
    [0.3, 0.3], [0.7, 0.3], [0.7, 0.7], [0.3, 0.7]
  ];

  function makeCalibration() {
    const write = vi.fn().mockResolvedValue({ ok: true, path: ".gaze_calibration.json" });
    const read = vi.fn().mockResolvedValue({ ok: true, text: null });
    const emit = vi.fn();
    const calibration = new Calibration(".gaze_calibration.json", emit, { read, write });
    return { calibration, write, read, emit };
  }

  // A projected cone that is nonlinearly distorted vs the raw gaze point —
  // the feature map can learn the warp, the affine chain cannot.
  function warpedFeatureAt([tx, ty]: [number, number]): GazeFeature {
    const yaw = (tx - 0.5) * 30;
    const pitch = (ty - 0.5) * 30;
    const warp = 0.4 * (tx - 0.5) * (ty - 0.5);
    return makeFeature([tx + warp, ty - warp], {
      leftYawDeg: yaw,
      rightYawDeg: yaw,
      leftPitchDeg: pitch,
      rightPitchDeg: pitch
    });
  }

  // The live capture flow: pursuit grid → fit → verify sweep → save.
  async function pursuitAndVerify(
    calibration: Calibration,
    featureAt: (t: [number, number]) => GazeFeature = (t) => makeFeature(t)
  ): Promise<void> {
    calibration.beginPursuit();
    for (const target of GRID) {
      calibration.capturePursuit(featureAt(target), target);
      calibration.capturePursuit(featureAt(target), target);
    }
    calibration.finishPursuit();
    calibration.beginVerify();
    for (let i = 0; i < 36; i += 1) {
      const target = GRID[i % GRID.length];
      calibration.captureVerifyError(featureAt(target), target);
    }
    await calibration.finishVerify();
  }

  it("uses injected calibration IO without window.gazeBridge", async () => {
    const read = vi.fn().mockResolvedValue({
      ok: true,
      text: JSON.stringify({
        raw_projection: "unclipped-v1",
        affine: [
          [1, 0],
          [0, 1],
          [0, 0]
        ]
      })
    });
    const write = vi.fn().mockResolvedValue({ ok: true, path: ".gaze_calibration.json" });
    const emit = vi.fn();
    const calibration = new Calibration(".gaze_calibration.json", emit, { read, write });
    await calibration.load();
    expect(read).toHaveBeenCalledWith(".gaze_calibration.json");
    expect(calibration.apply([0.25, 0.75])).toEqual([0.25, 0.75]);
  });

  it("ignores calibration files made from clipped projections", async () => {
    const emit = vi.fn();
    const calibration = new Calibration("old.json", emit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify({ affine: [[1, 0], [0, 1], [0, 0]] }) }),
      write: vi.fn()
    });
    await calibration.load();
    expect(calibration.matrix).toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ level: "warning" }));
  });

  it("produces a pending fit once 24+ pursuit samples land", () => {
    const { calibration } = makeCalibration();
    calibration.beginPursuit();
    for (let i = 0; i < 24; i += 1) {
      const target = GRID[i % GRID.length];
      calibration.capturePursuit(makeFeature(target), target);
    }
    calibration.finishPursuit();
    expect(calibration.pendingMatrix).not.toBeNull();
  });

  it("rejects a pursuit that ends short of 24 samples", () => {
    const { calibration, emit } = makeCalibration();
    calibration.beginPursuit();
    for (const target of GRID.slice(0, 10)) {
      calibration.capturePursuit(makeFeature(target), target);
    }
    calibration.finishPursuit();
    expect(calibration.pendingMatrix).toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ status: "rejected_fit" }));
  });

  it("drops non-finite frames at capture so they can't poison the pool", () => {
    const { calibration } = makeCalibration();
    calibration.beginPursuit();
    calibration.capturePursuit(makeFeature([Number.NaN, 0.5]), [0.5, 0.5]);
    calibration.capturePursuit(makeFeature([0.5, 0.5]), [Number.NaN, 0.5]);
    calibration.capturePursuit(makeFeature([0.5, 0.5], { leftYawDeg: Number.NaN }), [0.5, 0.5]);
    expect(calibration.samples).toHaveLength(0);
    calibration.capturePursuit(makeFeature([0.5, 0.5]), [0.5, 0.5]);
    expect(calibration.samples).toHaveLength(1);
  });

  it("saves the fit after a clean verify sweep", async () => {
    const { calibration, write, emit } = makeCalibration();
    await pursuitAndVerify(calibration);
    expect(write).toHaveBeenCalledOnce();
    const payload = write.mock.calls[0][1];
    expect(payload.affine).toHaveLength(3);
    expect(payload.raw_projection).toBe("unclipped-v2");
    expect(payload.samples).toHaveLength(26);
    // `raw` is the uncalibrated gaze point — same space as feature.point.
    expect(payload.samples[0].raw).toEqual(GRID[0]);
    expect(payload.feature_samples).toHaveLength(26);
    expect(payload.verify_verdict).toBeTruthy();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ status: "saved" }));
  });

  it("rejects the fit when the verify sweep is too short", async () => {
    const { calibration, write, emit } = makeCalibration();
    calibration.beginPursuit();
    for (const target of GRID) {
      calibration.capturePursuit(makeFeature(target), target);
      calibration.capturePursuit(makeFeature(target), target);
    }
    calibration.finishPursuit();
    calibration.beginVerify();
    for (let i = 0; i < 10; i += 1) {
      calibration.captureVerifyError(makeFeature(GRID[i]), GRID[i]);
    }
    await calibration.finishVerify();
    expect(write).not.toHaveBeenCalled();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ status: "rejected_fit" }));
  });

  it("rejects the fit when the verify sweep's errors exceed the gate", async () => {
    const { calibration, write, emit } = makeCalibration();
    calibration.beginPursuit();
    for (const target of GRID) {
      calibration.capturePursuit(makeFeature(target), target);
      calibration.capturePursuit(makeFeature(target), target);
    }
    calibration.finishPursuit();
    calibration.beginVerify();
    // Features predict ~[0.5,0.5] while the targets sit at the corner — a
    // consistent large miss is exactly what the sweep exists to catch.
    for (let i = 0; i < 36; i += 1) {
      calibration.captureVerifyError(makeFeature([0.5, 0.5]), [0.1, 0.1]);
    }
    await calibration.finishVerify();
    expect(write).not.toHaveBeenCalled();
    expect(calibration.pendingMatrix).toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ status: "rejected_fit" }));
  });

  it("abortPursuit clears pursuit/verify state without emitting anything", () => {
    const { calibration, write, emit } = makeCalibration();
    calibration.beginPursuit();
    for (const target of GRID) {
      calibration.capturePursuit(makeFeature(target), target);
    }
    calibration.abortPursuit();
    expect(calibration.samples).toHaveLength(0);
    expect(calibration.pendingMatrix).toBeNull();
    expect(calibration.lastVerdict).toBeNull();
    expect(emit).not.toHaveBeenCalled();
    expect(write).not.toHaveBeenCalled();
  });

  it("beginPursuit clears a stale verify verdict before the next fit", () => {
    const { calibration } = makeCalibration();
    calibration.lastVerdict = { median: 0.1, p90: 0.2, max: 0.3, samples: 40, regions: { center: 0.1 } };
    calibration.beginPursuit();
    expect(calibration.lastVerdict).toBeNull();
  });

  it("selects the feature map when the projected cone is nonlinearly distorted", async () => {
    const { calibration, write } = makeCalibration();
    await pursuitAndVerify(calibration, warpedFeatureAt);
    expect(write).toHaveBeenCalledOnce();
    const payload = write.mock.calls[0][1];
    expect(payload.raw_projection).toBe("featuremap-v3");
    expect(payload.feature_map).not.toBeNull();
    expect(payload.feature_map.coeffs).toHaveLength(48);
    expect(calibration.featureMap).not.toBeNull();
    const estimate = calibration.applyFeature(warpedFeatureAt([0.35, 0.75]));
    expect(pointDistance(estimate, [0.35, 0.75])).toBeLessThan(0.05);

    const reloaded = new Calibration(".gaze_calibration.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: ".gaze_calibration.json" })
    });
    await reloaded.load();
    expect(reloaded.featureMap).not.toBeNull();
    const reloadedEstimate = reloaded.applyFeature(warpedFeatureAt([0.6, 0.25]));
    expect(pointDistance(reloadedEstimate, [0.6, 0.25])).toBeLessThan(0.05);
  });

  it("applies, saturates, and persists a drift correction", async () => {
    const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({ raw_projection: "unclipped-v2", affine: [[1, 0], [0, 1], [0, 0]] })
      }),
      write
    });
    await calibration.load();
    // Six capped steps of 0.02 accumulate ≈(0.107, 0.054) — no teleport.
    for (let i = 0; i < 6; i += 1) {
      calibration.applyDriftCorrection(0.1, 0.05);
    }
    expect(calibration.apply([0.5, 0.5])[0]).toBeCloseTo(0.6073, 3);
    expect(calibration.apply([0.5, 0.5])[1]).toBeCloseTo(0.5537, 3);
    // Repeated confirmations accumulate to the 0.35 bound, never a jump.
    let offset = calibration.applyDriftCorrection(0.6, 0.6);
    expect(Math.hypot(offset[0], offset[1])).toBeLessThan(0.15);
    for (let i = 0; i < 40; i += 1) {
      offset = calibration.applyDriftCorrection(0.6, 0.6);
    }
    expect(Math.hypot(offset[0], offset[1])).toBeCloseTo(0.35, 5);
    const payload = write.mock.calls[write.mock.calls.length - 1][1];
    expect(Math.hypot(payload.output_offset[0], payload.output_offset[1])).toBeCloseTo(0.35, 5);
  });

  it("caps each drift correction event — a confirmed offset nudges, never teleports", async () => {
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({ raw_projection: "unclipped-v2", affine: [[1, 0], [0, 1], [0, 0]] })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    // Tonight's bug shape: a ~0.15 median rejection must apply ≤0.02.
    const offset = calibration.applyDriftCorrection(-0.146, -0.014);
    expect(Math.hypot(offset[0], offset[1])).toBeLessThanOrEqual(0.02 + 1e-9);
    expect(calibration.apply([0.5, 0.5])[0]).toBeCloseTo(0.5 - 0.0199, 3);
  });

  it("a capped drift correction must not mass-evict a healthy pool", async () => {
    // 81 well-fit samples — the pool shape from tonight's log.
    const featureSamples: Array<{ feature: GazeFeature; target: [number, number] }> = [];
    for (let i = 0; i < 9; i += 1) {
      for (let j = 0; j < 9; j += 1) {
        const point: [number, number] = [0.1 + 0.1 * i, 0.1 + 0.1 * j];
        featureSamples.push({ feature: makeFeature(point), target: point });
      }
    }
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "unclipped-v2",
          affine: [[1, 0], [0, 1], [0, 0]],
          feature_samples: featureSamples,
          feature_version: FEATURE_SCHEMA_VERSION
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    expect(calibration.samples).toHaveLength(81);
    calibration.applyDriftCorrection(-0.146, -0.014);
    // The 0.02-capped step moved every sample's post-offset error by ~0.02 —
    // far under the 0.12 staleness bar — so nothing was evicted.
    expect(calibration.samples).toHaveLength(81);
  });

  it("round-trips output_offset through a save and reload", async () => {
    const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
    const first = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({ raw_projection: "unclipped-v2", affine: [[1, 0], [0, 1], [0, 0]] })
      }),
      write
    });
    await first.load();
    for (let i = 0; i < 6; i += 1) {
      first.applyDriftCorrection(0.1, -0.05);
    }
    const payload = write.mock.calls[write.mock.calls.length - 1][1];
    // Six capped steps of (0.0179, -0.00894) ≈ the requested (0.1, -0.05).
    expect(payload.output_offset[0]).toBeCloseTo(0.1073, 3);
    expect(payload.output_offset[1]).toBeCloseTo(-0.0537, 3);

    const reloaded = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await reloaded.load();
    const applied = reloaded.apply([0.5, 0.5]);
    expect(applied[0]).toBeCloseTo(0.6073, 3);
    expect(applied[1]).toBeCloseTo(0.4463, 3);
  });

  it("clamps a corrupt persisted output_offset to the drift bound", async () => {
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "unclipped-v2",
          affine: [[1, 0], [0, 1], [0, 0]],
          output_offset: [0.9, -0.9]
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    const applied = calibration.apply([0.5, 0.5]);
    expect(Math.hypot(applied[0] - 0.5, applied[1] - 0.5)).toBeCloseTo(0.35, 5);
  });

  it("writes context_fingerprint and drops raw-space state when it changes", async () => {
    const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
    const first = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: null }),
      write
    });
    first.contextFingerprint = "binocular-screen|1512|982|13.32|90|640|480|0.5|0|1|1";
    await pursuitAndVerify(first);
    expect(write).toHaveBeenCalled();
    const payload = write.mock.calls[write.mock.calls.length - 1][1];
    expect(payload.context_fingerprint).toBe("binocular-screen|1512|982|13.32|90|640|480|0.5|0|1|1");

    // Same context → affine chain, bounds and offset all survive the reload.
    const same = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    same.contextFingerprint = "binocular-screen|1512|982|13.32|90|640|480|0.5|0|1|1";
    await same.load();
    expect(same.matrix).not.toBeNull();
    expect(same.sourceMin).not.toBeNull();

    // Display/projection changed → raw-space state drops, feature samples
    // stay (they're camera-domain), and the status line explains the drop.
    const emit = vi.fn();
    const moved = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    moved.contextFingerprint = "binocular-screen|1920|1080|31.5|90|640|480|0.5|0|1|1";
    await moved.load();
    expect(moved.matrix).toBeNull();
    expect(moved.sourceMin).toBeNull();
    expect(moved.samples.length).toBeGreaterThan(0);
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ level: "info", message: expect.stringContaining("context changed") }));
  });

  it("treats a calibration fit by the other detector family as missing", async () => {
    const ctx = (detector: string) => `binocular-screen|1512|982|13.32|90|640|480|0.5|0|1|1|0|${detector}`;
    const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
    const first = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: null }),
      write
    });
    first.contextFingerprint = ctx("retinaface");
    await pursuitAndVerify(first);
    const payload = write.mock.calls[write.mock.calls.length - 1][1];

    const emit = vi.fn();
    const switched = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    switched.contextFingerprint = ctx("mediapipe");
    await switched.load();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "missing" }));
    expect(switched.matrix).toBeNull();
    expect(switched.samples).toHaveLength(0);

    // Legacy-to-legacy keeps the old behaviour: the file still loads.
    const legacy = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    legacy.contextFingerprint = ctx("yolo");
    await legacy.load();
    expect(legacy.samples.length).toBeGreaterThan(0);
  });

  it("keeps the feature map and drops the drift offset across a context change", async () => {
    const write = vi.fn().mockResolvedValue({ ok: true, path: "c.json" });
    const first = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: null }),
      write
    });
    first.contextFingerprint = "ctx-A";
    await pursuitAndVerify(first, warpedFeatureAt);
    expect(first.featureMap).not.toBeNull();
    // Persist a drift offset built under context A.
    for (let i = 0; i < 6; i += 1) {
      first.applyDriftCorrection(0.1, 0.06);
    }
    const payload = write.mock.calls[write.mock.calls.length - 1][1];
    expect(payload.output_offset).toBeDefined();
    expect(payload.context_fingerprint).toBe("ctx-A");

    const emit = vi.fn();
    const reloaded = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    reloaded.contextFingerprint = "ctx-B";
    await reloaded.load();
    // The map is camera-domain and survives; the offset and affine chain were
    // fit in context A's projection space and drop.
    expect(reloaded.featureMap).not.toBeNull();
    expect(reloaded.matrix).toBeNull();
    const estimate = reloaded.applyFeature(warpedFeatureAt([0.6, 0.25]));
    expect(pointDistance(estimate, [0.6, 0.25])).toBeLessThan(0.05);
  });

  it("emits invalid when a context change leaves no usable map behind", async () => {
    const emit = vi.fn();
    const calibration = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "unclipped-v2",
          affine: [[1, 0], [0, 1], [0, 0]],
          context_fingerprint: "ctx-A"
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    calibration.contextFingerprint = "ctx-B";
    await calibration.load();
    expect(calibration.matrix).toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "invalid" }));
  });

  it("calibrationContextFingerprint changes with display, mode, and camera inputs", () => {
    const base = {
      gazeProjectionMode: "binocular-screen",
      displayWidth: 1512,
      displayHeight: 982,
      displaySizeInch: 13.32,
      cameraFov: 90,
      cameraWidth: 640,
      cameraHeight: 480,
      cameraScreenX: 0.5,
      cameraScreenY: 0,
      flipX: true,
      flipY: true
    };
    const fingerprint = calibrationContextFingerprint(base);
    expect(calibrationContextFingerprint(base)).toBe(fingerprint);
    expect(calibrationContextFingerprint({ ...base, displaySizeInch: 31.5 })).not.toBe(fingerprint);
    expect(calibrationContextFingerprint({ ...base, gazeProjectionMode: "legacy" })).not.toBe(fingerprint);
    expect(calibrationContextFingerprint({ ...base, cameraFov: 78 })).not.toBe(fingerprint);
  });

  it("evicts stale samples when a drift correction lands", async () => {
    const featureSamples: Array<{ feature: GazeFeature; target: [number, number] }> = [];
    for (let i = 0; i < 30; i += 1) {
      const point: [number, number] = [0.2 + 0.02 * i, 0.5];
      featureSamples.push({ feature: makeFeature(point), target: point });
    }
    // Samples captured under a previous camera pose misfit the current map.
    for (let i = 0; i < 6; i += 1) {
      const point: [number, number] = [0.3 + 0.05 * i, 0.3];
      featureSamples.push({ feature: makeFeature(point), target: [point[0] + 0.3, point[1] + 0.3] });
    }
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "unclipped-v2",
          affine: [[1, 0], [0, 1], [0, 0]],
          feature_samples: featureSamples,
          feature_version: FEATURE_SCHEMA_VERSION
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    expect(calibration.samples).toHaveLength(36);
    calibration.applyDriftCorrection(0.05, 0.05);
    expect(calibration.samples).toHaveLength(30);
  });

  it("heals the drift offset as an implicit refit absorbs the move", async () => {
    const { calibration } = makeCalibration();
    await pursuitAndVerify(calibration, warpedFeatureAt);
    expect(calibration.featureMap).not.toBeNull();

    // The camera "moved" — six capped confirmations accumulate ~0.11 of
    // correction (a single event can only nudge 0.02).
    for (let i = 0; i < 6; i += 1) {
      calibration.applyDriftCorrection(0.1, 0.06);
    }
    const shifted = calibration.applyFeature(warpedFeatureAt([0.4, 0.6]));
    expect(pointDistance(shifted, [0.4, 0.6])).toBeGreaterThan(0.08);

    // Fresh implicit evidence lets the map relearn the new geometry, and the
    // persistent offset decays back to ~0 — capped at 0.05 per reheal, so a
    // ~0.11 offset converges over a few refits rather than snapping off.
    for (let round = 0; round < 3; round += 1) {
      for (let i = 0; i < 36; i += 1) {
        const target = GRID[i % GRID.length];
        calibration.addImplicitSample(warpedFeatureAt(target), target);
      }
      const adopted = await calibration.refitWithImplicit(100_000 + round * 100_000);
      expect(adopted).toBe(true);
    }
    const healed = calibration.applyFeature(warpedFeatureAt([0.4, 0.6]));
    expect(pointDistance(healed, [0.4, 0.6])).toBeLessThan(0.05);
  });

  it("drops malformed feature_samples entries without aborting the load", async () => {
    const good = JSON.stringify({ feature: makeFeature([0.1, 0.2]), target: [0.1, 0.2] });
    const text = `{"raw_projection":"unclipped-v2","affine":[[1,0],[0,1],[0,0]],"feature_version":${FEATURE_SCHEMA_VERSION},"feature_samples":[
      ${good},
      {"feature":{"point":"bad"},"target":[0.3,0.4]},
      {"feature":{"point":[0.5,0.5]},"target":[0.5,0.5]},
      {"feature":{"point":[0.6,0.6],"eyeCenterPx":[320,240],"leftEyePx":[300,240],"rightEyePx":[340,240],"leftYawDeg":1e999,"leftPitchDeg":0,"rightYawDeg":0,"rightPitchDeg":0,"headWidthPx":160,"irisDiameterPx":30,"eyeOpen":0.9,"distanceM":0.6},"target":[0.6,0.6]},
      {"feature":{"point":[0.7,0.7]},"target":[0.7]}
    ]}`;
    const emit = vi.fn();
    const calibration = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({ ok: true, text }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    // Only the fully-valid entry survives — non-array point, missing fields,
    // a non-finite dim, and a short target each drop just their own entry.
    expect(calibration.samples).toHaveLength(1);
    expect(calibration.samples[0][1]).toEqual([0.1, 0.2]);
    expect(calibration.matrix).not.toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ message: "Loaded calibration: c.json" }));
  });

  it("rejects collapsed raw targets without replacing a saved calibration", () => {
    const { calibration, write, emit } = makeCalibration();
    calibration.beginPursuit();
    for (let i = 0; i < 26; i += 1) {
      calibration.capturePursuit(makeFeature([0.5, 0.5]), GRID[i % GRID.length]);
    }
    calibration.finishPursuit();
    expect(write).not.toHaveBeenCalled();
    expect(calibration.samples).toHaveLength(0);
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ status: "rejected_fit" }));
  });

  it("emits structured load statuses for missing, invalid, and loaded files", async () => {
    const missingEmit = vi.fn();
    await new Calibration("none.json", missingEmit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: null }),
      write: vi.fn()
    }).load();
    expect(missingEmit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "missing" }));

    const invalidEmit = vi.fn();
    await new Calibration("old.json", invalidEmit, {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify({ affine: [[1, 0], [0, 1], [0, 0]] }) }),
      write: vi.fn()
    }).load();
    expect(invalidEmit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "invalid" }));

    const loadedEmit = vi.fn();
    await new Calibration("good.json", loadedEmit, {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({ raw_projection: "unclipped-v2", affine: [[1, 0], [0, 1], [0, 0]] })
      }),
      write: vi.fn()
    }).load();
    expect(loadedEmit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "loaded" }));
  });

  it("drops persisted 43-dim feature_samples while 48-dim ones load", async () => {
    const legacy = JSON.parse(JSON.stringify(makeFeature([0.2, 0.3]))) as GazeFeature;
    delete legacy.appYawHeadFrameX;
    delete legacy.appYawHeadFrameY;
    delete legacy.appPitchHeadFrameX;
    delete legacy.appPitchHeadFrameY;
    delete legacy.appConfHeadFrameRadius;
    const fresh = JSON.parse(JSON.stringify(makeFeature([0.4, 0.5]))) as GazeFeature;
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "unclipped-v2",
          affine: [[1, 0], [0, 1], [0, 0]],
          feature_version: FEATURE_SCHEMA_VERSION,
          feature_samples: [
            { feature: legacy, target: [0.2, 0.3] },
            { feature: fresh, target: [0.4, 0.5] }
          ]
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    // The 43-dim entry vectorizes NaN in the new interaction dims and fails
    // isUsableSample — the one-time pool flush for the schema bump.
    expect(calibration.samples).toHaveLength(1);
    expect(calibration.samples[0][1]).toEqual([0.4, 0.5]);
  });

  it("drops an unversioned feature map and sample pool but keeps the raw fit", async () => {
    // v1 payloads predate the metric-pose dims — headYaw/headPitch were
    // line-ratio proxies, so the map coeffs and stored features encode a
    // ~50× scale shift the vectorizer cannot see. The schema gate drops the
    // whole feature space while the raw-space affine still carries the
    // calibration.
    const emit = vi.fn();
    const calibration = new Calibration("c.json", emit, {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({
          raw_projection: "featuremap-v3",
          affine: [[1, 0], [0, 1], [0, 0]],
          feature_map: { coeffs: [[0.1, 0.2]], mean: [0.5], scale: [1] },
          feature_samples: [{ feature: makeFeature([0.5, 0.5]), target: [0.5, 0.5] }]
          // feature_version absent → v1 semantics
        })
      }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await calibration.load();
    expect(calibration.featureMap).toBeNull();
    expect(calibration.samples).toHaveLength(0);
    expect(calibration.matrix).not.toBeNull();
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ type: "calibration", status: "loaded" }));
    expect(emit).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining("schema v1") }));
  });

  it("writes the feature schema version on save and honors it on reload", async () => {
    const { calibration, write } = makeCalibration();
    await pursuitAndVerify(calibration, warpedFeatureAt);
    expect(calibration.featureMap).not.toBeNull();
    const payload = write.mock.calls[write.mock.calls.length - 1][1];
    expect(payload.feature_version).toBe(FEATURE_SCHEMA_VERSION);
    // A same-version payload keeps the feature space across reload.
    const reloaded = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    await reloaded.load();
    expect(reloaded.featureMap).not.toBeNull();
    expect(reloaded.samples.length).toBeGreaterThan(0);
  });

  it("fits, persists, and applies a residual-bias field on commit", async () => {
    // A bias that flips sign at mid-screen: the base map absorbs the mean
    // and leaves ~±0.04 behind — exactly the per-user residual the field
    // exists to learn.
    const biased = (t: [number, number]): GazeFeature =>
      makeFeature([t[0] + (t[0] < 0.5 ? 0.08 : -0.08), t[1]]);
    const { calibration, write } = makeCalibration();
    await pursuitAndVerify(calibration, biased);
    expect(calibration.residualMap).not.toBeNull();
    const payload = write.mock.calls[0][1] as { residual_map?: unknown };
    expect(payload.residual_map).toBeTruthy();
    // The personalized path must score better than the same map without it.
    const probe = [0.2, 0.5] as [number, number];
    const feature = biased(probe);
    const field = calibration.residualMap;
    calibration.residualMap = null;
    const without = calibration.applyFeature(feature);
    calibration.residualMap = field;
    const personalized = calibration.applyFeature(feature);
    expect(pointDistance(personalized, probe)).toBeLessThan(pointDistance(without, probe));
  });

  it("restores a persisted residual field and drops it on a context change", async () => {
    const { calibration, write } = makeCalibration();
    calibration.contextFingerprint = "fp-a";
    await pursuitAndVerify(calibration);
    const payload = write.mock.calls[0][1];
    const same = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    same.contextFingerprint = "fp-a";
    await same.load();
    expect(same.residualMap).not.toBeNull();
    const moved = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({ ok: true, text: JSON.stringify(payload) }),
      write: vi.fn().mockResolvedValue({ ok: true, path: "c.json" })
    });
    moved.contextFingerprint = "fp-b";
    await moved.load();
    expect(moved.residualMap).toBeNull();
  });

  it("leaves the output identical when no personalization data exists", async () => {
    const calibration = new Calibration("c.json", vi.fn(), {
      read: vi.fn().mockResolvedValue({
        ok: true,
        text: JSON.stringify({ raw_projection: "unclipped-v2", affine: [[1, 0], [0, 1], [0, 0]] })
      }),
      write: vi.fn()
    });
    await calibration.load();
    expect(calibration.residualMap).toBeNull();
    expect(calibration.apply([0.25, 0.75])).toEqual([0.25, 0.75]);
    expect(calibration.applyFeature(makeFeature([0.3, 0.4]))).toEqual([0.3, 0.4]);
  });
});

describe("residual-bias personalization", () => {
  it("shrinks a systematic spatial bias markedly after fitting", () => {
    const points: [number, number][] = [];
    const residuals: [number, number][] = [];
    for (let ix = 0; ix < 12; ix += 1) {
      for (let iy = 0; iy < 12; iy += 1) {
        const x = 0.05 + (ix / 11) * 0.9;
        const y = 0.05 + (iy / 11) * 0.9;
        points.push([x, y]);
        // A smooth pull toward mid-screen — spatially varying, so neither a
        // global offset nor an affine could express it.
        residuals.push([(0.5 - x) * 0.12, (0.5 - y) * 0.08]);
      }
    }
    const map = fitResidualBias(points, residuals);
    expect(map).not.toBeNull();
    const before = residuals.reduce((sum, r) => sum + Math.hypot(r[0], r[1]), 0) / residuals.length;
    const after =
      points.reduce((sum, p, i) => {
        const [ox, oy] = residualBiasOffset(map!, p);
        return sum + Math.hypot(residuals[i][0] - ox, residuals[i][1] - oy);
      }, 0) / points.length;
    expect(after).toBeLessThan(before * 0.5);
  });

  it("returns null without enough evidence", () => {
    expect(fitResidualBias([], [])).toBeNull();
    expect(fitResidualBias([[0.5, 0.5]], [[0.1, 0.1]])).toBeNull();
  });

  it("shrinks weak evidence instead of trusting a single stray sample", () => {
    const points: [number, number][] = [];
    const residuals: [number, number][] = [];
    for (let i = 0; i < 30; i += 1) {
      points.push([0.5 + (i % 5) * 0.01, 0.5]);
      residuals.push([0.02, 0]);
    }
    points.push([0.95, 0.95]);
    residuals.push([0.5, 0.5]);
    const map = fitResidualBias(points, residuals)!;
    const [ox, oy] = residualBiasOffset(map, [0.95, 0.95]);
    // One sample earns 1/7 strength: ~0.07/axis — far from the raw 0.5.
    expect(Math.hypot(ox, oy)).toBeLessThan(0.15);
  });
});

describe("gazeFeatureVector", () => {
  it("produces 48 dims with position-conditioned appearance interactions", () => {
    const vector = gazeFeatureVector(
      makeFeature([0.5, 0.5], {
        appYawDeg: 15,
        appPitchDeg: -6,
        appConf: 0.5,
        headFrameX: 0.2,
        headFrameY: -0.1
      })
    );
    expect(vector).toHaveLength(48);
    // The interaction dims tail the vector: angle terms share the /30 scale
    // of the appearance dims, conf × head-frame radius stays raw.
    expect(vector[43]).toBeCloseTo((15 * 0.2) / 30);
    expect(vector[44]).toBeCloseTo((15 * -0.1) / 30);
    expect(vector[45]).toBeCloseTo((-6 * 0.2) / 30);
    expect(vector[46]).toBeCloseTo((-6 * -0.1) / 30);
    expect(vector[47]).toBeCloseTo(0.5 * Math.hypot(0.2, -0.1));
  });

  it("normalizes eye-center by the feature's actual frame size", () => {
    // Persisted-era features carry no frameWidth/Height and vectorize under
    // the VGA constants — exactly what they were captured at.
    const vga = gazeFeatureVector(makeFeature([0.5, 0.5])); // eyeCenterPx [320,240]
    expect(vga[8]).toBeCloseTo(0.5);
    expect(vga[9]).toBeCloseTo(0.5);

    // The same normalized position at 720p is different pixels — the vector
    // must be resolution-invariant so a map keeps working across a VGA
    // fallback boundary.
    const hd = gazeFeatureVector(
      makeFeature([0.5, 0.5], { eyeCenterPx: [640, 360], frameWidth: 1280, frameHeight: 720 })
    );
    expect(hd[8]).toBeCloseTo(0.5);
    expect(hd[9]).toBeCloseTo(0.5);

    // And the same pixels at 720p is a genuinely different position — the
    // old fixed-VGA normalization would have read 0.5 here.
    const offset = gazeFeatureVector(
      makeFeature([0.5, 0.5], { eyeCenterPx: [320, 240], frameWidth: 1280, frameHeight: 720 })
    );
    expect(offset[8]).toBeCloseTo(0.25);
    expect(offset[9]).toBeCloseTo(1 / 3);
    // Iris size scales with linear resolution too: a 36px iris at 720p is
    // the same physical eye as 18px at VGA.
    const iris = gazeFeatureVector(
      makeFeature([0.5, 0.5], { irisDiameterPx: 36, frameWidth: 1280, frameHeight: 720 })
    );
    expect(iris[13]).toBeCloseTo(1);
  });
});

describe("feature distance", () => {
  const focalPx = 640 / (2 * Math.tan((90 * Math.PI) / 360));

  it("prefers iris diameter when it is plausible", () => {
    const distance = featureDistanceM(makeFeature([0.5, 0.5], { irisDiameterPx: 20 }), focalPx);
    expect(distance).toBeCloseTo((0.0117 * focalPx) / 20, 6);
  });

  it("rejects implausible iris distances and falls back to head width", () => {
    const distance = featureDistanceM(makeFeature([0.5, 0.5], { irisDiameterPx: 30 }), focalPx);
    expect(distance).toBeCloseTo((0.16 * focalPx) / 160, 6);
  });

  it("falls back to head width when the iris is missing or implausible", () => {
    const headDistance = featureDistanceM(makeFeature([0.5, 0.5], { irisDiameterPx: 0 }), focalPx);
    expect(headDistance).toBeCloseTo((0.16 * focalPx) / 160, 6);
    const noIris = featureDistanceM(makeFeature([0.5, 0.5]), focalPx, false);
    expect(noIris).toBeCloseTo(headDistance, 6);
  });
});

describe("one euro filter", () => {
  it("passes the first sample through and smooths stationary noise", () => {
    const filter = new OneEuroFilter(1.0, 0.5, 1.0);
    expect(filter.filter(0.5, 0)).toBe(0.5);
    let value = 0;
    for (let index = 1; index <= 60; index += 1) {
      value = filter.filter(0.5 + (index % 2 === 0 ? 0.02 : -0.02), index / 60);
    }
    expect(Math.abs(value - 0.5)).toBeLessThan(0.02);
  });

  it("tracks a fast step faster than a slow drift", () => {
    const filter = new OneEuroFilter(1.0, 1.0, 1.0);
    filter.filter(0, 0);
    for (let index = 1; index <= 30; index += 1) {
      filter.filter(0, index / 60);
    }
    let settled = 0;
    for (let index = 31; index <= 45; index += 1) {
      settled = filter.filter(1, index / 60);
    }
    expect(settled).toBeGreaterThan(0.5);
  });
});

describe("eye validity", () => {
  it("holds the instant the lid drops mid-band — before a blink is confirmed", () => {
    const v = new EyeValidity();
    expect(v.update(0.9, 0)).toBe("tracking");
    // Mid-band dip: hold immediately — this is the frame that used to emit
    // a garbage mid-closure position.
    expect(v.update(0.4, 50)).toBe("closing");
    expect(v.holding).toBe(true);
    expect(v.blinking).toBe(false);
  });

  it("confirms a blink on the second closed frame and requires a sustained reopen", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    expect(v.update(0.2, 50)).toBe("closing");
    expect(v.update(0.2, 100)).toBe("closed");
    expect(v.blinking).toBe(true);
    // One recovering frame isn't enough — lid flicker during reopen.
    expect(v.update(0.65, 150)).toBe("closed");
    expect(v.update(0.65, 200)).toBe("tracking");
  });

  it("a mid-band hover is a squint, not a blink — releases after the timeout", () => {
    const v = new EyeValidity();
    v.update(0.45, 0);
    expect(v.update(0.45, 200)).toBe("closing");
    expect(v.update(0.45, 500)).toBe("tracking");
  });

  it("a quick dip-and-recover is jaw noise — never reaches closed", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    expect(v.update(0.7, 80)).toBe("tracking");
    expect(v.blinking).toBe(false);
  });

  it("ignores NaN openness without changing state", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    expect(v.update(Number.NaN, 50)).toBe("closing");
    const v2 = new EyeValidity();
    expect(v2.update(Number.NaN, 0)).toBe("tracking");
  });

  it("a 'closed' held past the pathology bound releases instead of freezing forever", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    v.update(0.2, 50);
    expect(v.update(0.2, 100)).toBe("closed");
    // Occlusion: fully-closed openness never recovers — the machine must
    // still un-freeze at the 2.5s pathology bound.
    for (let t = 150; t <= 2400; t += 50) {
      expect(v.update(0.2, t)).toBe("closed");
    }
    let released = false;
    for (let t = 2450; t <= 5000; t += 50) {
      if (v.update(0.2, t) === "tracking" && !v.holding) {
        released = true;
        break;
      }
    }
    expect(released).toBe(true);
  });

  it("a sustained mid-band squint releases to tracking — ptosis isn't a blink", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    v.update(0.2, 50);
    expect(v.update(0.2, 100)).toBe("closed");
    // ~1s of mid-band openness (0.28-0.6) is this user's resting lid, not a
    // held blink — before the squint trap it parked 'closed' for 2.5s on
    // every blink.
    for (let t = 150; t <= 1100; t += 50) {
      expect(v.update(0.45, t)).toBe("closed");
    }
    let released = false;
    for (let t = 1150; t <= 1600; t += 50) {
      if (v.update(0.45, t) === "tracking") {
        released = true;
        break;
      }
    }
    expect(released).toBe(true);
  });
});

describe("coast during hold", () => {
  it("eases along last velocity and caps displacement", () => {
    const moved = coastPosition([0.5, 0.5], [1.0, 0], 200);
    expect(moved[0]).toBeCloseTo(0.545);
    expect(moved[1]).toBe(0.5);
    // Long hold: coast stops, position stays put.
    const held = coastPosition([0.5, 0.5], [1.0, 0], 5000);
    expect(held[0]).toBeCloseTo(0.545);
    // Stale fast velocity can't fly the dot off.
    const capped = coastPosition([0.1, 0.5], [5.0, 0], 400);
    expect(capped[0]).toBeLessThan(0.15);
  });
});

describe("drift monitor", () => {
  it("returns the measured offset when implicit labels are rejected in a consistent direction", () => {
    const monitor = new DriftMonitor();
    let correction: [number, number] | null = null;
    // 5s spacing → the evidence window spans 35s, past the sustained-evidence
    // bar.
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], i * 5000) ?? correction;
    }
    // The returned vector is the map error — applying it undoes the move.
    expect(correction).not.toBeNull();
    expect(correction![0]).toBeCloseTo(0.15);
    expect(correction![1]).toBeCloseTo(0.05);
  });

  it("ignores a burst of consistent rejections inside the evidence window", () => {
    const monitor = new DriftMonitor();
    let correction: [number, number] | null = null;
    // 8 consistent rejections in 7s — plenty of direction consistency but no
    // sustained evidence. This is the cursor-parked-elsewhere failure mode.
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], i * 1000) ?? correction;
    }
    expect(correction).toBeNull();
    // Same rejections keep coming — once the sliding 12-entry window spans
    // 30s it confirms (5s spacing → window covers ~55s).
    for (let i = 8; i < 20; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], 10_000 + (i - 8) * 5000) ?? correction;
    }
    expect(correction).not.toBeNull();
    expect(correction![0]).toBeCloseTo(0.15);
  });

  it("ignores rejections anchored on a single rest spot — a parked cursor", () => {
    const monitor = new DriftMonitor();
    let correction: [number, number] | null = null;
    // 30+ seconds of consistent rejections, but every label came from the
    // same spot — that spot's label quality, not the map, is the problem.
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], i * 5000, [0.05, 0.5]) ?? correction;
    }
    expect(correction).toBeNull();
    // Spread the same rejections across the display and drift confirms.
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], 100_000 + i * 5000, [0.1 + 0.1 * i, 0.5]) ?? correction;
    }
    expect(correction).not.toBeNull();
    expect(correction![0]).toBeCloseTo(0.15);
  });

  it("stays quiet when rejections scatter — the user just looked elsewhere", () => {
    const monitor = new DriftMonitor();
    let correction: [number, number] | null = null;
    const offsets: [number, number][] = [[0.2, 0], [-0.2, 0], [0, 0.2], [0, -0.2], [0.18, 0.1], [-0.18, -0.1], [-0.1, 0.18], [0.1, -0.18]];
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, offsets[i], i * 5000) ?? correction;
    }
    expect(correction).toBeNull();
  });

  it("stays quiet while labels mostly agree, even if a few miss", () => {
    const monitor = new DriftMonitor();
    let correction: [number, number] | null = null;
    for (let i = 0; i < 8; i += 1) {
      const agreed = i % 3 !== 0;
      correction = monitor.record(agreed, agreed ? [0.01, 0.01] : [0.3, 0.3], i * 5000) ?? correction;
    }
    expect(correction).toBeNull();
  });

  it("reset clears the warn cooldown so a new drift can report immediately", () => {
    const monitor = new DriftMonitor();
    for (let i = 0; i < 8; i += 1) {
      monitor.record(false, [0.15, 0.05], i * 5000);
    }
    monitor.reset();
    // Same direction, well inside the old 90s cooldown — must still warn.
    let correction: [number, number] | null = null;
    for (let i = 0; i < 8; i += 1) {
      correction = monitor.record(false, [0.15, 0.05], 40_000 + i * 5000) ?? correction;
    }
    expect(correction).not.toBeNull();
  });
});

describe("head turn gate", () => {
  it("treats a collapsed eye span as a turned head", () => {
    expect(isHeadTurned(60, 160)).toBe(false);
    expect(isHeadTurned(25, 160)).toBe(true);
    expect(isHeadTurned(Number.NaN, 160)).toBe(false);
  });
});

describe("gaze jump gate", () => {
  it("drops an isolated jump and accepts a confirmed fast glance", () => {
    const gate = new GazeJumpGate();
    expect(gate.accept([0.1, 0.1], 0)).toEqual([0.1, 0.1]);
    expect(gate.accept([0.9, 0.9], 30)).toBeNull();
    expect(gate.accept([0.12, 0.1], 60)).toEqual([0.12, 0.1]);
    expect(gate.accept([0.9, 0.9], 90)).toBeNull();
    expect(gate.accept([0.91, 0.89], 120)).toEqual([0.91, 0.89]);
  });

  it("recovers after a tracking gap", () => {
    const gate = new GazeJumpGate();
    gate.accept([0.1, 0.1], 0);
    expect(gate.accept([0.9, 0.9], 1100)).toEqual([0.9, 0.9]);
    expect(gate.accept([Number.NaN, 0.2], 1200)).toBeNull();
  });
});

describe("verify verdict", () => {
  it("buckets errors by target region", () => {
    expect(regionOfTarget([0.5, 0.5])).toBe("center");
    expect(regionOfTarget([0.06, 0.06])).toBe("corner");
    expect(regionOfTarget([0.5, 0.3])).toBe("edge");
    // Edge midpoints are far from center on ONE axis only — not corners.
    expect(regionOfTarget([0.5, 0.06])).toBe("edge");
    expect(regionOfTarget([0.94, 0.5])).toBe("edge");
    const verdict = buildVerifyVerdict([
      { target: [0.5, 0.5], error: 0.05 },
      { target: [0.5, 0.55], error: 0.07 },
      { target: [0.5, 0.1], error: 0.2 },
      { target: [0.9, 0.5], error: 0.3 },
      { target: [0.06, 0.94], error: 0.4 },
      { target: [0.94, 0.94], error: 0.6 }
    ]);
    expect(verdict).not.toBeNull();
    expect(verdict!.samples).toBe(6);
    expect(verdict!.regions.center).toBeCloseTo(0.07);
    expect(verdict!.regions.edge).toBeCloseTo(0.3);
    expect(verdict!.regions.corner).toBeCloseTo(0.6);
    expect(verdict!.median).toBeCloseTo(0.3);
    expect(verdict!.max).toBeCloseTo(0.6);
  });

  it("returns null with no samples", () => {
    expect(buildVerifyVerdict([])).toBeNull();
  });
});

describe("decodeBinnedAngle", () => {
  const bins = new Float32Array(90);

  it("decodes a centered distribution to ~0°", () => {
    bins.fill(-10);
    bins[44] = 0;
    bins[45] = 0;
    expect(decodeBinnedAngle(bins).deg).toBeCloseTo(-2, 0);
  });

  it("decodes an extreme distribution to the bin edge", () => {
    const flat = new Float32Array(90).fill(-30);
    flat[89] = 0;
    const { deg, peak } = decodeBinnedAngle(flat);
    expect(deg).toBeCloseTo(176, 0);
    expect(peak).toBeCloseTo(1, 1);
  });

  it("reports low peak for a flat distribution", () => {
    const { peak } = decodeBinnedAngle(new Float32Array(90));
    expect(peak).toBeCloseTo(1 / 90, 2);
  });

  it("returns a safe neutral for non-finite or empty logits", () => {
    expect(decodeBinnedAngle(new Float32Array([Number.NaN, Number.NaN, Number.NaN]))).toEqual({ deg: 0, peak: 0 });
    expect(decodeBinnedAngle(new Float32Array(0))).toEqual({ deg: 0, peak: 0 });
    // A stray NaN among real logits is skipped, not amplified.
    const logits = new Float32Array(90).fill(-10);
    logits[45] = 0;
    logits[10] = Number.NaN;
    const { deg } = decodeBinnedAngle(logits);
    expect(Number.isFinite(deg)).toBe(true);
    expect(deg).toBeCloseTo(0, 0);
  });
});

describe("AppearanceChannel", () => {
  const angles = { yawDeg: 10, pitchDeg: -5, confidence: 0.6 };
  // Inference takes no time on this clock, so the adaptive period never
  // stretches with how loaded the test machine is.
  const frozen = () => 0;

  it("rate-limits runs and returns smoothed estimates", async () => {
    const channel = new AppearanceChannel(200, 0.5, 500, frozen);
    const estimate = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(1000, estimate);
    channel.maybeRun(1001, estimate); // pending — skipped
    expect(estimate).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => expect(channel.latest(1000)).not.toBeNull());
    expect(channel.latest(1000)!.yawDeg).toBe(10);
    // cadence gate: 100ms < 200ms period
    channel.maybeRun(1100, estimate);
    expect(estimate).toHaveBeenCalledTimes(1);
    channel.maybeRun(1201, estimate);
    expect(estimate).toHaveBeenCalledTimes(2);
  });

  it("reports stale results as null", async () => {
    const channel = new AppearanceChannel(200, 0.5, 300, frozen);
    channel.maybeRun(1000, () => Promise.resolve(angles));
    await vi.waitFor(() => expect(channel.latest(1000)).not.toBeNull());
    expect(channel.latest(1401)).toBeNull();
  });

  it("disables itself after repeated failures", async () => {
    const channel = new AppearanceChannel(10, 0.5, 500, frozen);
    const failing = () => Promise.reject(new Error("boom"));
    for (let i = 0; i < 4; i += 1) {
      channel.maybeRun(i * 20, failing);
      await new Promise((r) => setTimeout(r, 0));
    }
    expect(channel.disabled).toBe(true);
    const ok = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(900, ok);
    expect(ok).not.toHaveBeenCalled();
  });

  it("recovers when estimate throws synchronously", () => {
    const channel = new AppearanceChannel(10, 0.5, 500, frozen);
    channel.maybeRun(0, () => {
      throw new Error("sync boom");
    });
    // pending must be cleared — the next in-period call runs normally.
    const ok = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(20, ok);
    expect(ok).toHaveBeenCalledTimes(1);
  });

  it("clears a pending run whose promise never settles", () => {
    const channel = new AppearanceChannel(10, 0.5, 500, frozen);
    const never = vi.fn().mockImplementation(() => new Promise<never>(() => {}));
    channel.maybeRun(0, never);
    const ok = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(100, ok); // still pending — skipped
    expect(ok).not.toHaveBeenCalled();
    channel.maybeRun(2100, ok); // pending stale > 2s — cleared
    expect(ok).toHaveBeenCalledTimes(1);
  });

  it("rejects non-finite angle estimates without poisoning the EMA", async () => {
    const channel = new AppearanceChannel(10, 0.5, 500, frozen);
    channel.maybeRun(0, () => Promise.resolve({ yawDeg: Number.NaN, pitchDeg: 0, confidence: 0.5 }));
    await new Promise((r) => setTimeout(r, 0));
    expect(channel.latest(100)).toBeNull();
    const ok = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(20, ok);
    await vi.waitFor(() => expect(channel.latest(30)).not.toBeNull());
    expect(channel.latest(30)!.yawDeg).toBe(10);
  });

  it("reset re-enables a failure-disabled channel", async () => {
    const channel = new AppearanceChannel(10, 0.5, 500, frozen);
    const failing = () => Promise.reject(new Error("boom"));
    for (let i = 0; i < 4; i += 1) {
      channel.maybeRun(i * 20, failing);
      await new Promise((r) => setTimeout(r, 0));
    }
    expect(channel.disabled).toBe(true);
    channel.reset();
    expect(channel.disabled).toBe(false);
    const ok = vi.fn().mockResolvedValue(angles);
    channel.maybeRun(100, ok);
    expect(ok).toHaveBeenCalledTimes(1);
  });
});

describe("AppearanceChannel adaptive duty cycle", () => {
  it("backs off when inference is slow (single-threaded ORT)", async () => {
    // A 50ms inference on the injected clock forces the period to 200ms, so a
    // call inside that window is skipped and one outside it runs.
    let clock = 0;
    const channel = new AppearanceChannel(200, 0.5, 2000, () => clock);
    const slow = vi.fn().mockImplementation(() => {
      clock += 50;
      return Promise.resolve({ yawDeg: 0, pitchDeg: 0, confidence: 0.5 });
    });
    channel.maybeRun(0, slow);
    await vi.waitFor(() => expect(channel.latest(200)).not.toBeNull());
    channel.maybeRun(199, slow);
    expect(slow).toHaveBeenCalledTimes(1);
    channel.maybeRun(260, slow);
    expect(slow).toHaveBeenCalledTimes(2);
  });
});

describe("daily-use robustness", () => {
  it("RetinaFace landmarks expose nose and mouth-center anchors", () => {
    const rows = new Float32Array(17);
    // eyes at (80,50),(40,50); nose at (60,70); mouth corners (50,110),(70,110)
    rows.set([0, 0, 0.9, 10, 20, 110, 120, 80, 50, 40, 50, 60, 70, 50, 110, 70, 110], 0);
    const result = parseRetinaFaceOutput(rows, 0.5);
    expect(result.nose).toEqual([60, 70]);
    expect(result.mouthCenter).toEqual([60, 110]);
  });

  it("validity keeps holding through the post-reopen settle window", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    v.update(0.2, 50);
    v.update(0.2, 100); // closed
    v.update(0.65, 150);
    expect(v.update(0.65, 200)).toBe("tracking");
    expect(v.holding).toBe(true); // settle window — post-blink frames don't emit
    v.update(0.9, 330);
    expect(v.holding).toBe(true);
    v.update(0.9, 360); // past 140ms settle
    expect(v.holding).toBe(false);
  });

  it("a dip-and-recover also holds briefly — mid-closure frames passed through", () => {
    const v = new EyeValidity();
    v.update(0.4, 0);
    expect(v.update(0.7, 80)).toBe("tracking");
    expect(v.holding).toBe(true);
    v.update(0.9, 160);
    expect(v.holding).toBe(true);
    v.update(0.9, 200); // past 90ms settle
    expect(v.holding).toBe(false);
  });

  it("saccade filter dwell-locks a sustained fixation and releases on a real look", () => {
    const f = new SaccadeAwareGazeFilter();
    let out: [number, number] | null = null;
    // Sustained fixation: static angles (zero angular velocity), ±0.003 jitter.
    for (let i = 0; i < 14; i += 1) {
      out = f.update(0.5 + (i % 3) * 0.002, 0.5, i * 70, 0, 0);
    }
    expect(f.dwellLocked).toBe(true);
    const anchored = out!;
    // Micro-jitter while anchored must not move the dot at all.
    const again = f.update(0.51, 0.51, 15 * 70, 0, 0);
    expect(again).toEqual(anchored);
    // A genuine re-look (> anchorBreak) releases the anchor immediately.
    const moved = f.update(0.62, 0.55, 16 * 70, 8, 0);
    expect(f.dwellLocked).toBe(false);
    expect(moved[0]).toBeGreaterThan(0.55);
  });

  it("scattered fixation inputs never dwell-lock", () => {
    const f = new SaccadeAwareGazeFilter();
    for (let i = 0; i < 14; i += 1) {
      // Wide scatter (0.04 > anchorSpread 0.012) — a drifting/noisy signal
      // must not freeze in place.
      f.update(0.5 + (i % 2 === 0 ? 0.04 : -0.04), 0.5, i * 70, 0, 0);
    }
    expect(f.dwellLocked).toBe(false);
  });

  it("anchorEnabled defaults to true and disabling it never dwell-locks while smoothing still applies", () => {
    const f = new SaccadeAwareGazeFilter();
    expect(f.anchorEnabled).toBe(true);
    f.anchorEnabled = false;
    let out: [number, number] | null = null;
    // The same sustained-fixation pattern that dwell-locks by default.
    for (let i = 0; i < 14; i += 1) {
      out = f.update(0.5 + (i % 3) * 0.002, 0.5, i * 70, 0, 0);
    }
    expect(f.dwellLocked).toBe(false);
    // Filtering still runs — output stays finite and near the fixation.
    expect(out!.every(Number.isFinite)).toBe(true);
    expect(pointDistance(out!, [0.5, 0.5])).toBeLessThan(0.01);
  });

  it("disabling anchorEnabled mid-lock releases the anchor on the next update", () => {
    const f = new SaccadeAwareGazeFilter();
    for (let i = 0; i < 14; i += 1) {
      f.update(0.5 + (i % 3) * 0.002, 0.5, i * 70, 0, 0);
    }
    expect(f.dwellLocked).toBe(true);
    f.anchorEnabled = false;
    f.update(0.5, 0.5, 15 * 70, 0, 0);
    expect(f.dwellLocked).toBe(false);
  });

  it("saccade filter holds the last output on NaN input and never stores it", () => {
    const f = new SaccadeAwareGazeFilter();
    expect(f.update(0.5, 0.5, 0, 0, 0)).toEqual([0.5, 0.5]);
    expect(f.update(Number.NaN, 0.5, 16, 0, 0)).toEqual([0.5, 0.5]);
    expect(f.update(0.52, 0.5, 32, 0, 0).every(Number.isFinite)).toBe(true);
  });

  it("angle smoother holds the last good angles on a NaN frame", () => {
    const smoother = new GazeAngleSmoother();
    const estimate: GazeEstimate = {
      yawDeg: 2,
      pitchDeg: 1,
      leftYawDeg: 2,
      leftPitchDeg: 1,
      rightYawDeg: 2,
      rightPitchDeg: 1,
      irisDiameterPx: 30,
      eyeOpen: 0.9,
      agreement: 1
    };
    expect(smoother.update(estimate).yawDeg).toBe(2);
    const held = smoother.update({ ...estimate, leftYawDeg: Number.NaN });
    expect(held.yawDeg).toBe(2);
    expect(held.leftYawDeg).toBe(2);
    const next = smoother.update({ ...estimate, leftYawDeg: 4, rightYawDeg: 4, yawDeg: 4 });
    expect(Number.isFinite(next.yawDeg)).toBe(true);
  });
});

// The worker tests drive real frames through the inference pipeline, so
// under a loaded Mac each frame can take far longer than vi.waitFor's 1 s
// default and the whole test longer than vitest's 5 s (#571: set_paused took
// 5.1 s). Generous waits keep them event-driven rather than clock-bound.
const WORKER_WAIT = { timeout: 10_000, interval: 5 };
const WORKER_TEST_TIMEOUT_MS = 30_000;

describe("inference worker", { timeout: WORKER_TEST_TIMEOUT_MS }, () => {
  function workerConfig(accelerator: "auto" | "webgpu" | "wasm" = "wasm"): WebInferenceConfig {
    return {
      runtime: "onnxweb",
      webInferenceWorker: "dedicated",
      webAccelerator: accelerator,
      detector: "yolo",
      backend: "web",
      camera: "0",
      cameraWidth: 640,
      cameraHeight: 480,
      cameraFov: 90,
      scoreThreshold: 0.5,
      displaySizeInch: 31.5,
      displayWidth: 1920,
      displayHeight: 1080,
      calibrationFile: "c.json",
      detectorModel: "det.onnx",
      lipMotionModel: "lip.onnx",
      detectorModelUrl: "det.onnx",
      gazeModelUrl: "gaze.onnx",
      lipMotionModelUrl: "lip.onnx",
      onnxWasmBaseUrl: "/",
      smoothingAlpha: 0.5,
      smoothingAlphaY: 0.5,
      calibrate: false,
      gazeFilter: "saccade",
      filterMincutoff: 1,
      filterBeta: 0.7,
      filterDcutoff: 1,
      disableIrisDistance: false,
      previewFps: 5,
      gazeMaxFps: 30,
      hidePreview: true,
      flipX: true,
      flipY: true,
      cameraScreenX: 0.5,
      cameraScreenY: 0,
      eyePositionWeightX: 1,
      eyePositionWeightY: 0.25,
      retinafaceHeadFaceRatio: 1,
      gazeProjectionMode: "binocular-screen",
      enableLipMotion: false
    };
  }

  // Shared self stub: the worker assigns self.onmessage once at import, so
  // the same object must serve every test in this file.
  const workerMessages: Array<Record<string, unknown>> = [];
  const selfStub: { onmessage: null | ((event: { data: unknown }) => void); postMessage: (message: unknown) => void } = {
    onmessage: null,
    postMessage: (message) => workerMessages.push(message as Record<string, unknown>)
  };

  async function startWorker(accelerator: "auto" | "webgpu" | "wasm" = "wasm") {
    // Cross-test hygiene: module state persists between tests in this file —
    // reset the shared control block before every init.
    workerModelsControl.detectError = null;
    workerModelsControl.createError = null;
    workerModelsControl.createErrorFor = {};
    workerModelsControl.warmupFailures = 0;
    workerModelsControl.disposeHang = false;
    workerModelsControl.detectGate = null;
    workerModelsControl.detectResult = null;
    workerModelsControl.createCalls = [];
    workerModelsControl.detectCalls = 0;
    workerModelsControl.detectInFlight = 0;
    workerModelsControl.maxDetectInFlight = 0;
    vi.stubGlobal("self", selfStub);
    vi.stubGlobal(
      "ImageData",
      class {
        constructor(
          readonly data: Uint8ClampedArray,
          readonly width: number,
          readonly height: number
        ) {}
      }
    );
    vi.stubGlobal(
      "OffscreenCanvas",
      class {
        constructor(
          readonly width: number,
          readonly height: number
        ) {}
        getContext() {
          return {
            drawImage: () => undefined,
            putImageData: () => undefined,
            getImageData: (_x: number, _y: number, w: number, h: number) =>
              new (globalThis.ImageData as unknown as new (d: Uint8ClampedArray, w: number, h: number) => object)(
                new Uint8ClampedArray(w * h * 4),
                w,
                h
              )
          };
        }
      }
    );
    workerMessages.length = 0;
    await import("./inferenceWorker");
    const send = (message: unknown) => selfStub.onmessage?.({ data: message });
    send({ type: "init", config: workerConfig(accelerator) });
    // The pump posts camera_geometry the moment getUserMedia answers —
    // init now parks on it (model build overlaps camera acquisition), so
    // the harness must deliver it or init never reaches calibration_read.
    send({ type: "camera_geometry", width: 640, height: 480, resolutionName: "640x480" });
    await vi.waitFor(() => expect(workerMessages.some((m) => m.type === "calibration_read")).toBe(true), WORKER_WAIT);
    const readRequest = workerMessages.find((m) => m.type === "calibration_read") as { id: number };
    send({ type: "calibration_read_result", id: readRequest.id, response: { ok: true, text: null } });
    await vi.waitFor(() => expect(workerMessages.some((m) => m.type === "backend")).toBe(true), WORKER_WAIT);
    workerMessages.length = 0;
    return send;
  }

  async function sendFrame(send: (message: unknown) => void): Promise<void> {
    const done = workerMessages.filter((m) => m.type === "frame_done").length;
    send({
      type: "frame",
      data: new Uint8ClampedArray(4 * 640 * 480),
      width: 640,
      height: 480,
      captureMs: 1,
      capturedAt: performance.now(),
      droppedFrames: 0,
      mainThreadLongTasks: 0
    });
    await vi.waitFor(() => expect(workerMessages.filter((m) => m.type === "frame_done").length).toBeGreaterThan(done), WORKER_WAIT);
  }

  function gazePayloads(): Array<Record<string, unknown>> {
    return workerMessages
      .filter((m) => m.type === "backend")
      .map((m) => (m as { payload: Record<string, unknown> }).payload)
      .filter((payload) => payload.type === "gaze");
  }

  function statusPayloads(): Array<Record<string, unknown>> {
    return workerMessages
      .filter((m) => m.type === "backend")
      .map((m) => (m as { payload: Record<string, unknown> }).payload)
      .filter((payload) => payload.type === "status");
  }

  // sendFrame() polls with real timers — during a fake-timers recovery the
  // frame must be sent raw and clock advanced manually.
  function sendRawFrame(send: (message: unknown) => void): void {
    send({
      type: "frame",
      data: new Uint8ClampedArray(4 * 640 * 480),
      width: 640,
      height: 480,
      captureMs: 1,
      capturedAt: performance.now(),
      droppedFrames: 0,
      mainThreadLongTasks: 0
    });
  }

  it("set_paused drops frames without emitting and unpause resumes cleanly", async () => {
    const send = await startWorker();
    await sendFrame(send);
    expect(gazePayloads().length).toBeGreaterThan(0);
    workerMessages.length = 0;
    send({ type: "set_paused", paused: true });
    await sendFrame(send);
    await sendFrame(send);
    // Paused frames still post frame_done (the pump handshake) but never a
    // backend payload — no gaze, no status spam.
    expect(workerMessages.filter((m) => m.type === "backend")).toHaveLength(0);
    workerMessages.length = 0;
    send({ type: "set_paused", paused: false });
    await sendFrame(send);
    expect(gazePayloads().length).toBeGreaterThan(0);
    vi.unstubAllGlobals();
  });

  it("no-face frames emit a ~1Hz away heartbeat — liveness, never a sample", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker();
      // Every detect comes back empty — the boot-away case: lastEmitCore is
      // null, so heartbeats start immediately rather than after 8s.
      workerModelsControl.detectResult = { head: null, eyes: [], mouth: null };
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(0);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      const beats = gazePayloads();
      // ~1Hz: four frames over ~3.3s yield 3-4 beats, and the cadence gate
      // means the second frame in the same second can't double-emit.
      expect(beats.length).toBeGreaterThanOrEqual(3);
      expect(beats.length).toBeLessThanOrEqual(4);
      for (const beat of beats) {
        expect(beat.away).toBe(true);
        expect(beat.held_reason).toBe("no_face");
        // Liveness only — no coordinates a consumer could read as a gaze.
        expect(beat.x_norm).toBeUndefined();
        expect(beat.y_norm).toBeUndefined();
      }
      // A face returning clears the marker on the very next valid emit.
      workerModelsControl.detectResult = null;
      await vi.advanceTimersByTimeAsync(0);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(0);
      const tail = gazePayloads().slice(beats.length);
      expect(tail.length).toBeGreaterThan(0);
      expect(tail.every((p) => p.away === undefined && typeof p.x_norm === "number")).toBe(true);
    } finally {
      workerModelsControl.detectResult = null;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("filter_options dwellLock toggles anchoring while frames keep flowing", async () => {
    const send = await startWorker();
    send({ type: "filter_options", dwellLock: false });
    for (let i = 0; i < 10; i += 1) {
      await sendFrame(send);
    }
    // Static fixation that dwell-locks by default — anchoring never engages
    // while disabled, but filtered gaze still emits every frame.
    expect(gazePayloads().length).toBeGreaterThan(0);
    expect(gazePayloads().some((p) => p.gaze_state === "dwell")).toBe(false);
    send({ type: "filter_options", dwellLock: true });
    let locked = false;
    for (let i = 0; i < 12 && !locked; i += 1) {
      await sendFrame(send);
      locked = gazePayloads().some((p) => p.gaze_state === "dwell");
    }
    expect(locked).toBe(true);
    vi.unstubAllGlobals();
  });

  it("rebuilds a lost wasm session after backoff instead of erroring every frame", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker();
      // Detector only runs once searchInterval/DETECT_INTERVAL_MS has
      // elapsed on the fake clock — advance past both so frames hit it.
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send); // healthy frame → lastDetection primed
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("cannot run inference. invalid session id: 12726032");
      sendRawFrame(send); // detect throws → session-lost recovery
      await vi.advanceTimersByTimeAsync(3000);
      await vi.advanceTimersByTimeAsync(0);
      const statuses = statusPayloads().map((p) => String(p.message));
      expect(statuses.some((m) => m.includes("rebuilding sessions"))).toBe(true);
      expect(statuses.some((m) => m === "Models reloaded with wasm")).toBe(true);
      expect(statuses.some((m) => m.includes("inference unrecoverable"))).toBe(false);
      workerModelsControl.detectError = null;
      // Post-recovery frames produce gaze again on the rebuilt session.
      workerMessages.length = 0;
      await vi.advanceTimersByTimeAsync(1100);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(0);
      expect(gazePayloads().length).toBeGreaterThan(0);
    } finally {
      workerModelsControl.detectError = null;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("counts a rebuilt session that fails its probe run as a failed attempt", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker();
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("cannot run inference. invalid session id: 5");
      // First rebuilt session creates cleanly but can't run — must not be
      // declared recovered; attempt 2 succeeds and tracking resumes.
      workerModelsControl.warmupFailures = 1;
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(3000);
      await vi.advanceTimersByTimeAsync(6000);
      await vi.advanceTimersByTimeAsync(0);
      const statuses = statusPayloads().map((p) => String(p.message));
      expect(statuses.filter((m) => m.includes("rebuilding sessions"))).toHaveLength(2);
      expect(statuses.some((m) => m === "Models reloaded with wasm")).toBe(true);
      expect(statuses.some((m) => m.includes("inference unrecoverable"))).toBe(false);
    } finally {
      workerModelsControl.detectError = null;
      workerModelsControl.warmupFailures = 0;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("emits one unrecoverable status after rebuild attempts run out, then goes quiet", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker();
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("cannot run inference. invalid session id: 9");
      workerModelsControl.createError = new Error("memory access out of bounds");
      sendRawFrame(send);
      // 3s + 6s + 12s of backoff, then terminal.
      await vi.advanceTimersByTimeAsync(30000);
      const statuses = statusPayloads().map((p) => String(p.message));
      expect(statuses.filter((m) => m.includes("inference unrecoverable — restart tracking"))).toHaveLength(1);
      // Terminal: later frames still ack via frame_done but emit nothing —
      // the dead-session spam that wedged the old loop is gone.
      workerMessages.length = 0;
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(0);
      expect(workerMessages.filter((m) => m.type === "backend")).toHaveLength(0);
      expect(workerMessages.some((m) => m.type === "frame_done")).toBe(true);
    } finally {
      workerModelsControl.detectError = null;
      workerModelsControl.createError = null;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("rebuilds webgpu in place on the short ladder before any wasm demotion", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker("webgpu");
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send); // healthy frame on webgpu — lastDetection primed
      await vi.advanceTimersByTimeAsync(1100);
      // Dawn-style device loss mid-run: recoverable, and the fast path is
      // retried first — the tracker must prefer webgpu ALWAYS.
      workerModelsControl.detectError = new Error("AbortError: the GPU device is lost");
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1500);
      await vi.advanceTimersByTimeAsync(0);
      const statuses = statusPayloads().map((p) => String(p.message));
      expect(statuses.some((m) => m.includes("rebuilding webgpu sessions"))).toBe(true);
      expect(statuses.some((m) => m === "Models reloaded with webgpu")).toBe(true);
      expect(statuses.some((m) => m.includes("inference unrecoverable"))).toBe(false);
      // Init + one recovery rung, both webgpu — wasm was never touched.
      expect(workerModelsControl.createCalls).toEqual(["webgpu", "webgpu"]);
    } finally {
      workerModelsControl.detectError = null;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("demotes to wasm only after the webgpu ladder exhausts, then quietly re-promotes", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker("webgpu");
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("ORT_ENFORCE failed in MapAsync callback");
      workerModelsControl.createErrorFor.webgpu = new Error("webgpu device unavailable");
      sendRawFrame(send);
      // webgpu rungs (1.5s + 5s) both fail, then wasm rung 1 lands at +3s.
      await vi.advanceTimersByTimeAsync(1500 + 5000 + 3000 + 100);
      const statuses = statusPayloads().map((p) => String(p.message));
      expect(statuses.some((m) => m.includes("webgpu session rebuilds exhausted"))).toBe(true);
      expect(statuses.some((m) => m === "Models reloaded with wasm")).toBe(true);
      expect(workerModelsControl.createCalls).toEqual(["webgpu", "webgpu", "webgpu", "wasm"]);
      // wasm is never a permanent silent downgrade: the landing armed a
      // quiet re-promotion probe at +60s.
      workerModelsControl.detectError = null;
      workerModelsControl.createErrorFor = {};
      workerMessages.length = 0;
      await vi.advanceTimersByTimeAsync(60000);
      await vi.advanceTimersByTimeAsync(2500); // let the swapped-set dispose drain
      expect(workerModelsControl.createCalls.at(-1)).toBe("webgpu");
      const laterStatuses = statusPayloads();
      expect(laterStatuses.some((p) => p.message === "Models reloaded with webgpu")).toBe(true);
      // Quiet promotion: the only emitted status is the info-level reload —
      // no warning/error feeds the host a false wedge signature.
      expect(laterStatuses.every((p) => p.level === "info")).toBe(true);
    } finally {
      workerModelsControl.detectError = null;
      workerModelsControl.createErrorFor = {};
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("stays on wasm silently when the re-promotion probe declines", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker("webgpu");
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("invalid session id: 77");
      // webgpu keeps failing — the tracker lands on wasm and stays there,
      // retrying quietly on the ~5min cadence without spamming statuses.
      workerModelsControl.createErrorFor.webgpu = new Error("webgpu still unavailable");
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1500 + 5000 + 3000 + 100);
      expect(statusPayloads().map((p) => String(p.message)).some((m) => m === "Models reloaded with wasm")).toBe(true);
      workerModelsControl.detectError = null;
      workerMessages.length = 0;
      // First probe at +60s fails quietly; next is scheduled at +5min.
      await vi.advanceTimersByTimeAsync(60000 + 100);
      expect(statusPayloads()).toHaveLength(0);
      const createsAfterProbe = workerModelsControl.createCalls.length;
      await vi.advanceTimersByTimeAsync(300000);
      // Second quiet attempt fired — still no host-visible statuses.
      expect(workerModelsControl.createCalls.length).toBeGreaterThan(createsAfterProbe);
      expect(statusPayloads()).toHaveLength(0);
    } finally {
      workerModelsControl.detectError = null;
      workerModelsControl.createErrorFor = {};
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("bounds a wedged session dispose so recovery still proceeds", async () => {
    vi.useFakeTimers();
    try {
      const send = await startWorker("wasm");
      await vi.advanceTimersByTimeAsync(300);
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(1100);
      workerModelsControl.detectError = new Error("cannot run inference. invalid session id: 42");
      // ORT 1.26 could wedge release() forever inside a Dawn callback — the
      // 5s dispose timeout must unstick the ladder instead of ending the run.
      workerModelsControl.disposeHang = true;
      const warnSpy = vi.spyOn(console, "warn");
      sendRawFrame(send);
      await vi.advanceTimersByTimeAsync(5000 + 3000 + 100);
      await vi.advanceTimersByTimeAsync(0);
      const statuses = statusPayloads().map((p) => String(p.message));
      // The dispose failure is console-only telemetry; the recovery ladder
      // proceeding past the hung release is what must be host-visible.
      expect(warnSpy.mock.calls.some((call) => String(call[0]).includes("dispose failed"))).toBe(true);
      expect(statuses.some((m) => m === "Models reloaded with wasm")).toBe(true);
    } finally {
      workerModelsControl.detectError = null;
      workerModelsControl.disposeHang = false;
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });

  it("serializes frame processing — a second frame is dropped+acked, never overlapped", async () => {
    vi.useFakeTimers();
    let releaseGate: (() => void) | undefined;
    try {
      const send = await startWorker("wasm");
      await vi.advanceTimersByTimeAsync(300);
      workerModelsControl.detectGate = new Promise<void>((resolve) => {
        releaseGate = resolve;
      });
      sendRawFrame(send); // parks inside detect on the gate
      await vi.advanceTimersByTimeAsync(0);
      expect(workerModelsControl.detectCalls).toBe(1);
      sendRawFrame(send); // mid-flight: in-flight guard drops it but acks —
      // the pump's dropped-frame contract is preserved.
      expect(workerMessages.filter((m) => m.type === "frame_done")).toHaveLength(1);
      // Frame 2 never reached detect — no overlapping calls on shared state.
      expect(workerModelsControl.detectCalls).toBe(1);
      // A control message doesn't queue behind the parked frame — stop lands
      // immediately (no stop() deadlock while inference is mid-flight).
      send({ type: "stop" });
      workerModelsControl.detectGate = null;
      releaseGate?.();
      await vi.advanceTimersByTimeAsync(0);
      expect(workerMessages.filter((m) => m.type === "frame_done")).toHaveLength(2);
      expect(workerModelsControl.maxDetectInFlight).toBe(1);
    } finally {
      workerModelsControl.detectGate = null;
      releaseGate?.();
      // stop left the module stopped; a fresh init in the next test resets it.
      vi.useRealTimers();
    }
    vi.unstubAllGlobals();
  });
});

// The model-input samplers were rewritten to scalar bilinear reads (the old
// path allocated ~5 arrays per output pixel). These reference builders keep
// the ORIGINAL per-pixel math so the optimized output can be proven
// bit-identical rather than approximately-equal.
describe("scalar bilinear input sampling", () => {
  function refPixel(data: Uint8ClampedArray, width: number, x: number, y: number): [number, number, number] {
    const offset = (y * width + x) * 4;
    return [data[offset], data[offset + 1], data[offset + 2]];
  }

  function refSampleRgb(data: Uint8ClampedArray, width: number, height: number, x: number, y: number): [number, number, number] {
    if (x < 0 || y < 0 || x > width - 1 || y > height - 1) {
      return [0, 0, 0];
    }
    const x0 = Math.floor(x);
    const y0 = Math.floor(y);
    const x1 = Math.min(width - 1, x0 + 1);
    const y1 = Math.min(height - 1, y0 + 1);
    const wx = x - x0;
    const wy = y - y0;
    const c00 = refPixel(data, width, x0, y0);
    const c10 = refPixel(data, width, x1, y0);
    const c01 = refPixel(data, width, x0, y1);
    const c11 = refPixel(data, width, x1, y1);
    return [0, 1, 2].map((channel) => {
      const top = c00[channel] * (1 - wx) + c10[channel] * wx;
      const bottom = c01[channel] * (1 - wx) + c11[channel] * wx;
      return top * (1 - wy) + bottom * wy;
    }) as [number, number, number];
  }

  // A noisy fixture with the head box pushed off-frame so both the in-frame
  // bilinear taps and the out-of-frame neutral path get exercised.
  function fixtureFrame(width: number, height: number): { data: Uint8ClampedArray; width: number; height: number } {
    const data = new Uint8ClampedArray(width * height * 4);
    for (let i = 0; i < data.length; i += 1) {
      data[i] = (i * 37 + 11) % 256;
    }
    return { data, width, height };
  }

  function firstMismatch(actual: ArrayLike<number>, expected: ArrayLike<number>): number {
    for (let i = 0; i < expected.length; i += 1) {
      if (!Object.is(actual[i], expected[i])) {
        return i;
      }
    }
    return -1;
  }

  it("createGazeInput is bit-identical to the naive per-pixel path", () => {
    const frame = fixtureFrame(96, 64);
    // Head hangs off the left/top edge so some source taps sample out-of-frame.
    const head = { classId: 7, score: 1, x1: -10, y1: -8, x2: 60, y2: 50 };
    const eyes = [
      { classId: 17, score: 1, x1: 2, y1: 10, x2: 14, y2: 18 },
      { classId: 17, score: 1, x1: 30, y1: 10, x2: 42, y2: 18 }
    ];
    const crop = createGazeInput(frame as ImageData, head, eyes);

    const left: [number, number] = [(eyes[0].x1 + eyes[0].x2) * 0.5, (eyes[0].y1 + eyes[0].y2) * 0.5];
    const right: [number, number] = [(eyes[1].x1 + eyes[1].x2) * 0.5, (eyes[1].y1 + eyes[1].y2) * 0.5];
    const eyeCenter: [number, number] = [(left[0] + right[0]) * 0.5, (left[1] + right[1]) * 0.5];
    const eyeDistance = Math.hypot(right[0] - left[0], right[1] - left[1]);
    const cropSize = Math.max((head.x2 - head.x1) / 1.5, eyeDistance) * 1.5;
    const scale = GAZE_INPUT_SIZE / Math.max(1, cropSize);
    const inverseScale = 1 / scale;
    const inverseTx = eyeCenter[0] - GAZE_INPUT_SIZE * 0.5 * inverseScale;
    const inverseTy = eyeCenter[1] - GAZE_INPUT_SIZE * 0.5 * inverseScale;
    const plane = GAZE_INPUT_SIZE * GAZE_INPUT_SIZE;
    const reference = new Float32Array(3 * plane);
    for (let y = 0; y < GAZE_INPUT_SIZE; y += 1) {
      for (let x = 0; x < GAZE_INPUT_SIZE; x += 1) {
        const [r, g, b] = refSampleRgb(frame.data, frame.width, frame.height, x * inverseScale + inverseTx, y * inverseScale + inverseTy);
        const dst = y * GAZE_INPUT_SIZE + x;
        reference[dst] = r / 127.5 - 1;
        reference[plane + dst] = g / 127.5 - 1;
        reference[plane * 2 + dst] = b / 127.5 - 1;
      }
    }
    expect(firstMismatch(crop.input, reference)).toBe(-1);
    // The geometry outputs are the un-sampled part of the contract.
    expect(crop.inverseScale).toBe(inverseScale);
    expect(crop.inverseTx).toBe(inverseTx);
    expect(crop.inverseTy).toBe(inverseTy);
  });

  it("createAppearanceInput is bit-identical to the naive per-pixel path", () => {
    const frame = fixtureFrame(120, 80);
    const head = { classId: 7, score: 1, x1: -20, y1: 4, x2: 90, y2: 70 };
    const actual = createAppearanceInput(frame as ImageData, head);

    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    const headCx = (head.x1 + head.x2) * 0.5;
    const headCy = (head.y1 + head.y2) * 0.5;
    const side = Math.max(head.x2 - head.x1, head.y2 - head.y1) * 1.5;
    const scale = APPEARANCE_INPUT_SIZE / Math.max(1, side);
    const inverseScale = 1 / scale;
    const inverseTx = headCx - APPEARANCE_INPUT_SIZE * 0.5 * inverseScale;
    const inverseTy = headCy - APPEARANCE_INPUT_SIZE * 0.5 * inverseScale;
    const plane = APPEARANCE_INPUT_SIZE * APPEARANCE_INPUT_SIZE;
    const reference = new Float32Array(3 * plane);
    for (let y = 0; y < APPEARANCE_INPUT_SIZE; y += 1) {
      for (let x = 0; x < APPEARANCE_INPUT_SIZE; x += 1) {
        const [r, g, b] = refSampleRgb(frame.data, frame.width, frame.height, x * inverseScale + inverseTx, y * inverseScale + inverseTy);
        const dst = y * APPEARANCE_INPUT_SIZE + x;
        reference[dst] = (r / 255 - mean[0]) / std[0];
        reference[plane + dst] = (g / 255 - mean[1]) / std[1];
        reference[plane * 2 + dst] = (b / 255 - mean[2]) / std[2];
      }
    }
    expect(firstMismatch(actual, reference)).toBe(-1);
  });
});
