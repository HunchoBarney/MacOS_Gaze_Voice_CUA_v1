import type { BackendMessage, GazeProjectionMode, ImplicitLabelKind } from "../global";

export const CAMERA_WIDTH = 640;
export const CAMERA_HEIGHT = 480;
export const RETINAFACE_INPUT_WIDTH = 640;
export const RETINAFACE_INPUT_HEIGHT = 480;
export const YOLO_INPUT_WIDTH = 640;
export const YOLO_INPUT_HEIGHT = 480;
export const YOLO_CLASS_COUNT = 28;
export const YOLO_EYE_SCORE_THRESHOLD = 0.2;
export const YOLO_NMS_IOU_THRESHOLD = 0.45;
export const GAZE_INPUT_SIZE = 160;
export const HEAD_CLASS_ID = 7;
export const EYE_CLASS_ID = 17;
export const MOUTH_CLASS_ID = 19;
export const LIP_MOTION_INPUT_WIDTH = 48;
export const LIP_MOTION_INPUT_HEIGHT = 30;
export const LIP_MOTION_OPEN_THRESHOLD = 0.5;
export const LIP_MOTION_MARGIN_TOP = 2;
export const LIP_MOTION_MARGIN_BOTTOM = 6;
export const LIP_MOTION_MARGIN_LEFT = 2;
export const LIP_MOTION_MARGIN_RIGHT = 2;
export const AVERAGE_HEAD_WIDTH_M = 0.16;
export const CAMERA_HORIZONTAL_FOV_DEG = 90;
const IRIS_IDX_481 = [248, 252, 224, 228, 232, 236, 240, 244];
export const IRIS_DIAMETER_M = 0.0117;
export const BLINK_OPEN_THRESHOLD = 0.35;
export const BLINK_CLOSE_THRESHOLD = 0.28;

export const MIN_EYE_SPAN_RATIO = 0.2;
export const DISTANCE_MIN_M = 0.15;
export const DISTANCE_MAX_M = 3.0;
export const DISTANCE_SMOOTHING_ALPHA = 0.35;
export const CALIBRATION_FIT_MAX_ERROR = 0.18;
// Feature-vector schema epoch for persisted calibration payloads. v1 is the
// unversioned era where headYawProxy/headPitchProxy held line-ratio proxies;
// v2 is metric degrees from the Kabsch mesh fit (~50× dim-scale shift). Bump
// this whenever a GazeFeature dim changes semantics — same-width vectors
// with different meaning are the case per-entry checks cannot catch.
export const FEATURE_SCHEMA_VERSION = 2;

// Single home for the recoverable-session classifier — the frame loops in
// webRuntime.ts and inferenceWorker.ts both route estimate/detect failures
// through their recovery ladders based on this verdict, so the signature
// list must live in exactly one place or the two runtimes drift (they
// already did once: name === vs name.includes("aborterror")). Lives in
// core (not runtimes) because the worker test harness mocks runtimes
// wholesale — and because this is a pure predicate, no session machinery.
export function isRecoverableInferenceError(error: unknown): boolean {
  // Case-insensitive: ORT/Dawn error strings vary in casing across versions
  // (AbortError vs aborterror, MapAsync vs mapAsync).
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  const name = error instanceof Error ? error.name.toLowerCase() : "";
  return (
    message.includes("ortrun") ||
    // A run against a released/dead session — only a rebuild can fix it.
    message.includes("invalid session id") ||
    message.includes("bad_array_new_length") ||
    message.includes("failed to call") ||
    message.includes("memory access out of bounds") ||
    message.includes("error_code") ||
    // Dawn/WebGPU device-loss signatures — device loss can still surface
    // mid-run on real GPUs; these must start the (webgpu-first) ladder,
    // not spam frames.
    message.includes("device is lost") ||
    message.includes("device lost") ||
    message.includes("instance reference") ||
    message.includes("mapasync") ||
    message.includes("aborterror") ||
    name === "aborterror"
  );
}
// 1.3 is a deliberate overshoot candidate — the eye-position weight is allowed
// to exceed 1 slightly, so the projectFeatures/retune clamps allow up to it.
const WEIGHT_X_CANDIDATES = [1.0, 0.7, 1.3];
const WEIGHT_Y_CANDIDATES = [0.25, 0.0, 0.15, 0.4, 0.6];
const EYE_WEIGHT_X_MAX = 1.3;
// In-memory bound for the learned sample pool — the persisted slice is
// capped separately at write time, but without this the live pool (and every
// refit's cost) grew without limit across sessions.
const MAX_POOL_SAMPLES = 1200;
// Hard cap that keeps the O(nk² + k³) refit bounded no matter how much
// evidence a session accrues — the fit pool feeds the design matrix and each
// RBF center is a solve row (RBF centers have their own cap in rbfFit).
const FIT_POOL_CAP = 400;

// Invisible calibration: labels from ordinary use (cursor rests, clicks,
// voice-named picks, the text caret) fit the map instead of a calibration
// screen. Each kind names how far back the eyes were on the target, whether
// it may seed a map from nothing, whether it joins the main fit pool, and
// the weight it carries as residual-bias evidence when it doesn't. A commit
// that gaze itself chose only echoes the map's own guess, so it is low-weight
// residual evidence, never ground truth. A resting cursor is no evidence at
// all: people read elsewhere while it sits still, and on the owner's Mac those
// rests filled the pool with one screen-centre patch the map then memorised.
export type { ImplicitLabelKind };
export const IMPLICIT_LABEL_KINDS: Record<ImplicitLabelKind, { lookbackMs: number; bootstrap: boolean; mainPool: boolean; biasWeight: number }> = {
  cursor_rest: { lookbackMs: 250, bootstrap: false, mainPool: false, biasWeight: 0 },
  click: { lookbackMs: 120, bootstrap: true, mainPool: true, biasWeight: 0 },
  voice: { lookbackMs: 600, bootstrap: true, mainPool: true, biasWeight: 0 },
  caret: { lookbackMs: 150, bootstrap: false, mainPool: true, biasWeight: 0 },
  gaze_pick: { lookbackMs: 250, bootstrap: false, mainPool: false, biasWeight: 0.3 }
};
export function isImplicitLabelKind(value: unknown): value is ImplicitLabelKind {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(IMPLICIT_LABEL_KINDS, value);
}
// Personal samples before a map counts as settled. Below it refits run on a
// short cadence and the drift monitor stays quiet: a learning map's misses
// are not a moved camera.
export const LEARNING_POOL_TARGET = 60;
const LEARNING_REFIT_MIN_LABELS = 8;
const LEARNING_REFIT_INTERVAL_MS = 10_000;
// A map from nothing needs labels spread across the screen first.
export const BOOTSTRAP_MIN_LABELS = 16;
const BOOTSTRAP_MIN_SPREAD: [number, number] = [0.3, 0.25];
const LEARNED_ERROR_WINDOW = 40;
const LEARNED_ERROR_MIN_LABELS = 10;
// The feature map has dozens of dims; on a few implicit labels its ridge fit
// interpolates noise. Implicit fits stay affine until the pool can carry it.
const IMPLICIT_FEATURE_MAP_MIN_SAMPLES = 40;
// Accept gate in normalized screen units: 2.5x the learned median error,
// never tighter than the settled-map gate. Its ceiling is about a fifth of
// the screen for a decent map and widens with a bad one (1.5x its median, at
// most half the screen): a map that misses by 0.4 must not veto the labels
// that would correct it, or the pool only ever confirms where it already
// points. Held-out adoption (refitWithImplicit) keeps a wide gate honest.
// Before any error is learned, a settled map keeps the tight gate and a
// learning one starts wide.
export function implicitAcceptGate(learnedMedian: number | null, learning: boolean): number {
  if (learnedMedian === null) {
    return learning ? 0.22 : 0.09;
  }
  const ceiling = Math.min(0.5, Math.max(0.22, learnedMedian * 1.5));
  return Math.min(ceiling, Math.max(0.09, learnedMedian * 2.5));
}

export interface CameraResolution {
  name?: string;
  width: number;
  height: number;
}

// 720p default: roughly double the iris pixels of VGA — the accuracy lane's
// reason for capturing above VGA. A sensor that can't deliver it falls back
// to VGA in webRuntime.openCamera; an explicit --camera-resolution stays
// exact-or-fail (main.cjs only leaves cameraResolutionName unset when no
// flag was passed, which is how the runtime tells the two apart).
export const DEFAULT_CAMERA_RESOLUTION: CameraResolution = { name: "HD", width: 1280, height: 720 };
export const FALLBACK_CAMERA_RESOLUTION: CameraResolution = { name: "VGA", width: CAMERA_WIDTH, height: CAMERA_HEIGHT };

const CAMERA_RESOLUTION_PRESETS = new Map<string, CameraResolution>();
for (const [name, width, height, aliases] of [
  ["QQVGA", 160, 120, ["QQVGA"]],
  ["QVGA", 320, 240, ["QVGA"]],
  ["VGA", 640, 480, ["VGA"]],
  ["SVGA", 800, 600, ["SVGA"]],
  ["XGA", 1024, 768, ["XGA"]],
  ["HD", 1280, 720, ["HD", "720p"]],
  ["SXGA", 1280, 1024, ["SXGA"]],
  ["UXGA", 1600, 1200, ["UXGA"]],
  ["Full HD", 1920, 1080, ["Full HD", "1080p"]],
  ["3MP", 2048, 1536, ["3MP"]],
  ["QHD", 2560, 1440, ["QHD", "WQHD", "1440p"]],
  ["5MP", 2592, 1944, ["5MP"]],
  ["6MP", 3072, 2048, ["6MP"]],
  ["4K UHD", 3840, 2160, ["4K UHD"]],
  ["DCI 4K", 4096, 2160, ["DCI 4K"]],
  ["12MP", 4000, 3000, ["12MP"]],
  ["5K", 5120, 2880, ["5K"]],
  ["6K", 6144, 3456, ["6K"]],
  ["8K UHD", 7680, 4320, ["8K UHD"]],
  ["12K", 12288, 6480, ["12K"]]
] as const) {
  const resolution = { name, width, height };
  for (const alias of aliases) {
    CAMERA_RESOLUTION_PRESETS.set(normalizeCameraResolutionName(alias), resolution);
  }
}
const REJECTED_CAMERA_RESOLUTION_NAMES = new Set(["2mp", "4mp", "8mp"]);

export function normalizeCameraResolutionName(value: string): string {
  return Array.from(value.toLowerCase()).filter((ch) => /[a-z0-9]/.test(ch)).join("");
}

export function parseCameraResolution(value: string): CameraResolution {
  const raw = value.trim();
  const sizeMatch = raw.match(/^(\d+)\s*[xX×]\s*(\d+)$/);
  if (sizeMatch) {
    const width = Number.parseInt(sizeMatch[1], 10);
    const height = Number.parseInt(sizeMatch[2], 10);
    if (width <= 0 || height <= 0) {
      throw new Error("camera resolution width and height must be positive integers");
    }
    return { width, height };
  }
  const normalized = normalizeCameraResolutionName(raw);
  if (REJECTED_CAMERA_RESOLUTION_NAMES.has(normalized)) {
    throw new Error(`camera resolution alias is not accepted; use WIDTHxHEIGHT instead: ${value}`);
  }
  const preset = CAMERA_RESOLUTION_PRESETS.get(normalized);
  if (!preset) {
    throw new Error(`unknown camera resolution: ${value}`);
  }
  // Copy, not the shared preset object — callers annotate/mutate the result.
  return { ...preset };
}

export interface Detection {
  classId: number;
  score: number;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

export interface DetectionResult {
  head: Detection | null;
  eyes: Detection[];
  mouth: Detection | null;
  // RetinaFace landmark anchors (image px): nose is a jaw-invariant head-pose
  // anchor, mouthCenter is the jaw-motion signal for talk-robustness.
  nose?: [number, number];
  mouthCenter?: [number, number];
}

export interface GazeEstimate {
  yawDeg: number;
  pitchDeg: number;
  leftYawDeg: number;
  leftPitchDeg: number;
  rightYawDeg: number;
  rightPitchDeg: number;
  irisDiameterPx: number;
  eyeOpen: number;
  agreement: number;
  leftIrisPx?: [number, number][];
  rightIrisPx?: [number, number][];
  leftEyeballPx?: [number, number];
  rightEyeballPx?: [number, number];
  leftIrisCenterPx?: [number, number];
  rightIrisCenterPx?: [number, number];
  depthHealthy?: boolean;
  // Per-eye mesh descriptors: iris ellipse axis ratio + orientation, lid
  // aperture ratio (mesh height ÷ iris diameter), and iris offset inside the
  // eye-mesh bbox. Detector-box independent, so jaw motion can't corrupt them.
  // (The "Ecc" name is kept for saved-schema compat — the value is a
  // minor/major axis ratio, not a true eccentricity.)
  leftEllipseEcc?: number;
  rightEllipseEcc?: number;
  leftEllipseAngle?: [number, number];
  rightEllipseAngle?: [number, number];
  leftApertureRatio?: number;
  rightApertureRatio?: number;
  leftMeshOffset?: [number, number];
  rightMeshOffset?: [number, number];
  // Stable-subset camera-space points (x = image right, y = image down,
  // z = into the scene) for the metric head-pose fit — the runtimes rigid-fit
  // them against a session baseline rather than trusting yaw/pitch proxies.
  headPosePoints?: Float32Array;
}

export interface GazeFeature {
  point: [number, number];
  eyeCenterPx: [number, number];
  leftEyePx: [number, number];
  rightEyePx: [number, number];
  leftYawDeg: number;
  leftPitchDeg: number;
  rightYawDeg: number;
  rightPitchDeg: number;
  headWidthPx: number;
  irisDiameterPx: number;
  eyeOpen: number;
  distanceM: number;
  // Capture-frame size the feature was extracted from — the vectorizer
  // normalizes px terms by these, so a VGA-fallback session and a 720p
  // session produce commensurate dims. Optional because persisted samples
  // predate the field; they were all captured at VGA and vectorize under
  // the CAMERA_WIDTH/HEIGHT constants.
  frameWidth?: number;
  frameHeight?: number;
  // Iris position inside its eye box, normalized to box half-extents (~[-1,1]).
  // Head-pose tolerant — the box moves with the head, the iris inside it with
  // gaze. This is the primary signal in WebGazer-style trackers.
  leftIrisOffset?: [number, number];
  rightIrisOffset?: [number, number];
  // Metric head pose from the Kabsch mesh fit, in degrees (field names kept
  // for saved-schema compat — they used to hold the nose/eye-line proxies,
  // which remain the fallback when the mesh fit can't run). They let the
  // regression learn how much of the "gaze" signal is actually head
  // rotation, so adjusting posture or talking doesn't drag the dot.
  // headRollRad stays radians — the vectorizer de-rotates gaze angles by it.
  headRollRad?: number;
  headYawProxy?: number;
  headPitchProxy?: number;
  // Mesh-derived descriptors — detector-box independent (Phase 3):
  // per-eye iris ellipse axis ratio + sin/cos of the ellipse angle, lid
  // aperture ratio, and iris offset inside the eye-mesh bounding box.
  leftEllipseEcc?: number;
  rightEllipseEcc?: number;
  leftEllipseAngle?: [number, number];
  rightEllipseAngle?: [number, number];
  leftApertureRatio?: number;
  rightApertureRatio?: number;
  leftMeshOffset?: [number, number];
  rightMeshOffset?: [number, number];
  // Appearance-model channels (Phase 4): EMA-smoothed yaw/pitch from the
  // MobileOne gaze net, plus its softmax-peak confidence. Absent/stale → 0s so
  // maps trained without the model still apply unchanged.
  appYawDeg?: number;
  appPitchDeg?: number;
  appConf?: number;
  // Jaw-motion channels (RetinaFace landmarks): mouth-center offset from the
  // eye midpoint normalized by eye span — the regression learns to subtract
  // jaw-drop artifacts instead of reading them as gaze pitch.
  jawX?: number;
  jawY?: number;
  // Head-frame position: eye midpoint relative to head-box center, normalized
  // by head width. Distance- and translation-invariant, so leaning in/out or
  // shifting in the chair doesn't shift the mapped point.
  headFrameX?: number;
  headFrameY?: number;
  // Position-conditioned appearance fusion: appearance angles (deg, same
  // units as appYawDeg/appPitchDeg) gated by the eye-midpoint's head-frame
  // position, plus confidence × the head-frame radius — the map learns how
  // much to trust the ensemble signal at each head pose. Assembled at
  // feature construction (0 when a factor is absent); a persisted sample
  // that lacks them vectorizes NaN and isUsableSample drops it.
  appYawHeadFrameX?: number;
  appYawHeadFrameY?: number;
  appPitchHeadFrameX?: number;
  appPitchHeadFrameY?: number;
  appConfHeadFrameRadius?: number;
}

export interface ProjectionResult {
  point: [number, number];
  fallbackReason?: string;
}

export interface CalibrationGeometry {
  eye_position_weight_x: number;
  eye_position_weight_y: number;
}

export interface CalibrationPayload {
  raw_projection?: "unclipped-v1" | "unclipped-v2" | "featuremap-v3";
  affine: number[][];
  rbf?: {
    sigma: number;
    centers: [number, number][];
    weights: [number, number][];
  } | null;
  feature_map?: {
    coeffs: number[][];
    mean: number[];
    scale: number[];
  } | null;
  feature_rbf?: {
    sigma: number;
    centers: [number, number][];
    weights: [number, number][];
  } | null;
  geometry?: CalibrationGeometry | null;
  source_bounds?: {
    min: number[];
    max: number[];
    margin?: number;
  };
  samples?: Array<{ raw: [number, number]; target: [number, number] }>;
  // Full-feature sample pool — persists across restarts so the map keeps
  // improving with use (implicit labels) instead of resetting each launch.
  // `samples` above keeps only raw points for back-compat; this carries the
  // real GazeFeatures needed to refit.
  feature_samples?: Array<{ feature: GazeFeature; target: [number, number] }>;
  validation?: Array<{ raw: [number, number]; target: [number, number]; error: number }>;
  verify_verdict?: VerifyVerdict;
  // Persistent translation correction applied on top of the map — the
  // self-heal for a repositioned laptop/camera. Persisted so a move made in
  // one session stays corrected in the next.
  output_offset?: [number, number];
  // Per-user residual-bias field (fitResidualBias): normalized-screen
  // correction layered over the map's own output. Raw-space like the affine
  // chain — it drops on a context-fingerprint mismatch.
  residual_map?: {
    grid: number;
    offsets: number[][];
    counts?: number[];
  } | null;
  // The projector/display context the raw-space fit was produced under — see
  // calibrationContextFingerprint. On load, a mismatch means the display,
  // projection mode, or camera changed: the affine chain, source bounds, and
  // persisted drift offset are stale and drop; feature-space state
  // (feature_map, feature samples, eye weights) is camera-domain and
  // legitimately survives.
  context_fingerprint?: string;
  // Feature-vector schema epoch. Absent = v1 (pre-metric-pose), where
  // headYawProxy/headPitchProxy held line-ratio proxies; v2 = metric
  // degrees from the Kabsch fit. A mismatch drops feature_map and
  // feature_samples — the vectorizer can't detect the ~50× pose-dim
  // scale shift, so the file itself must declare which semantics it was
  // written under.
  feature_version?: number;
}

// Verify-sweep outcome for a pending fit: normalized-screen error statistics
// plus medians bucketed by target region, so corner/edge regressions surface
// instead of being averaged into one number.
export interface VerifyVerdict {
  median: number;
  p90: number;
  max: number;
  samples: number;
  regions: {
    center?: number;
    edge?: number;
    corner?: number;
  };
}

export function regionOfTarget(target: [number, number]): "center" | "edge" | "corner" {
  const dx = Math.abs(target[0] - 0.5);
  const dy = Math.abs(target[1] - 0.5);
  if (Math.hypot(dx, dy) < 0.2) return "center";
  // True corners only: an edge midpoint is far on ONE axis and centred on the
  // other — the old radial check mislabeled those as corners.
  return dx > 0.35 && dy > 0.35 ? "corner" : "edge";
}

function medianOf(values: number[]): number | undefined {
  if (values.length === 0) return undefined;
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

export function buildVerifyVerdict(validation: Array<{ target: [number, number]; error: number }>): VerifyVerdict | null {
  if (validation.length === 0) {
    return null;
  }
  const errors = validation.map((v) => v.error).sort((a, b) => a - b);
  const regions: VerifyVerdict["regions"] = {};
  for (const region of ["center", "edge", "corner"] as const) {
    const bucket = validation.filter((v) => regionOfTarget(v.target) === region).map((v) => v.error);
    const median = medianOf(bucket);
    if (median !== undefined) {
      regions[region] = Number(median.toFixed(4));
    }
  }
  return {
    median: errors[Math.floor(errors.length / 2)],
    p90: errors[Math.floor(errors.length * 0.9)],
    max: errors[errors.length - 1],
    samples: errors.length,
    regions
  };
}

export interface CalibrationIO {
  read(path: string): Promise<{ ok: true; text: string | null } | { ok: false; error: string }>;
  write(path: string, payload: unknown): Promise<{ ok: true; path: string } | { ok: false; error: string }>;
}

export function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

export function validCameraFovDeg(value: number, fallback = CAMERA_HORIZONTAL_FOV_DEG): number {
  return Number.isFinite(value) && value > 0 && value < 180 ? value : fallback;
}

export function center(det: Detection): [number, number] {
  return [(det.x1 + det.x2) * 0.5, (det.y1 + det.y2) * 0.5];
}

export function width(det: Detection): number {
  return Math.max(0, det.x2 - det.x1);
}

export function height(det: Detection): number {
  return Math.max(0, det.y2 - det.y1);
}

function hypot(x: number, y: number): number {
  return Math.hypot(x, y);
}

export function createRetinaFaceInput(frame: ImageData): Float32Array {
  const input = new Float32Array(1 * 3 * RETINAFACE_INPUT_HEIGHT * RETINAFACE_INPUT_WIDTH);
  const plane = RETINAFACE_INPUT_HEIGHT * RETINAFACE_INPUT_WIDTH;
  const data = frame.data;
  for (let y = 0; y < RETINAFACE_INPUT_HEIGHT; y += 1) {
    const srcY = Math.min(frame.height - 1, Math.floor(((y + 0.5) * frame.height) / RETINAFACE_INPUT_HEIGHT));
    for (let x = 0; x < RETINAFACE_INPUT_WIDTH; x += 1) {
      const srcX = Math.min(frame.width - 1, Math.floor(((x + 0.5) * frame.width) / RETINAFACE_INPUT_WIDTH));
      const src = (srcY * frame.width + srcX) * 4;
      const dst = y * RETINAFACE_INPUT_WIDTH + x;
      input[dst] = data[src] - 104;
      input[plane + dst] = data[src + 1] - 117;
      input[plane * 2 + dst] = data[src + 2] - 123;
    }
  }
  return input;
}

export function createYoloInput(frame: ImageData): Float32Array {
  const input = new Float32Array(1 * 3 * YOLO_INPUT_HEIGHT * YOLO_INPUT_WIDTH);
  const plane = YOLO_INPUT_HEIGHT * YOLO_INPUT_WIDTH;
  const data = frame.data;
  for (let y = 0; y < YOLO_INPUT_HEIGHT; y += 1) {
    const srcY = Math.min(frame.height - 1, Math.floor(((y + 0.5) * frame.height) / YOLO_INPUT_HEIGHT));
    for (let x = 0; x < YOLO_INPUT_WIDTH; x += 1) {
      const srcX = Math.min(frame.width - 1, Math.floor(((x + 0.5) * frame.width) / YOLO_INPUT_WIDTH));
      const src = (srcY * frame.width + srcX) * 4;
      const dst = y * YOLO_INPUT_WIDTH + x;
      input[dst] = data[src] / 255;
      input[plane + dst] = data[src + 1] / 255;
      input[plane * 2 + dst] = data[src + 2] / 255;
    }
  }
  return input;
}

export function createLipMotionInput(frame: ImageData, mouth: Detection): Float32Array {
  const input = new Float32Array(1 * 3 * LIP_MOTION_INPUT_HEIGHT * LIP_MOTION_INPUT_WIDTH);
  const plane = LIP_MOTION_INPUT_HEIGHT * LIP_MOTION_INPUT_WIDTH;
  forEachDetectionPixel(frame, mouth, LIP_MOTION_INPUT_WIDTH, LIP_MOTION_INPUT_HEIGHT, (dst, src) => {
    input[dst] = frame.data[src] / 255;
    input[plane + dst] = frame.data[src + 1] / 255;
    input[plane * 2 + dst] = frame.data[src + 2] / 255;
  });
  return input;
}

export function parseYoloOutput(
  output: ArrayLike<number>,
  scoreThreshold: number,
  targetWidth = CAMERA_WIDTH,
  targetHeight = CAMERA_HEIGHT
): DetectionResult {
  const rowSize = 4 + YOLO_CLASS_COUNT;
  if (output.length % rowSize !== 0) {
    throw new Error(`Unexpected YOLO output length ${output.length}`);
  }
  const candidateCount = output.length / rowSize;
  const scaleX = targetWidth / YOLO_INPUT_WIDTH;
  const scaleY = targetHeight / YOLO_INPUT_HEIGHT;
  const heads: Detection[] = [];
  const eyes: Detection[] = [];
  const mouths: Detection[] = [];

  for (let index = 0; index < candidateCount; index += 1) {
    const cx = Number(output[index]);
    const cy = Number(output[candidateCount + index]);
    const boxWidth = Number(output[candidateCount * 2 + index]);
    const boxHeight = Number(output[candidateCount * 3 + index]);
    if (![cx, cy, boxWidth, boxHeight].every(Number.isFinite) || boxWidth <= 0 || boxHeight <= 0) {
      continue;
    }
    const x1 = clamp((cx - boxWidth * 0.5) * scaleX, 0, targetWidth - 1);
    const y1 = clamp((cy - boxHeight * 0.5) * scaleY, 0, targetHeight - 1);
    const x2 = clamp((cx + boxWidth * 0.5) * scaleX, 0, targetWidth - 1);
    const y2 = clamp((cy + boxHeight * 0.5) * scaleY, 0, targetHeight - 1);
    if (x2 <= x1 || y2 <= y1) {
      continue;
    }

    const headScore = Number(output[candidateCount * (4 + HEAD_CLASS_ID) + index]);
    if (Number.isFinite(headScore) && headScore >= scoreThreshold) {
      heads.push({ classId: HEAD_CLASS_ID, score: headScore, x1, y1, x2, y2 });
    }
    const eyeScore = Number(output[candidateCount * (4 + EYE_CLASS_ID) + index]);
    if (Number.isFinite(eyeScore) && eyeScore >= YOLO_EYE_SCORE_THRESHOLD) {
      eyes.push({ classId: EYE_CLASS_ID, score: eyeScore, x1, y1, x2, y2 });
    }
    const mouthScore = Number(output[candidateCount * (4 + MOUTH_CLASS_ID) + index]);
    if (Number.isFinite(mouthScore) && mouthScore >= scoreThreshold) {
      mouths.push({ classId: MOUTH_CLASS_ID, score: mouthScore, x1, y1, x2, y2 });
    }
  }

  const selectedHeads = nmsDetections(heads, YOLO_NMS_IOU_THRESHOLD);
  if (selectedHeads.length === 0) {
    return { head: null, eyes: [], mouth: null };
  }
  const head = selectedHeads[0];
  return {
    head,
    eyes: selectEyePair(head, nmsDetections(eyes, YOLO_NMS_IOU_THRESHOLD)),
    mouth: selectBestInHead(head, nmsDetections(mouths, YOLO_NMS_IOU_THRESHOLD))
  };
}

export function parseRetinaFaceOutput(
  output: ArrayLike<number>,
  scoreThreshold: number,
  targetWidth = CAMERA_WIDTH,
  targetHeight = CAMERA_HEIGHT
): DetectionResult {
  const rowSize = 17;
  let bestOffset = -1;
  let bestScore = -Infinity;
  for (let offset = 0; offset + rowSize <= output.length; offset += rowSize) {
    const score = Number(output[offset + 2]);
    if (score >= scoreThreshold && score > bestScore) {
      bestScore = score;
      bestOffset = offset;
    }
  }
  if (bestOffset < 0) {
    return { head: null, eyes: [], mouth: null };
  }

  const x1 = scaleRetinaFaceX(Number(output[bestOffset + 3]), targetWidth);
  const y1 = scaleRetinaFaceY(Number(output[bestOffset + 4]), targetHeight);
  const x2 = scaleRetinaFaceX(Number(output[bestOffset + 5]), targetWidth);
  const y2 = scaleRetinaFaceY(Number(output[bestOffset + 6]), targetHeight);
  if (x2 <= x1 || y2 <= y1) {
    return { head: null, eyes: [], mouth: null };
  }
  const head: Detection = { classId: HEAD_CLASS_ID, score: bestScore, x1, y1, x2, y2 };
  const rightEye: [number, number] = [
    scaleRetinaFaceX(Number(output[bestOffset + 7]), targetWidth),
    scaleRetinaFaceY(Number(output[bestOffset + 8]), targetHeight)
  ];
  const leftEye: [number, number] = [
    scaleRetinaFaceX(Number(output[bestOffset + 9]), targetWidth),
    scaleRetinaFaceY(Number(output[bestOffset + 10]), targetHeight)
  ];
  const eyeBoxSize = Math.max(10, width(head) * 0.08);
  const eyes = [eyeDetection(leftEye, eyeBoxSize, bestScore), eyeDetection(rightEye, eyeBoxSize, bestScore)].sort(
    (a, b) => center(a)[0] - center(b)[0]
  );
  const nose: [number, number] = [
    scaleRetinaFaceX(Number(output[bestOffset + 11]), targetWidth),
    scaleRetinaFaceY(Number(output[bestOffset + 12]), targetHeight)
  ];
  const mouthCenter: [number, number] = [
    scaleRetinaFaceX((Number(output[bestOffset + 13]) + Number(output[bestOffset + 15])) * 0.5, targetWidth),
    scaleRetinaFaceY((Number(output[bestOffset + 14]) + Number(output[bestOffset + 16])) * 0.5, targetHeight)
  ];
  return {
    head,
    eyes,
    mouth: null,
    nose: isFinitePoint(nose) ? nose : undefined,
    mouthCenter: isFinitePoint(mouthCenter) ? mouthCenter : undefined
  };
}

function scaleRetinaFaceX(value: number, targetWidth: number): number {
  return clamp((value * targetWidth) / RETINAFACE_INPUT_WIDTH, 0, targetWidth - 1);
}

function scaleRetinaFaceY(value: number, targetHeight: number): number {
  return clamp((value * targetHeight) / RETINAFACE_INPUT_HEIGHT, 0, targetHeight - 1);
}

function isFinitePoint(point: [number, number]): boolean {
  return Number.isFinite(point[0]) && Number.isFinite(point[1]);
}

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

function detectionIou(a: Detection, b: Detection): number {
  const ix1 = Math.max(a.x1, b.x1);
  const iy1 = Math.max(a.y1, b.y1);
  const ix2 = Math.min(a.x2, b.x2);
  const iy2 = Math.min(a.y2, b.y2);
  const intersection = Math.max(0, ix2 - ix1) * Math.max(0, iy2 - iy1);
  const union = width(a) * height(a) + width(b) * height(b) - intersection;
  return union > 0 ? intersection / union : 0;
}

function nmsDetections(detections: Detection[], iouThreshold: number): Detection[] {
  const remaining = [...detections].sort((a, b) => b.score - a.score);
  const selected: Detection[] = [];
  while (remaining.length > 0) {
    const current = remaining.shift() as Detection;
    selected.push(current);
    for (let index = remaining.length - 1; index >= 0; index -= 1) {
      if (detectionIou(current, remaining[index]) > iouThreshold) {
        remaining.splice(index, 1);
      }
    }
  }
  return selected;
}

function selectEyePair(head: Detection, eyes: Detection[]): Detection[] {
  const marginX = width(head) * 0.2;
  const marginY = height(head) * 0.2;
  const candidates = eyes
    .filter((eye) => {
      const [cx, cy] = center(eye);
      return cx >= head.x1 - marginX && cx <= head.x2 + marginX && cy >= head.y1 - marginY && cy <= head.y2 + marginY;
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, 6);
  if (candidates.length <= 2) {
    return candidates.sort((a, b) => center(a)[0] - center(b)[0]);
  }
  let bestPair: [Detection, Detection] = [candidates[0], candidates[1]];
  let bestScore = -Infinity;
  for (let i = 0; i < candidates.length; i += 1) {
    for (let j = i + 1; j < candidates.length; j += 1) {
      const score = Math.abs(center(candidates[i])[0] - center(candidates[j])[0]) * (candidates[i].score + candidates[j].score);
      if (score > bestScore) {
        bestScore = score;
        bestPair = [candidates[i], candidates[j]];
      }
    }
  }
  return bestPair.sort((a, b) => center(a)[0] - center(b)[0]);
}

function selectBestInHead(head: Detection, detections: Detection[]): Detection | null {
  const marginX = width(head) * 0.2;
  const marginY = height(head) * 0.2;
  const candidates = detections.filter((detection) => {
    const [cx, cy] = center(detection);
    return cx >= head.x1 - marginX && cx <= head.x2 + marginX && cy >= head.y1 - marginY && cy <= head.y2 + marginY;
  });
  if (candidates.length === 0) {
    return null;
  }
  return candidates.reduce((best, candidate) => (candidate.score > best.score ? candidate : best), candidates[0]);
}

function forEachDetectionPixel(
  frame: ImageData,
  detection: Detection,
  targetWidth: number,
  targetHeight: number,
  callback: (dstPixel: number, srcOffset: number) => void
): void {
  const crop = lipMotionCropDetection(frame, detection);
  const x1 = crop.x1;
  const y1 = crop.y1;
  const x2 = crop.x2;
  const y2 = crop.y2;
  const cropWidth = x2 - x1;
  const cropHeight = y2 - y1;
  for (let y = 0; y < targetHeight; y += 1) {
    const srcY = Math.min(y2 - 1, y1 + Math.floor(((y + 0.5) * cropHeight) / targetHeight));
    for (let x = 0; x < targetWidth; x += 1) {
      const srcX = Math.min(x2 - 1, x1 + Math.floor(((x + 0.5) * cropWidth) / targetWidth));
      callback(y * targetWidth + x, (srcY * frame.width + srcX) * 4);
    }
  }
}

function lipMotionCropDetection(frame: { width: number; height: number }, detection: Detection): Detection {
  const x1 = clamp(Math.floor(detection.x1) - LIP_MOTION_MARGIN_LEFT, 0, frame.width - 1);
  const y1 = clamp(Math.floor(detection.y1) - LIP_MOTION_MARGIN_TOP, 0, frame.height - 1);
  const x2 = Math.max(x1 + 1, clamp(Math.ceil(detection.x2) + LIP_MOTION_MARGIN_RIGHT, 1, frame.width));
  const y2 = Math.max(y1 + 1, clamp(Math.ceil(detection.y2) + LIP_MOTION_MARGIN_BOTTOM, 1, frame.height));
  return { ...detection, x1, y1, x2, y2 };
}

function eyeDetection(point: [number, number], size: number, score: number): Detection {
  const half = size * 0.5;
  return {
    classId: EYE_CLASS_ID,
    score,
    x1: point[0] - half,
    y1: point[1] - half,
    x2: point[0] + half,
    y2: point[1] + half
  };
}

export interface GazeCrop {
  input: Float32Array;
  inverseScale: number;
  inverseTx: number;
  inverseTy: number;
}

export function createGazeInput(frame: ImageData, head: Detection, eyes: Detection[]): GazeCrop {
  if (eyes.length < 2) {
    throw new Error("Two eye detections are required");
  }
  const left = center(eyes[0]);
  const right = center(eyes[1]);
  const eyeCenter: [number, number] = [(left[0] + right[0]) * 0.5, (left[1] + right[1]) * 0.5];
  const eyeDistance = hypot(right[0] - left[0], right[1] - left[1]);
  const cropSize = Math.max(width(head) / 1.5, eyeDistance) * 1.5;
  const scale = GAZE_INPUT_SIZE / Math.max(1, cropSize);
  const inverseScale = 1 / scale;
  const inverseTx = eyeCenter[0] - GAZE_INPUT_SIZE * 0.5 * inverseScale;
  const inverseTy = eyeCenter[1] - GAZE_INPUT_SIZE * 0.5 * inverseScale;
  const input = new Float32Array(1 * 3 * GAZE_INPUT_SIZE * GAZE_INPUT_SIZE);
  const plane = GAZE_INPUT_SIZE * GAZE_INPUT_SIZE;
  const data = frame.data;
  const frameWidth = frame.width;
  const maxX = frameWidth - 1;
  const maxY = frame.height - 1;
  for (let y = 0; y < GAZE_INPUT_SIZE; y += 1) {
    const srcY = y * inverseScale + inverseTy;
    for (let x = 0; x < GAZE_INPUT_SIZE; x += 1) {
      const srcX = x * inverseScale + inverseTx;
      const dst = y * GAZE_INPUT_SIZE + x;
      if (srcX < 0 || srcY < 0 || srcX > maxX || srcY > maxY) {
        // Out-of-frame texels keep the old [0,0,0] neutral: 0/127.5-1 = -1.
        input[dst] = -1;
        input[plane + dst] = -1;
        input[plane * 2 + dst] = -1;
        continue;
      }
      const x0 = Math.floor(srcX);
      const y0 = Math.floor(srcY);
      const x1 = Math.min(maxX, x0 + 1);
      const y1 = Math.min(maxY, y0 + 1);
      const wx = srcX - x0;
      const wy = srcY - y0;
      const i00 = (y0 * frameWidth + x0) * 4;
      const i10 = (y0 * frameWidth + x1) * 4;
      const i01 = (y1 * frameWidth + x0) * 4;
      const i11 = (y1 * frameWidth + x1) * 4;
      input[dst] = bilinearChannel(data, i00, i10, i01, i11, wx, wy, 0) / 127.5 - 1;
      input[plane + dst] = bilinearChannel(data, i00, i10, i01, i11, wx, wy, 1) / 127.5 - 1;
      input[plane * 2 + dst] = bilinearChannel(data, i00, i10, i01, i11, wx, wy, 2) / 127.5 - 1;
    }
  }
  return { input, inverseScale, inverseTx, inverseTy };
}

// Scalar bilinear read of one RGB channel. The old path allocated ~5 arrays
// per pixel ([r,g,b] + four pixel() tuples + the map() result); at the
// 160²/448² targets that was ~2.4M allocs/s of pure GC churn. This keeps the
// SAME arithmetic — per-channel top/bottom lerp in the original operand
// order — so tensor output is bit-identical with zero allocations. Callers
// bounds-check first; the tap only ever sees in-frame corner indices.
function bilinearChannel(
  data: Uint8ClampedArray,
  i00: number,
  i10: number,
  i01: number,
  i11: number,
  wx: number,
  wy: number,
  channel: number
): number {
  const top = data[i00 + channel] * (1 - wx) + data[i10 + channel] * wx;
  const bottom = data[i01 + channel] * (1 - wx) + data[i11 + channel] * wx;
  return top * (1 - wy) + bottom * wy;
}

// ---------------------------------------------------------------------------
// Appearance-model ensemble (Phase 4). A MobileOne-S0 gaze net (L2CS-family,
// ~5MB) predicts yaw/pitch as 90-bin softmax logits over a 448² face crop.
// It runs async at a low cadence as a *second signal* — the feature map learns
// when to trust it vs. the geometric mesh channels, which is what rescues
// bottom-gaze regions where lid occlusion saturates the pitch channel.
// ---------------------------------------------------------------------------

export const APPEARANCE_INPUT_SIZE = 448;
export const APPEARANCE_PERIOD_MS = 220;
export const APPEARANCE_STALE_MS = 700;

export interface AppearanceAngles {
  yawDeg: number;
  pitchDeg: number;
  // Softmax peak of the sharper of the two distributions — a cheap proxy for
  // how decisive the model was on this frame (unimodal ≈ high, flat ≈ low).
  confidence: number;
}

// L2CS decode: softmax expectation over 90 bins spanning [-180°, +180°].
export function decodeBinnedAngle(logits: Float32Array | ArrayLike<number>): { deg: number; peak: number } {
  let maxLogit = -Infinity;
  for (let i = 0; i < logits.length; i += 1) {
    const v = Number(logits[i]);
    // NaN compares false, so it can't become the max — but an all-NaN or
    // empty tensor leaves -Infinity here and must bail before exp() runs.
    if (v > maxLogit) maxLogit = v;
  }
  if (logits.length === 0 || !Number.isFinite(maxLogit)) {
    return { deg: 0, peak: 0 };
  }
  let sum = 0;
  let expectation = 0;
  let peak = 0;
  for (let i = 0; i < logits.length; i += 1) {
    const v = Number(logits[i]);
    const p = Number.isFinite(v) ? Math.exp(v - maxLogit) : 0;
    sum += p;
    expectation += p * i;
    if (p > peak) peak = p;
  }
  const deg = (expectation / sum) * (360 / logits.length) - 180;
  const confidence = peak / sum;
  if (!Number.isFinite(sum) || sum <= 0 || !Number.isFinite(deg) || !Number.isFinite(confidence)) {
    return { deg: 0, peak: 0 };
  }
  return { deg, peak: confidence };
}

// ImageNet normalization — matches the MobileOne/L2CS training pipeline.
const APPEARANCE_MEAN: [number, number, number] = [0.485, 0.456, 0.406];
const APPEARANCE_STD: [number, number, number] = [0.229, 0.224, 0.225];

// Square crop around the head box padded to ~1.5× — the model wants the whole
// face plus context, not a tight bbox.
export function createAppearanceInput(frame: ImageData, head: Detection): Float32Array {
  const headCx = (head.x1 + head.x2) * 0.5;
  const headCy = (head.y1 + head.y2) * 0.5;
  const side = Math.max(width(head), head.y2 - head.y1) * 1.5;
  const scale = APPEARANCE_INPUT_SIZE / Math.max(1, side);
  const inverseScale = 1 / scale;
  const inverseTx = headCx - APPEARANCE_INPUT_SIZE * 0.5 * inverseScale;
  const inverseTy = headCy - APPEARANCE_INPUT_SIZE * 0.5 * inverseScale;
  const plane = APPEARANCE_INPUT_SIZE * APPEARANCE_INPUT_SIZE;
  const input = new Float32Array(3 * plane);
  const data = frame.data;
  const frameWidth = frame.width;
  const maxX = frameWidth - 1;
  const maxY = frame.height - 1;
  for (let y = 0; y < APPEARANCE_INPUT_SIZE; y += 1) {
    const srcY = y * inverseScale + inverseTy;
    for (let x = 0; x < APPEARANCE_INPUT_SIZE; x += 1) {
      const srcX = x * inverseScale + inverseTx;
      const dst = y * APPEARANCE_INPUT_SIZE + x;
      if (srcX < 0 || srcY < 0 || srcX > maxX || srcY > maxY) {
        // Same out-of-frame neutral as the old [0,0,0] path: (0/255-m)/s.
        input[dst] = -APPEARANCE_MEAN[0] / APPEARANCE_STD[0];
        input[plane + dst] = -APPEARANCE_MEAN[1] / APPEARANCE_STD[1];
        input[plane * 2 + dst] = -APPEARANCE_MEAN[2] / APPEARANCE_STD[2];
        continue;
      }
      const x0 = Math.floor(srcX);
      const y0 = Math.floor(srcY);
      const x1 = Math.min(maxX, x0 + 1);
      const y1 = Math.min(maxY, y0 + 1);
      const wx = srcX - x0;
      const wy = srcY - y0;
      const i00 = (y0 * frameWidth + x0) * 4;
      const i10 = (y0 * frameWidth + x1) * 4;
      const i01 = (y1 * frameWidth + x0) * 4;
      const i11 = (y1 * frameWidth + x1) * 4;
      input[dst] = (bilinearChannel(data, i00, i10, i01, i11, wx, wy, 0) / 255 - APPEARANCE_MEAN[0]) / APPEARANCE_STD[0];
      input[plane + dst] = (bilinearChannel(data, i00, i10, i01, i11, wx, wy, 1) / 255 - APPEARANCE_MEAN[1]) / APPEARANCE_STD[1];
      input[plane * 2 + dst] = (bilinearChannel(data, i00, i10, i01, i11, wx, wy, 2) / 255 - APPEARANCE_MEAN[2]) / APPEARANCE_STD[2];
    }
  }
  return input;
}

// Rate-limits the (relatively expensive) appearance pass and EMA-smooths its
// output so the feature vector sees a stable signal instead of per-run jitter.
// Inference is fired without awaiting — on a threaded ORT wasm build the
// compute happens on ORT's own workers and the frame loop stays responsive.
export class AppearanceChannel {
  private pending = false;
  private pendingSince = -Infinity;
  private lastRunAt = -Infinity;
  private lastDurationMs = 0;
  private smoothed: (AppearanceAngles & { at: number }) | null = null;
  private failures = 0;

  constructor(
    private readonly periodMs: number = APPEARANCE_PERIOD_MS,
    private readonly ema: number = 0.45,
    private readonly staleMs: number = APPEARANCE_STALE_MS,
    private readonly clock: () => number = () => performance.now()
  ) {}

  get disabled(): boolean {
    return this.failures >= 3;
  }

  maybeRun(now: number, estimate: () => Promise<AppearanceAngles>): void {
    // Adaptive duty cycle: the effective period is max(periodMs, 4× last
    // inference duration) so the model can never exceed ~25% of wall time —
    // on a single-threaded ORT build (no crossOriginIsolation, e.g. packaged
    // file:// loads) a ~90ms call backs off to ~3fps instead of hitching.
    const effectivePeriod = Math.max(this.periodMs, this.lastDurationMs * 4);
    if (this.pending) {
      // A promise that never settles (hung wasm session) would wedge the
      // channel forever — clear the lock once it's older than any plausible
      // inference. The late resolve still lands harmlessly.
      if (now - this.pendingSince > APPEARANCE_PENDING_STALE_MS) {
        this.pending = false;
      } else {
        return;
      }
    }
    if (this.disabled || now - this.lastRunAt < effectivePeriod) {
      return;
    }
    this.pending = true;
    this.pendingSince = now;
    this.lastRunAt = now;
    const runStart = this.clock();
    let result: Promise<AppearanceAngles>;
    try {
      result = estimate();
    } catch {
      // A synchronous throw never reaches .finally — clear pending here or
      // the channel stays wedged.
      this.pending = false;
      this.failures += 1;
      return;
    }
    result
      .then((angles) => {
        this.lastDurationMs = this.clock() - runStart;
        // Reject non-finite output rather than poisoning the EMA — one NaN
        // frame would otherwise stick in `smoothed` permanently.
        if (angles === null || ![angles.yawDeg, angles.pitchDeg, angles.confidence].every(Number.isFinite)) {
          this.failures += 1;
          return;
        }
        const prev = this.smoothed;
        this.smoothed = prev
          ? {
              yawDeg: prev.yawDeg + (angles.yawDeg - prev.yawDeg) * this.ema,
              pitchDeg: prev.pitchDeg + (angles.pitchDeg - prev.pitchDeg) * this.ema,
              confidence: prev.confidence + (angles.confidence - prev.confidence) * this.ema,
              at: now
            }
          : { ...angles, at: now };
      })
      .catch(() => {
        this.failures += 1;
      })
      .finally(() => {
        this.pending = false;
      });
  }

  latest(now: number): AppearanceAngles | null {
    const s = this.smoothed;
    return s !== null && now - s.at <= this.staleMs ? s : null;
  }

  reset(): void {
    this.smoothed = null;
    this.pending = false;
    this.pendingSince = -Infinity;
    this.lastRunAt = -Infinity;
    // A restarted channel must not stay disabled or keep the old duty cycle.
    this.lastDurationMs = 0;
    this.failures = 0;
  }
}

// Pending-run staleness bound — far beyond any real inference (~100ms).
const APPEARANCE_PENDING_STALE_MS = 2000;

export function estimateGazeFromModelOutput(output: ArrayLike<number>, crop: GazeCrop): GazeEstimate {
  if (output.length < 962 * 3) {
    throw new Error(`Unexpected gaze output length: ${output.length}`);
  }
  const points = new Float32Array(962 * 3);
  for (let i = 0; i < 962; i += 1) {
    const src = i * 3;
    const x = Number(output[src]) * crop.inverseScale + crop.inverseTx;
    const y = Number(output[src + 1]) * crop.inverseScale + crop.inverseTy;
    const z = Number(output[src + 2]) * crop.inverseScale;
    points[src] = y;
    points[src + 1] = x;
    points[src + 2] = z;
  }
  const leftMetrics = eyeIrisMetrics(points, 0);
  const rightMetrics = eyeIrisMetrics(points, 481);
  // The iris-to-ball-centre vector must span roughly the eyeball radius —
  // ~2.7x the iris diameter for this mesh. When the model's depth channel
  // collapses (observed under ordinary pose/lighting shifts), the measured
  // norm shrinks ~10x; those frames reconstruct depth from the learned radius.
  const [thetaXL, thetaYL, , leftHealthy, leftBall] = anglesAndVecFromEye(points, 0, leftMetrics.diameterPx);
  const [thetaXR, thetaYR, , rightHealthy, rightBall] = anglesAndVecFromEye(points, 481, rightMetrics.diameterPx);
  const leftYawDeg = (thetaYL * 180) / Math.PI;
  const leftPitchDeg = (-thetaXL * 180) / Math.PI;
  const rightYawDeg = (thetaYR * 180) / Math.PI;
  const rightPitchDeg = (-thetaXR * 180) / Math.PI;
  const depthHealthy = leftHealthy && rightHealthy;
  // Binocular fusion — Tobii's rule: a degraded eye must not drag down a
  // healthy one. Divergent eyes are physiologically impossible, so when one
  // side's depth channel collapsed (reconstructed radius = low fidelity),
  // trust the healthy eye alone rather than averaging in its garbage.
  const fuse = (l: number, r: number): number =>
    leftHealthy && rightHealthy ? (l + r) * 0.5 : leftHealthy ? l : rightHealthy ? r : (l + r) * 0.5;
  const diameters = [leftMetrics.diameterPx, rightMetrics.diameterPx].filter(Number.isFinite);
  const disagreement = Math.max(Math.abs(leftYawDeg - rightYawDeg), Math.abs(leftPitchDeg - rightPitchDeg));
  const leftMesh = eyeMeshBounds(points, 0);
  const rightMesh = eyeMeshBounds(points, 481);
  const leftIrisC = contourCenter(leftMetrics.contour);
  const rightIrisC = contourCenter(rightMetrics.contour);
  const meshOffset = (iris: [number, number] | undefined, mesh: { cx: number; cy: number; width: number; height: number }): [number, number] =>
    iris
      ? [(iris[0] - mesh.cx) / (mesh.width * 0.5), (iris[1] - mesh.cy) / (Math.max(mesh.height, 1e-6) * 0.5)]
      : [0, 0];
  return {
    yawDeg: fuse(leftYawDeg, rightYawDeg),
    pitchDeg: fuse(leftPitchDeg, rightPitchDeg),
    leftYawDeg,
    leftPitchDeg,
    rightYawDeg,
    rightPitchDeg,
    irisDiameterPx: diameters.length ? diameters.reduce((a, b) => a + b, 0) / diameters.length : 0,
    eyeOpen: clamp01(Math.min(leftMetrics.openRatio, rightMetrics.openRatio)),
    agreement: clamp01(1 - disagreement / 30),
    leftIrisPx: leftMetrics.contour,
    rightIrisPx: rightMetrics.contour,
    leftIrisCenterPx: leftIrisC,
    rightIrisCenterPx: rightIrisC,
    leftEyeballPx: [leftBall[1], leftBall[0]],
    rightEyeballPx: [rightBall[1], rightBall[0]],
    depthHealthy,
    leftEllipseEcc: leftMetrics.openRatio,
    rightEllipseEcc: rightMetrics.openRatio,
    leftEllipseAngle: [leftMetrics.ellipseSin, leftMetrics.ellipseCos],
    rightEllipseAngle: [rightMetrics.ellipseSin, rightMetrics.ellipseCos],
    leftApertureRatio: leftMetrics.diameterPx > 1e-6 ? leftMesh.height / leftMetrics.diameterPx : 0,
    rightApertureRatio: rightMetrics.diameterPx > 1e-6 ? rightMesh.height / rightMetrics.diameterPx : 0,
    leftMeshOffset: meshOffset(leftIrisC, leftMesh),
    rightMeshOffset: meshOffset(rightIrisC, rightMesh),
    headPosePoints: headPoseSubsetPoints(points)
  };
}

function eyeIrisMetrics(points: Float32Array, pointOffset: number): { diameterPx: number; openRatio: number; ellipseSin: number; ellipseCos: number; contour: [number, number][] } {
  const iris: [number, number][] = IRIS_IDX_481.map((index) => {
    const src = (pointOffset + index) * 3;
    return [points[src], points[src + 1]];
  });
  const contour: [number, number][] = iris.map(([camY, camX]) => [camX, camY]);
  const pairs: [number, number][] = [[0, 4], [1, 5], [2, 6], [3, 7]];
  const diameterPx =
    pairs.reduce((sum, [a, b]) => sum + Math.hypot(iris[a][0] - iris[b][0], iris[a][1] - iris[b][1]), 0) / pairs.length;
  const meanX = iris.reduce((sum, p) => sum + p[0], 0) / iris.length;
  const meanY = iris.reduce((sum, p) => sum + p[1], 0) / iris.length;
  let varX = 0;
  let varY = 0;
  let covXY = 0;
  for (const [x, y] of iris) {
    const dx = x - meanX;
    const dy = y - meanY;
    varX += dx * dx;
    varY += dy * dy;
    covXY += dx * dy;
  }
  const divisor = Math.max(1, iris.length - 1);
  varX /= divisor;
  varY /= divisor;
  covXY /= divisor;
  const trace = varX + varY;
  const det = varX * varY - covXY * covXY;
  const disc = Math.max(0, trace * trace * 0.25 - det);
  const major = trace * 0.5 + Math.sqrt(disc);
  const minor = trace * 0.5 - Math.sqrt(disc);
  const openRatio = major > 1e-12 ? Math.sqrt(Math.max(0, minor / major)) : 0;
  // Major-axis orientation of the iris ellipse — the projected iris disc
  // foreshortens along the gaze direction, so the axis angle carries signal
  // that the diameter can't (0.5·atan2 convention: orientation is mod-π).
  const ellipseAngle = 0.5 * Math.atan2(2 * covXY, varX - varY);
  return {
    diameterPx,
    openRatio: clamp01(openRatio),
    ellipseSin: Math.sin(2 * ellipseAngle),
    ellipseCos: Math.cos(2 * ellipseAngle),
    contour
  };
}

// Bounding box of the whole per-eye mesh (lid + eyeball points) in camera
// pixels — the reference frame for detector-independent iris offsets and the
// lid-aperture ratio (mesh height / iris diameter is head-scale invariant).
function eyeMeshBounds(
  points: Float32Array,
  pointOffset: number
): { cx: number; cy: number; width: number; height: number } {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (let i = 0; i < 481; i += 1) {
    const src = (pointOffset + i) * 3;
    const x = points[src + 1];
    const y = points[src];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, width: Math.max(1e-6, maxX - minX), height: Math.max(0, maxY - minY) };
}

// Re-anchors cached detector boxes to the gaze mesh's camera-space iris
// centers. Between full detector runs the head drifts; matching each eye box
// to its nearest iris center and translating the head box by the same delta
// keeps the crop aligned without paying for detection. Returns null when the
// implied shift is too large to trust — callers should force a fresh detection.
export function reanchorDetection(
  head: Detection,
  eyes: Detection[],
  leftEyeAnchor: [number, number] | undefined,
  rightEyeAnchor: [number, number] | undefined,
  frameWidth: number,
  frameHeight: number
): { head: Detection; eyes: Detection[]; dx: number; dy: number } | null {
  if (eyes.length < 2 || leftEyeAnchor === undefined || rightEyeAnchor === undefined) {
    return null;
  }
  const irisCenters = [leftEyeAnchor, rightEyeAnchor];
  for (const iris of irisCenters) {
    if (!iris.every(Number.isFinite) || iris[0] < 0 || iris[0] > frameWidth || iris[1] < 0 || iris[1] > frameHeight) {
      return null;
    }
  }
  const used = new Set<number>();
  const centers: [number, number][] = [];
  for (const eye of eyes.slice(0, 2)) {
    const [cx, cy] = center(eye);
    let best = -1;
    let bestDistance = Infinity;
    for (let i = 0; i < 2; i += 1) {
      if (used.has(i)) {
        continue;
      }
      const distance = Math.hypot(irisCenters[i][0] - cx, irisCenters[i][1] - cy);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (best === -1 || bestDistance > 80) {
      return null;
    }
    used.add(best);
    centers.push(irisCenters[best]);
  }
  const dx = (centers[0][0] + centers[1][0]) * 0.5 - (center(eyes[0])[0] + center(eyes[1])[0]) * 0.5;
  const dy = (centers[0][1] + centers[1][1]) * 0.5 - (center(eyes[0])[1] + center(eyes[1])[1]) * 0.5;
  const shiftBox = (box: Detection, centerPoint: [number, number]): Detection => {
    const [cx, cy] = center(box);
    const offsetX = centerPoint[0] - cx;
    const offsetY = centerPoint[1] - cy;
    return { ...box, x1: box.x1 + offsetX, y1: box.y1 + offsetY, x2: box.x2 + offsetX, y2: box.y2 + offsetY };
  };
  return {
    head: { ...head, x1: head.x1 + dx, y1: head.y1 + dy, x2: head.x2 + dx, y2: head.y2 + dy },
    eyes: [shiftBox(eyes[0], centers[0]), shiftBox(eyes[1], centers[1])],
    dx,
    dy
  };
}

export function featureDistanceM(feature: GazeFeature, focalPx: number, useIris = true): number {
  if (useIris && Number.isFinite(feature.irisDiameterPx) && feature.irisDiameterPx >= 2) {
    const distance = (IRIS_DIAMETER_M * focalPx) / feature.irisDiameterPx;
    if (distance >= DISTANCE_MIN_M && distance <= DISTANCE_MAX_M) {
      return distance;
    }
  }
  const headWidth = Math.max(1, feature.headWidthPx);
  return Math.min(DISTANCE_MAX_M, Math.max(0.05, (AVERAGE_HEAD_WIDTH_M * focalPx) / headWidth));
}

function contourCenter(contour: [number, number][] | undefined): [number, number] | undefined {
  if (!contour || contour.length === 0) {
    return undefined;
  }
  let x = 0;
  let y = 0;
  for (const point of contour) {
    x += point[0];
    y += point[1];
  }
  return [x / contour.length, y / contour.length];
}

// Saccade-aware gaze angle smoothing. Mesh estimation noise is ~±2° and roughly
// white, so a per-channel median over the last `windowSize` frames followed by a
// light EMA removes most of it — and the median rejects single-/double-frame
// mesh blowups (the per-eye z-collapse reads ~2.5x over) that the EMA used to
// blend into the output. Real saccades move BOTH eyes by far more than noise in
// one frame, so a large binocular-coherent jump snaps the filter immediately
// (zero added latency); a lone-eye or opposing-eye jump is a collapse signature
// and must persist for `snapConfirmFrames` before it earns a snap.
export class GazeAngleSmoother {
  private smoothed: [number, number, number, number] | null = null;
  private window: [number, number, number, number][] = [];
  private devStreak = 0;
  private lastT = 0;

  constructor(
    readonly alpha = 0.5,
    readonly snapDeg = 12,
    readonly windowSize = 5,
    readonly snapConfirmFrames = 2,
    // Binocular coherence: the smaller eye's angular jump must be at least
    // this fraction of the larger's for a snap to fire without confirmation.
    readonly coherenceRatio = 0.35
  ) {}

  update(estimate: GazeEstimate, tMs = 0): GazeEstimate {
    const raw: [number, number, number, number] = [
      estimate.leftYawDeg,
      estimate.leftPitchDeg,
      estimate.rightYawDeg,
      estimate.rightPitchDeg
    ];
    if (!raw.every(Number.isFinite)) {
      // A NaN frame must not poison the window/EMA — emit the last good
      // angles and store nothing. (Before any good frame exists, pass the
      // input through: the smoothed state stays clean either way.)
      return this.smoothed === null ? estimate : this.withAngles(estimate);
    }
    this.window.push(raw);
    while (this.window.length > this.windowSize) {
      this.window.shift();
    }
    if (this.smoothed === null) {
      this.smoothed = raw;
      this.lastT = tMs;
    } else {
      const dt = this.lastT > 0 && tMs > this.lastT ? (tMs - this.lastT) / 1000 : 1 / 30;
      const alpha = 1 - Math.pow(1 - this.alpha, dt * 30);
      const dL = Math.hypot(raw[0] - this.smoothed[0], raw[1] - this.smoothed[1]);
      const dR = Math.hypot(raw[2] - this.smoothed[2], raw[3] - this.smoothed[3]);
      const maxDelta = Math.max(dL, dR);
      const minDelta = Math.min(dL, dR);
      // Binocular jump: any real gaze move (saccade or vergence) displaces
      // BOTH eyes — a lone-eye deviation is a mesh collapse, not a look.
      const coherent = minDelta >= maxDelta * this.coherenceRatio;
      let snapped = false;
      if (maxDelta > this.snapDeg) {
        this.devStreak += 1;
        if (coherent || this.devStreak >= this.snapConfirmFrames) {
          this.smoothed = raw;
          this.devStreak = 0;
          snapped = true;
          // Post-snap the window re-seeds on the landing frame so stale
          // pre-saccade samples can't drag the next median back.
          this.window.length = 0;
          this.window.push(raw);
        }
      } else {
        this.devStreak = 0;
      }
      if (!snapped) {
        // In-window median — robust to the 1-2 frame outliers a median-5
        // window isolates — then the dt-scaled EMA (the calibrated constant
        // assumes ~30fps; a slower pump would otherwise double the lag).
        const med = channelMedian(this.window);
        for (let i = 0; i < 4; i += 1) {
          this.smoothed[i] += alpha * (med[i] - this.smoothed[i]);
        }
      }
      this.lastT = tMs;
    }
    return this.withAngles(estimate);
  }

  private withAngles(estimate: GazeEstimate): GazeEstimate {
    const [leftYawDeg, leftPitchDeg, rightYawDeg, rightPitchDeg] = this.smoothed as [number, number, number, number];
    return {
      ...estimate,
      yawDeg: (leftYawDeg + rightYawDeg) * 0.5,
      pitchDeg: (leftPitchDeg + rightPitchDeg) * 0.5,
      leftYawDeg,
      leftPitchDeg,
      rightYawDeg,
      rightPitchDeg
    };
  }

  reset(): void {
    this.smoothed = null;
    this.window.length = 0;
    this.devStreak = 0;
    this.lastT = 0;
  }
}

// Per-channel median of the smoother window — a lone spike on any single
// channel can't reach the EMA (it lands outside the median rank).
function channelMedian(window: [number, number, number, number][]): [number, number, number, number] {
  const out = [0, 0, 0, 0] as [number, number, number, number];
  const mid = window.length >> 1;
  for (let i = 0; i < 4; i += 1) {
    const sorted = window.map((w) => w[i]).sort((a, b) => a - b);
    out[i] = sorted[mid];
  }
  return out;
}

// Dispersion-window gaze filter (GUIDe/I-DT pattern, Kumar & Klingner 2007;
// the conditional-smoothing behavior of Tobii's US11915521 "zero delay gaze
// filter"). Velocity-threshold classification is meaningless at 12-20fps — a
// saccade spans <=1 frame — so the state machine keys on DISPERSION instead:
// a sample inside `fixRadius` of the running fixation-cluster mean extends
// the fixation; one outside it is a saccade boundary and passes through
// unsmoothed (zero added latency). Inside a fixation the output converges on
// the cluster's recency-weighted mean — sensor noise averages out, which is
// what makes "look at a window and speak" usable at webcam accuracy. Once
// the whole window tightens under `lockSpread` the output freezes on the
// cluster mean until a real look (`anchorBreak`) releases it.
export class SaccadeAwareGazeFilter {
  private out: [number, number] | null = null;
  private window: [number, number][] = [];
  private lastAngles: [number, number] | null = null;
  private lastT = 0;
  private velocity = 0;
  private saccade = false;
  // Dwell-lock: a frozen copy of the cluster mean — during a sustained,
  // tight fixation the dot stops moving entirely until a genuine re-look.
  private anchor: [number, number] | null = null;
  // Dwell-lock kill-switch: when false the anchor never engages — and an
  // engaged one releases on the next update — while the fixation/saccade
  // filtering still applies unchanged.
  anchorEnabled = true;

  constructor(
    // ~400-500ms of samples at 12-15fps — the I-DT minimum-fixation analog.
    readonly windowSize = 6,
    // A sample within this of the cluster mean belongs to the same fixation.
    // Sized to the model's noise floor (~±0.02-0.04 norm ≈ 30-60px), well
    // below a deliberate re-look to a different UI region.
    readonly fixRadius = 0.05,
    // The whole window within this of its mean freezes the dot. Deliberately
    // near the noise floor — locking beyond it would freeze a slow scan.
    readonly lockSpread = 0.04,
    // This far from a frozen anchor = a genuine re-look; releases the lock.
    readonly anchorBreak = 0.1,
    // A single-frame angle jump this large also breaks the fixation even if
    // the screen-space move stayed inside fixRadius (a near-cluster saccade).
    readonly snapDeg = 8,
    // EMA step toward the cluster mean per in-window frame (dt-scaled).
    readonly smoothAlpha = 0.4,
    // Diagnostic-only °/s EMA — reported as filter_velocity_deg_s, no longer
    // gates state (it can't: see header comment).
    readonly velAlpha = 0.65
  ) {}

  update(x: number, y: number, tMs: number, yawDeg: number, pitchDeg: number): [number, number] {
    if (![x, y, tMs, yawDeg, pitchDeg].every(Number.isFinite)) {
      // A NaN frame would poison the cluster and every output after it —
      // hold the last good point and store nothing.
      return this.out ?? [0.5, 0.5];
    }
    if (this.out === null || this.lastAngles === null || this.lastT === 0) {
      this.out = [x, y];
      this.window.push([x, y]);
      this.lastAngles = [yawDeg, pitchDeg];
      this.lastT = tMs;
      return this.out;
    }
    const dt = Math.max((tMs - this.lastT) / 1000, 1e-3);
    const angleDelta = Math.hypot(yawDeg - this.lastAngles[0], pitchDeg - this.lastAngles[1]);
    const instantaneous = angleDelta / dt;
    const velAlpha = 1 - Math.pow(1 - this.velAlpha, dt * 30);
    this.velocity += velAlpha * (instantaneous - this.velocity);
    this.lastAngles = [yawDeg, pitchDeg];
    this.lastT = tMs;

    if (this.anchor !== null) {
      if (!this.anchorEnabled || Math.hypot(x - this.anchor[0], y - this.anchor[1]) > this.anchorBreak) {
        this.anchor = null;
      } else {
        // Keep collecting in-cluster samples so a slow drift still grows the
        // window — the frozen output just doesn't move.
        this.pushWindow([x, y]);
        this.saccade = false;
        return this.anchor;
      }
    }

    const mean = this.clusterMean();
    const boundary =
      angleDelta >= this.snapDeg ||
      mean === null ||
      Math.hypot(x - mean[0], y - mean[1]) > this.fixRadius;
    if (boundary) {
      // Saccade: pass the raw landing through with zero smoothing and start a
      // fresh cluster — the next in-radius sample settles the new fixation.
      this.window.length = 0;
      this.window.push([x, y]);
      this.anchor = null;
      this.out = [x, y];
      this.saccade = true;
      return this.out;
    }

    this.window.push([x, y]);
    while (this.window.length > this.windowSize) {
      this.window.shift();
    }
    const target = this.clusterMean() ?? ([x, y] as [number, number]);
    const alpha = 1 - Math.pow(1 - this.smoothAlpha, dt * 30);
    this.out = [this.out[0] + alpha * (target[0] - this.out[0]), this.out[1] + alpha * (target[1] - this.out[1])];
    this.saccade = this.window.length < 2;
    if (this.anchorEnabled && this.window.length >= this.windowSize && this.windowSpread(target) <= this.lockSpread) {
      this.anchor = [target[0], target[1]];
      this.out = this.anchor;
      return this.anchor;
    }
    return this.out;
  }

  private pushWindow(p: [number, number]): void {
    this.window.push(p);
    while (this.window.length > this.windowSize) {
      this.window.shift();
    }
  }

  private clusterMean(): [number, number] | null {
    if (this.window.length === 0) {
      return null;
    }
    // Linear recency weighting (GUIDe-style): the newest sample describes the
    // current fixation best, so it counts most — the mean stays glued to the
    // dwell's leading edge instead of lagging a half-window behind it.
    let mx = 0;
    let my = 0;
    let wsum = 0;
    for (let i = 0; i < this.window.length; i += 1) {
      const w = i + 1;
      mx += this.window[i][0] * w;
      my += this.window[i][1] * w;
      wsum += w;
    }
    return [mx / wsum, my / wsum];
  }

  private windowSpread(mean: [number, number]): number {
    let maxD = 0;
    for (const p of this.window) {
      maxD = Math.max(maxD, Math.hypot(p[0] - mean[0], p[1] - mean[1]));
    }
    return maxD;
  }

  get velocityDegS(): number {
    return this.velocity;
  }

  get inSaccade(): boolean {
    return this.saccade;
  }

  get dwellLocked(): boolean {
    return this.anchor !== null;
  }

  reset(): void {
    this.out = null;
    this.window.length = 0;
    this.lastAngles = null;
    this.lastT = 0;
    this.velocity = 0;
    this.saccade = false;
    this.anchor = null;
  }
}

export class OneEuroFilter {
  private x: number | null = null;
  private dx = 0;
  private t: number | null = null;

  constructor(
    readonly mincutoff = 1.0,
    readonly beta = 0.7,
    readonly dcutoff = 1.0
  ) {}

  private alpha(cutoff: number, dt: number): number {
    const tau = 1 / (2 * Math.PI * Math.max(1e-4, cutoff));
    return 1 / (1 + tau / Math.max(1e-4, dt));
  }

  filter(value: number, at: number): number {
    if (!Number.isFinite(value)) {
      return this.x === null ? value : this.x;
    }
    if (this.t === null || this.x === null) {
      this.t = at;
      this.x = value;
      return value;
    }
    const dt = Math.max(at - this.t, 1e-3);
    this.t = at;
    const derivative = (value - this.x) / dt;
    this.dx += this.alpha(this.dcutoff, dt) * (derivative - this.dx);
    const cutoff = this.mincutoff + this.beta * Math.abs(this.dx);
    this.x += this.alpha(cutoff, dt) * (value - this.x);
    return this.x;
  }
}

// The mesh's first 32 points are an unreliable eyeball-centre proxy: their z
// collapses to ~0 under ordinary pose/lighting changes (observed live), which
// pins the extracted pitch at ~-85 deg. A least-squares sphere fit over all
// 481 points tracks the true 3D ball centre on every frame.
function sphereFitCenter(points: Float32Array, pointOffset: number): [number, number, number] | null {
  let sxx = 0;
  let sxy = 0;
  let sxz = 0;
  let syy = 0;
  let syz = 0;
  let szz = 0;
  let sx = 0;
  let sy = 0;
  let sz = 0;
  let bx = 0;
  let by = 0;
  let bz = 0;
  let bb = 0;
  const n = 481;
  for (let i = 0; i < n; i += 1) {
    const src = (pointOffset + i) * 3;
    const x = points[src];
    const y = points[src + 1];
    const z = points[src + 2];
    const r2 = x * x + y * y + z * z;
    sxx += x * x;
    sxy += x * y;
    sxz += x * z;
    syy += y * y;
    syz += y * z;
    szz += z * z;
    sx += x;
    sy += y;
    sz += z;
    bx += x * r2;
    by += y * r2;
    bz += z * r2;
    bb += r2;
  }
  // Normal equations for A=[2x 2y 2z 1], b=x^2+y^2+z^2
  const ata = [
    [4 * sxx, 4 * sxy, 4 * sxz, 2 * sx],
    [4 * sxy, 4 * syy, 4 * syz, 2 * sy],
    [4 * sxz, 4 * syz, 4 * szz, 2 * sz],
    [2 * sx, 2 * sy, 2 * sz, n]
  ];
  const atb = [[2 * bx], [2 * by], [2 * bz], [bb]];
  const solved = solveLinearSystem(ata, atb);
  if (solved === null) {
    return null;
  }
  return [solved[0][0], solved[1][0], solved[2][0]];
}

// Learned |iris - ballCentre| from frames where the model's z channel is
// healthy (~2.7x iris diameter here). On collapsed frames we reconstruct the
// forward depth as -sqrt(R^2 - |d2d|^2) — the iris rides the ball surface, so
// direction is fully recoverable from the stable 2D displacement alone.
//
// The learned value is stored as a RATIO to the iris diameter, not absolute
// px: a distance or resolution change rescales both axes together, and an
// absolute px baseline would pin the gate at the old scale forever (the EMA
// only updates on healthy frames, so it can never recover).
let learnedBallVecRatio = 0;
export function resetBallVecBaseline(): void {
  learnedBallVecRatio = 0;
}

function irisCenter3D(points: Float32Array, pointOffset: number): [number, number, number] {
  const c = [0, 0, 0];
  for (const index of IRIS_IDX_481) {
    const src = (pointOffset + index) * 3;
    c[0] += points[src];
    c[1] += points[src + 1];
    c[2] += points[src + 2];
  }
  c[0] /= IRIS_IDX_481.length;
  c[1] /= IRIS_IDX_481.length;
  c[2] /= IRIS_IDX_481.length;
  return c as [number, number, number];
}

function anglesAndVecFromEye(
  points: Float32Array,
  pointOffset: number,
  irisDiameterPx: number
): [number, number, number, boolean, [number, number, number]] {
  const ball = sphereFitCenter(points, pointOffset);
  if (ball === null) {
    throw new Error("Degenerate gaze mesh (sphere fit failed)");
  }
  const iris = irisCenter3D(points, pointOffset);
  const vec = [iris[0] - ball[0], iris[1] - ball[1], iris[2] - ball[2]];
  const norm = Math.hypot(vec[0], vec[1], vec[2]);
  const d2d = Math.hypot(vec[0], vec[1]);
  // A healthy |iris-ball| runs ~2.7x the iris diameter for this mesh; the
  // depth-collapse regime drops it ~10x, and partial collapse still yields a
  // shrunken norm (~27 vs ~66 measured) that over-reads angles ~2.5x. Gate on
  // the learned radius once known; iris-diameter floor covers the seed phase.
  const safeDiameterPx = Number.isFinite(irisDiameterPx) ? irisDiameterPx : 0;
  const minHealthyNorm = Math.max(1e-6, safeDiameterPx * 0.6);
  const radiusRatio = learnedBallVecRatio > 0 ? learnedBallVecRatio : 2.7;
  const radius = Math.max(1, safeDiameterPx * radiusRatio);
  let healthy = norm >= Math.max(minHealthyNorm, radius * 0.65);
  if (healthy) {
    if (safeDiameterPx > 0) {
      const ratio = norm / safeDiameterPx;
      learnedBallVecRatio =
        learnedBallVecRatio === 0 ? ratio : learnedBallVecRatio + 0.05 * (ratio - learnedBallVecRatio);
    }
  } else {
    const dzSq = radius * radius - d2d * d2d;
    vec[2] = -Math.sqrt(Math.max(dzSq, radius * 0.0025));
    healthy = false;
  }
  const usedNorm = Math.hypot(vec[0], vec[1], vec[2]);
  if (usedNorm <= 1e-6) {
    throw new Error("Invalid gaze vector norm");
  }
  const [thetaX, thetaY] = anglesFromVec([vec[0] / usedNorm, vec[1] / usedNorm, vec[2] / usedNorm]);
  return [thetaX, thetaY, usedNorm, healthy, ball];
}

function anglesFromVec(vec: [number, number, number]): [number, number] {
  const x = -vec[2];
  const y = vec[1];
  const z = -vec[0];
  const theta = Math.atan2(y, x);
  const phi = Math.atan2(Math.sqrt(x * x + y * y), z) - Math.PI / 2;
  return [phi, theta];
}

// ---------------------------------------------------------------------------
// Metric head pose. The two per-eye mesh clusters ride rigidly on the skull,
// so a Kabsch fit of a stable vertex subset (every 8th vertex; the iris
// contour is excluded — it tracks gaze, not head) against a session reference
// recovers the real head rotation in degrees, replacing the nose/eye-line
// proxies. Angles decompose R = Rz(roll)·Ry(-yaw)·Rx(pitch) in camera coords
// (x = image right, y = image down, z = into the scene) with signs matching
// the proxies: yaw > 0 tips the nose toward image-right, pitch > 0 tips it
// down, roll > 0 lowers the image-right eye.
// ---------------------------------------------------------------------------

export interface HeadPose {
  yawDeg: number;
  pitchDeg: number;
  rollDeg: number;
}

const HEAD_POSE_SUBSET_STRIDE = 8;
const HEAD_POSE_IRIS_INDICES = new Set(IRIS_IDX_481);
const HEAD_POSE_SUBSET: number[] = [];
for (let half = 0; half < 2; half += 1) {
  const base = half * 481;
  for (let i = 0; i < 481; i += HEAD_POSE_SUBSET_STRIDE) {
    if (!HEAD_POSE_IRIS_INDICES.has(i)) {
      HEAD_POSE_SUBSET.push(base + i);
    }
  }
}
export const HEAD_POSE_SUBSET_SIZE = HEAD_POSE_SUBSET.length;

// Subset extraction — the mesh's (y, x, z) layout → camera (x, y, z) triples.
function headPoseSubsetPoints(points: Float32Array): Float32Array {
  const out = new Float32Array(HEAD_POSE_SUBSET.length * 3);
  for (let k = 0; k < HEAD_POSE_SUBSET.length; k += 1) {
    const src = HEAD_POSE_SUBSET[k] * 3;
    out[k * 3] = points[src + 1];
    out[k * 3 + 1] = points[src];
    out[k * 3 + 2] = points[src + 2];
  }
  return out;
}

// Applies the documented rotation convention R = Rz(roll)·Ry(-yaw)·Rx(pitch)
// to a k×3 point set — the inverse of what the estimator extracts, so tests
// build "known pose" meshes through exactly the semantics the fit recovers.
export function applyPoseRotation(points: Float32Array, yawDeg: number, pitchDeg: number, rollDeg: number): Float32Array {
  const yaw = (yawDeg * Math.PI) / 180;
  const pitch = (pitchDeg * Math.PI) / 180;
  const roll = (rollDeg * Math.PI) / 180;
  const cy = Math.cos(yaw);
  const sy = Math.sin(yaw);
  const cp = Math.cos(pitch);
  const sp = Math.sin(pitch);
  const cr = Math.cos(roll);
  const sr = Math.sin(roll);
  const r00 = cr * cy;
  const r01 = -cr * sy * sp - sr * cp;
  const r02 = -cr * sy * cp + sr * sp;
  const r10 = sr * cy;
  const r11 = -sr * sy * sp + cr * cp;
  const r12 = -sr * sy * cp - cr * sp;
  const r20 = sy;
  const r21 = cy * sp;
  const r22 = cy * cp;
  const out = new Float32Array(points.length);
  for (let i = 0; i + 2 < points.length; i += 3) {
    const x = points[i];
    const y = points[i + 1];
    const z = points[i + 2];
    out[i] = r00 * x + r01 * y + r02 * z;
    out[i + 1] = r10 * x + r11 * y + r12 * z;
    out[i + 2] = r20 * x + r21 * y + r22 * z;
  }
  return out;
}

interface PoseFit {
  rotation: number[][];
  refCenter: [number, number, number];
  liveCenter: [number, number, number];
}

// Rigid Kabsch alignment (Horn's quaternion form): the rotation R with
// live ≈ s·R·ref + t — scale and translation are absorbed, so the recovered
// rotation is distance- and framing-invariant. Degenerate clouds (collapsed
// depth, constant points, any non-finite coordinate) return null so callers
// fall back to the detector proxies instead of emitting NaN pose.
function fitPoseRotation(reference: Float32Array, live: Float32Array): PoseFit | null {
  if (reference.length !== live.length || live.length < 9 || live.length % 3 !== 0) {
    return null;
  }
  const n = live.length / 3;
  const refCenter: [number, number, number] = [0, 0, 0];
  const liveCenter: [number, number, number] = [0, 0, 0];
  for (let i = 0; i < live.length; i += 3) {
    refCenter[0] += reference[i];
    refCenter[1] += reference[i + 1];
    refCenter[2] += reference[i + 2];
    liveCenter[0] += live[i];
    liveCenter[1] += live[i + 1];
    liveCenter[2] += live[i + 2];
  }
  for (let axis = 0; axis < 3; axis += 1) {
    refCenter[axis] /= n;
    liveCenter[axis] /= n;
  }
  let sxx = 0;
  let sxy = 0;
  let sxz = 0;
  let syx = 0;
  let syy = 0;
  let syz = 0;
  let szx = 0;
  let szy = 0;
  let szz = 0;
  let refVar = 0;
  let liveVar = 0;
  for (let i = 0; i < live.length; i += 3) {
    const ax = reference[i] - refCenter[0];
    const ay = reference[i + 1] - refCenter[1];
    const az = reference[i + 2] - refCenter[2];
    const bx = live[i] - liveCenter[0];
    const by = live[i + 1] - liveCenter[1];
    const bz = live[i + 2] - liveCenter[2];
    if (![ax, ay, az, bx, by, bz].every(Number.isFinite)) {
      return null;
    }
    sxx += ax * bx;
    sxy += ax * by;
    sxz += ax * bz;
    syx += ay * bx;
    syy += ay * by;
    syz += ay * bz;
    szx += az * bx;
    szy += az * by;
    szz += az * bz;
    refVar += ax * ax + ay * ay + az * az;
    liveVar += bx * bx + by * by + bz * bz;
  }
  if (!Number.isFinite(refVar) || !Number.isFinite(liveVar) || refVar < 1e-6 || liveVar < 1e-6) {
    return null;
  }
  const trace = sxx + syy + szz;
  const nMat = [
    [trace, syz - szy, szx - sxz, sxy - syx],
    [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
    [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
    [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz]
  ];
  // Gershgorin shift makes the matrix PSD, so power iteration lands on the
  // TOP eigenvector — the least-squares rotation quaternion — rather than
  // whichever eigenvalue happens to be largest in magnitude.
  let shift = 0;
  for (let r = 0; r < 4; r += 1) {
    let radius = 0;
    for (let c = 0; c < 4; c += 1) {
      radius += Math.abs(nMat[r][c]);
    }
    if (radius > shift) {
      shift = radius;
    }
  }
  for (let r = 0; r < 4; r += 1) {
    nMat[r][r] += shift;
  }
  let q: [number, number, number, number] = [1, 0, 0, 0];
  for (let iter = 0; iter < 48; iter += 1) {
    const w0 = nMat[0][0] * q[0] + nMat[0][1] * q[1] + nMat[0][2] * q[2] + nMat[0][3] * q[3];
    const w1 = nMat[1][0] * q[0] + nMat[1][1] * q[1] + nMat[1][2] * q[2] + nMat[1][3] * q[3];
    const w2 = nMat[2][0] * q[0] + nMat[2][1] * q[1] + nMat[2][2] * q[2] + nMat[2][3] * q[3];
    const w3 = nMat[3][0] * q[0] + nMat[3][1] * q[1] + nMat[3][2] * q[2] + nMat[3][3] * q[3];
    const norm = Math.hypot(w0, w1, w2, w3);
    if (!Number.isFinite(norm) || norm < 1e-12) {
      return null;
    }
    q = [w0 / norm, w1 / norm, w2 / norm, w3 / norm];
  }
  const [qw, qx, qy, qz] = q;
  const rotation = [
    [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)],
    [2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)],
    [2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)]
  ];
  return { rotation, refCenter, liveCenter };
}

function headPoseFromRotation(r: number[][]): HeadPose | null {
  const yawDeg = (Math.asin(Math.max(-1, Math.min(1, r[2][0]))) * 180) / Math.PI;
  const pitchDeg = (Math.atan2(r[2][1], r[2][2]) * 180) / Math.PI;
  const rollDeg = (Math.atan2(r[1][0], r[0][0]) * 180) / Math.PI;
  if (![yawDeg, pitchDeg, rollDeg].every(Number.isFinite)) {
    return null;
  }
  return { yawDeg, pitchDeg, rollDeg };
}

// Head rotation of `live` (a headPosePoints subset) against `reference` in
// the same subset layout — the pure fit; HeadPoseBaseline owns which cloud
// serves as the reference.
export function estimateHeadPoseFromMesh(live: Float32Array, reference: Float32Array): HeadPose | null {
  const fit = fitPoseRotation(reference, live);
  if (fit === null) {
    return null;
  }
  return headPoseFromRotation(fit.rotation);
}

// Session "straight-ahead" the live mesh is compared against: the user's own
// neutral pose, not an anatomical template, so per-face geometry differences
// cancel instead of biasing the angles. The first valid mesh alone can catch
// a mid-turn or a half-settled frame — the seed is instead the per-vertex
// median of the first few NEAR-NEUTRAL meshes (a held turn outside the
// adapt band never enters the pool). After seeding, the reference EMA-adapts
// ONLY while the pose already reads near-neutral — slow posture drift
// converges into the zero, a held turn outside the band can't.
export class HeadPoseBaseline {
  private reference: Float32Array | null = null;
  private seedPool: Float32Array[] = [];

  constructor(
    private readonly adaptAlpha = 0.005,
    private readonly adaptLimitDeg = 10,
    private readonly seedCount = 5
  ) {}

  get ready(): boolean {
    return this.reference !== null;
  }

  // One headPosePoints subset per estimated frame; null on malformed or
  // degenerate input — the proxy path is the caller's fallback.
  update(live: Float32Array): HeadPose | null {
    if (live.length % 3 !== 0 || live.length < 9) {
      return null;
    }
    for (let i = 0; i < live.length; i += 1) {
      if (!Number.isFinite(live[i])) {
        return null;
      }
    }
    if (this.reference === null) {
      this.reference = live.slice();
      this.seedPool = [live.slice()];
      return { yawDeg: 0, pitchDeg: 0, rollDeg: 0 };
    }
    const fit = fitPoseRotation(this.reference, live);
    if (fit === null) {
      return null;
    }
    const pose = headPoseFromRotation(fit.rotation);
    if (pose === null) {
      return null;
    }
    if (Math.max(Math.abs(pose.yawDeg), Math.abs(pose.pitchDeg), Math.abs(pose.rollDeg)) <= this.adaptLimitDeg) {
      if (this.seedPool.length < this.seedCount) {
        // Still seeding: fold the near-neutral frame into the pool and move
        // the reference to the running per-vertex median — an unlucky first
        // mesh (mid-blink, mid-turn) is outvoted instead of owned forever.
        this.seedPool.push(live.slice());
        this.reference = medianPointCloud(this.seedPool);
      } else {
        this.adapt(fit, live);
      }
    }
    return pose;
  }

  // Blend the fit-aligned live cloud into the reference — the user's
  // habitual posture drifts slowly, so the neutral it measures against may
  // too; near-neutral-only gating keeps a held turn from dragging the zero.
  private adapt(fit: PoseFit, live: Float32Array): void {
    const reference = this.reference as Float32Array;
    const r = fit.rotation;
    const [cx, cy, cz] = fit.liveCenter;
    const [ox, oy, oz] = fit.refCenter;
    const alpha = this.adaptAlpha;
    for (let i = 0; i + 2 < reference.length; i += 3) {
      const bx = live[i] - cx;
      const by = live[i + 1] - cy;
      const bz = live[i + 2] - cz;
      const qx = r[0][0] * bx + r[1][0] * by + r[2][0] * bz + ox;
      const qy = r[0][1] * bx + r[1][1] * by + r[2][1] * bz + oy;
      const qz = r[0][2] * bx + r[1][2] * by + r[2][2] * bz + oz;
      reference[i] += alpha * (qx - reference[i]);
      reference[i + 1] += alpha * (qy - reference[i + 1]);
      reference[i + 2] += alpha * (qz - reference[i + 2]);
    }
  }

  reset(): void {
    this.reference = null;
    this.seedPool = [];
  }
}

// Per-vertex positional median over a handful of same-layout clouds — the
// median mesh is robust to one odd seed (blink warp, mid-turn frame) where
// a mean would blend it in.
function medianPointCloud(clouds: Float32Array[]): Float32Array {
  const out = new Float32Array(clouds[0].length);
  const column = new Array<number>(clouds.length);
  for (let i = 0; i < out.length; i += 1) {
    for (let k = 0; k < clouds.length; k += 1) {
      column[k] = clouds[k][i];
    }
    column.sort((a, b) => a - b);
    const mid = Math.floor(column.length / 2);
    out[i] = column.length % 2 === 1 ? column[mid] : (column[mid - 1] + column[mid]) * 0.5;
  }
  return out;
}

export class DisplayGeometry {
  constructor(
    readonly widthPx: number,
    readonly heightPx: number,
    readonly diagonalInch: number
  ) {}

  get sizeM(): [number, number] {
    const diagonalM = this.diagonalInch * 0.0254;
    const pixelDiagonal = Math.hypot(this.widthPx, this.heightPx);
    return [(diagonalM * this.widthPx) / pixelDiagonal, (diagonalM * this.heightPx) / pixelDiagonal];
  }
}

export class ScreenProjector {
  readonly cameraScreenX: number;
  readonly cameraScreenY: number;
  eyePositionWeightX: number;
  eyePositionWeightY: number;
  readonly cameraFovDeg: number;
  // Not readonly: the actual capture size is only knowable after
  // getUserMedia answers, and the default-resolution VGA fallback can land
  // below the requested size — setCameraSize reconciles dims + focal once
  // the real frame size exists.
  focalPx: number;
  focalScale = 1;
  cameraWidth: number;
  cameraHeight: number;

  constructor(
    readonly display: DisplayGeometry,
    readonly flipX = true,
    readonly flipY = true,
    cameraScreenX = 0.5,
    cameraScreenY = 0,
    eyePositionWeightX = 1,
    eyePositionWeightY = 0.25,
    cameraFovDeg = CAMERA_HORIZONTAL_FOV_DEG,
    cameraWidth = CAMERA_WIDTH,
    cameraHeight = CAMERA_HEIGHT
  ) {
    this.cameraWidth = Math.max(1, Math.trunc(cameraWidth));
    this.cameraHeight = Math.max(1, Math.trunc(cameraHeight));
    this.cameraScreenX = clamp01(cameraScreenX);
    this.cameraScreenY = clamp01(cameraScreenY);
    this.eyePositionWeightX = clamp(eyePositionWeightX, 0, 1);
    this.eyePositionWeightY = clamp(eyePositionWeightY, 0, 1);
    this.cameraFovDeg = validCameraFovDeg(cameraFovDeg);
    this.focalPx = this.cameraWidth / (2 * Math.tan((this.cameraFovDeg * Math.PI) / 180 * 0.5));
  }

  // The projector is built before the camera opens (the calibration fit
  // closure captures it), so a fallback landing at a different size must be
  // applied here — projecting eye px with a stale sensor width scales every
  // raw point by the width ratio.
  setCameraSize(widthPx: number, heightPx: number): void {
    const w = Math.max(1, Math.trunc(widthPx));
    const h = Math.max(1, Math.trunc(heightPx));
    if (w === this.cameraWidth && h === this.cameraHeight) {
      return;
    }
    this.cameraWidth = w;
    this.cameraHeight = h;
    this.focalPx = this.cameraWidth / (2 * Math.tan((this.cameraFovDeg * Math.PI) / 180 * 0.5));
    // The learned ball-vector baseline is a ratio to iris diameter — nearly
    // scale-invariant, but a new sensor size is a different imaging pipeline
    // (binning, resize kernels), so relearn rather than inherit.
    resetBallVecBaseline();
  }

  get effectiveFocalPx(): number {
    return this.focalPx * this.focalScale;
  }

  effectiveFovDeg(): number {
    return (2 * Math.atan(this.cameraWidth / (2 * this.effectiveFocalPx)) * 180) / Math.PI;
  }

  retune(focalScale: number | null, weightX: number | null, weightY: number | null): void {
    if (focalScale !== null && Number.isFinite(focalScale) && focalScale > 0) {
      this.focalScale = focalScale;
    }
    if (weightX !== null && Number.isFinite(weightX)) {
      // Bound matches the fit's candidate range — a fitted 1.3 geometry must
      // apply to the live projector exactly as it did during the fit.
      this.eyePositionWeightX = clamp(weightX, 0, EYE_WEIGHT_X_MAX);
    }
    if (weightY !== null && Number.isFinite(weightY)) {
      this.eyePositionWeightY = clamp(weightY, 0, 1);
    }
  }

  distanceFromHead(head: Detection, widthRatio = 1): number {
    const correctedWidthPx = Math.max(1, width(head) * widthRatio);
    return (AVERAGE_HEAD_WIDTH_M * this.effectiveFocalPx) / correctedWidthPx;
  }

  distanceFromIris(irisDiameterPx: number): number {
    return (IRIS_DIAMETER_M * this.effectiveFocalPx) / Math.max(1, irisDiameterPx);
  }

  projectFeatures(
    feature: GazeFeature,
    mode: GazeProjectionMode = "binocular-screen",
    weightX?: number,
    weightY?: number,
    useIris = true
  ): [number, number] {
    const distanceM = featureDistanceM(feature, this.effectiveFocalPx, useIris);
    const wx = weightX === undefined ? this.eyePositionWeightX : clamp(weightX, 0, EYE_WEIGHT_X_MAX);
    const wy = weightY === undefined ? this.eyePositionWeightY : clamp(weightY, 0, 1);
    const [displayWM, displayHM] = this.display.sizeM;
    const origin = (eyePx: [number, number]): [number, number] => [
      displayWM * this.cameraScreenX + ((eyePx[0] - this.cameraWidth * 0.5) * distanceM) / this.effectiveFocalPx * wx,
      displayHM * this.cameraScreenY + ((eyePx[1] - this.cameraHeight * 0.5) * distanceM) / this.effectiveFocalPx * wy
    ];
    const hit = (eyePx: [number, number], yawDeg: number, pitchDeg: number): [number, number] => {
      const [originX, originY] = origin(eyePx);
      let pitchYM = Math.tan((pitchDeg * Math.PI) / 180) * distanceM;
      if (this.flipY) {
        pitchYM = -pitchYM;
      }
      return [originX + Math.tan((yawDeg * Math.PI) / 180) * distanceM, originY + pitchYM];
    };
    let hitM: [number, number];
    if (mode === "legacy") {
      hitM = hit(feature.eyeCenterPx, (feature.leftYawDeg + feature.rightYawDeg) * 0.5, (feature.leftPitchDeg + feature.rightPitchDeg) * 0.5);
    } else {
      const leftHit = hit(feature.leftEyePx, feature.leftYawDeg, feature.leftPitchDeg);
      const rightHit = hit(feature.rightEyePx, feature.rightYawDeg, feature.rightPitchDeg);
      hitM = [(leftHit[0] + rightHit[0]) * 0.5, (leftHit[1] + rightHit[1]) * 0.5];
    }
    return this.normalizeHitM(hitM);
  }

  project(eyeCenterPx: [number, number], yawDeg: number, pitchDeg: number, distanceM: number): [number, number] {
    return this.normalizeHitM(this.screenHitM(eyeCenterPx, yawDeg, pitchDeg, distanceM));
  }

  projectEstimate(mode: GazeProjectionMode, eyes: Detection[], estimate: GazeEstimate, distanceM: number): ProjectionResult {
    const eyeCenter: [number, number] = [
      (center(eyes[0])[0] + center(eyes[1])[0]) * 0.5,
      (center(eyes[0])[1] + center(eyes[1])[1]) * 0.5
    ];
    const legacy = this.project(eyeCenter, estimate.yawDeg, estimate.pitchDeg, distanceM);
    if (mode === "legacy") {
      return { point: legacy };
    }
    if (mode === "binocular-screen") {
      const leftHit = this.screenHitM(center(eyes[0]), estimate.leftYawDeg, estimate.leftPitchDeg, distanceM);
      const rightHit = this.screenHitM(center(eyes[1]), estimate.rightYawDeg, estimate.rightPitchDeg, distanceM);
      const hit: [number, number] = [(leftHit[0] + rightHit[0]) * 0.5, (leftHit[1] + rightHit[1]) * 0.5];
      if (Number.isFinite(hit[0]) && Number.isFinite(hit[1])) {
        return { point: this.normalizeHitM(hit) };
      }
      return { point: legacy, fallbackReason: "binocular-screen produced a non-finite hit point" };
    }
    if (mode === "binocular-convergence") {
      const convergence = this.convergenceHitM(
        center(eyes[0]),
        estimate.leftYawDeg,
        estimate.leftPitchDeg,
        center(eyes[1]),
        estimate.rightYawDeg,
        estimate.rightPitchDeg,
        distanceM
      );
      if (typeof convergence === "string") {
        return { point: legacy, fallbackReason: convergence };
      }
      return { point: this.normalizeHitM(convergence) };
    }
    return { point: legacy, fallbackReason: `Unsupported gaze projection mode: ${mode}` };
  }

  private eyeOriginM(eyeCenterPx: [number, number], distanceM: number): [number, number] {
    const [displayWM, displayHM] = this.display.sizeM;
    const eyeXM = ((eyeCenterPx[0] - this.cameraWidth * 0.5) * distanceM) / this.effectiveFocalPx * this.eyePositionWeightX;
    const eyeYM = ((eyeCenterPx[1] - this.cameraHeight * 0.5) * distanceM) / this.effectiveFocalPx * this.eyePositionWeightY;
    return [displayWM * this.cameraScreenX + eyeXM, displayHM * this.cameraScreenY + eyeYM];
  }

  private screenHitM(eyeCenterPx: [number, number], yawDeg: number, pitchDeg: number, distanceM: number): [number, number] {
    const [eyeXM, eyeYM] = this.eyeOriginM(eyeCenterPx, distanceM);
    const hitXM = eyeXM + Math.tan((yawDeg * Math.PI) / 180) * distanceM;
    let pitchYM = Math.tan((pitchDeg * Math.PI) / 180) * distanceM;
    if (this.flipY) {
      pitchYM = -pitchYM;
    }
    return [hitXM, eyeYM + pitchYM];
  }

  private normalizeHitM(hitM: [number, number]): [number, number] {
    const [displayWM, displayHM] = this.display.sizeM;
    let xNorm = hitM[0] / displayWM;
    if (this.flipX) {
      xNorm = 1 - xNorm;
    }
    return [xNorm, hitM[1] / displayHM];
  }

  private gazeDirection(yawDeg: number, pitchDeg: number): [number, number, number] {
    let pitchTan = Math.tan((pitchDeg * Math.PI) / 180);
    if (this.flipY) {
      pitchTan = -pitchTan;
    }
    const direction: [number, number, number] = [Math.tan((yawDeg * Math.PI) / 180), pitchTan, 1];
    const norm = Math.hypot(direction[0], direction[1], direction[2]);
    if (!Number.isFinite(norm) || norm <= 1e-9) {
      throw new Error("Invalid gaze direction");
    }
    return [direction[0] / norm, direction[1] / norm, direction[2] / norm];
  }

  private convergenceHitM(
    leftCenterPx: [number, number],
    leftYawDeg: number,
    leftPitchDeg: number,
    rightCenterPx: [number, number],
    rightYawDeg: number,
    rightPitchDeg: number,
    distanceM: number
  ): [number, number] | string {
    let leftOrigin: [number, number];
    let rightOrigin: [number, number];
    let d1: [number, number, number];
    let d2: [number, number, number];
    try {
      leftOrigin = this.eyeOriginM(leftCenterPx, distanceM);
      rightOrigin = this.eyeOriginM(rightCenterPx, distanceM);
      d1 = this.gazeDirection(leftYawDeg, leftPitchDeg);
      d2 = this.gazeDirection(rightYawDeg, rightPitchDeg);
    } catch (error) {
      return error instanceof Error ? error.message : String(error);
    }
    const p1: [number, number, number] = [leftOrigin[0], leftOrigin[1], 0];
    const p2: [number, number, number] = [rightOrigin[0], rightOrigin[1], 0];
    const b = dot(d1, d2);
    const denom = 1 - b * b;
    if (denom <= 1e-6) {
      return "binocular-convergence rays are nearly parallel";
    }
    const w0: [number, number, number] = [p1[0] - p2[0], p1[1] - p2[1], p1[2] - p2[2]];
    const d = dot(d1, w0);
    const e = dot(d2, w0);
    const t = (b * e - d) / denom;
    const u = (e - b * d) / denom;
    if (t <= 0 || u <= 0) {
      return "binocular-convergence intersection is behind the eye plane";
    }
    const closestLeft: [number, number, number] = [p1[0] + t * d1[0], p1[1] + t * d1[1], p1[2] + t * d1[2]];
    const closestRight: [number, number, number] = [p2[0] + u * d2[0], p2[1] + u * d2[1], p2[2] + u * d2[2]];
    const closestDistance = Math.hypot(
      closestLeft[0] - closestRight[0],
      closestLeft[1] - closestRight[1],
      closestLeft[2] - closestRight[2]
    );
    if (closestDistance > 0.2) {
      return "binocular-convergence rays do not meet closely";
    }
    const midpoint: [number, number, number] = [
      (closestLeft[0] + closestRight[0]) * 0.5,
      (closestLeft[1] + closestRight[1]) * 0.5,
      (closestLeft[2] + closestRight[2]) * 0.5
    ];
    if (!midpoint.every(Number.isFinite)) {
      return "binocular-convergence produced a non-finite point";
    }
    if (midpoint[2] <= 0 || midpoint[2] > distanceM * 3) {
      return "binocular-convergence depth is outside the expected range";
    }
    return [midpoint[0], midpoint[1]];
  }
}

function dot(a: [number, number, number], b: [number, number, number]): number {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

export interface RbfCorrection {
  centers: [number, number][];
  weights: [number, number][];
  sigma: number;
}

// Residual-bias personalization (C4): a grid of bilinear-blended cell means
// over the map's own residual errors — the per-user spatial bias the fitted
// map leaves behind (e.g. the systematic pull one user's mesh shows at a
// screen edge). Screen-normalized space like the affine chain: drops on a
// context change, and per-cell shrinkage keeps sparse evidence from
// overcorrecting. Fitting is O(n) binning — far under the in-browser budget.
export interface ResidualBiasMap {
  grid: number;
  offsets: [number, number][];
  counts: number[];
}

const RESIDUAL_BIAS_GRID = 4;
// Cells need ~6 samples before their mean applies at full strength — a
// single stray residual can't bend a region it barely visits.
const RESIDUAL_BIAS_SHRINK = 6;
const RESIDUAL_BIAS_MAX = 0.15;

export function fitResidualBias(
  points: [number, number][],
  residuals: [number, number][],
  grid = RESIDUAL_BIAS_GRID,
  weights?: number[]
): ResidualBiasMap | null {
  if (points.length !== residuals.length || points.length < 12 || grid < 2 || (weights !== undefined && weights.length !== points.length)) {
    return null;
  }
  const cells = grid * grid;
  const sums = Array.from({ length: cells }, () => [0, 0] as [number, number]);
  const counts = new Array<number>(cells).fill(0);
  for (let i = 0; i < points.length; i += 1) {
    const [x, y] = points[i];
    const [rx, ry] = residuals[i];
    const w = weights === undefined ? 1 : weights[i];
    if (![x, y, rx, ry, w].every(Number.isFinite) || w <= 0) {
      continue;
    }
    const cx = Math.min(grid - 1, Math.max(0, Math.floor(clamp01(x) * grid)));
    const cy = Math.min(grid - 1, Math.max(0, Math.floor(clamp01(y) * grid)));
    const cell = cy * grid + cx;
    sums[cell][0] += rx * w;
    sums[cell][1] += ry * w;
    counts[cell] += w;
  }
  const offsets: [number, number][] = [];
  for (let c = 0; c < cells; c += 1) {
    const count = counts[c];
    if (count === 0) {
      offsets.push([0, 0]);
      continue;
    }
    const shrink = count / (count + RESIDUAL_BIAS_SHRINK);
    let ox = (sums[c][0] / count) * shrink;
    let oy = (sums[c][1] / count) * shrink;
    const mag = Math.hypot(ox, oy);
    if (mag > RESIDUAL_BIAS_MAX) {
      ox *= RESIDUAL_BIAS_MAX / mag;
      oy *= RESIDUAL_BIAS_MAX / mag;
    }
    offsets.push([ox, oy]);
  }
  return { grid, offsets, counts };
}

// Bilinear lookup of the residual field at a normalized-screen point — the
// correction to ADD to a map output.
export function residualBiasOffset(map: ResidualBiasMap, point: [number, number]): [number, number] {
  const grid = map.grid;
  const gx = clamp01(point[0]) * grid - 0.5;
  const gy = clamp01(point[1]) * grid - 0.5;
  const x0 = Math.min(grid - 2, Math.max(0, Math.floor(gx)));
  const y0 = Math.min(grid - 2, Math.max(0, Math.floor(gy)));
  const wx = Math.min(1, Math.max(0, gx - x0));
  const wy = Math.min(1, Math.max(0, gy - y0));
  let ox = 0;
  let oy = 0;
  for (const [cx, cy, w] of [
    [x0, y0, (1 - wx) * (1 - wy)],
    [x0 + 1, y0, wx * (1 - wy)],
    [x0, y0 + 1, (1 - wx) * wy],
    [x0 + 1, y0 + 1, wx * wy]
  ] as const) {
    const cell = map.offsets[cy * grid + cx];
    ox += w * cell[0];
    oy += w * cell[1];
  }
  return [ox, oy];
}

export type CalibrationReprojector = (feature: GazeFeature, weightX: number, weightY: number) => [number, number];

interface PendingFit {
  matrix: number[][];
  rbf: RbfCorrection | null;
  geometry: CalibrationGeometry | null;
  sourceMin: [number, number];
  sourceMax: [number, number];
  raws: [number, number][];
  error: number;
  featureMap: FeatureMap | null;
  featureRbf: RbfCorrection | null;
  useFeatureMap: boolean;
}

// The projection/display/camera context a calibration was fit under. Every
// input that changes what ScreenProjector emits — projection mode, display
// pixels + physical size, camera FOV/resolution/placement, mirroring —
// belongs here: the affine chain, source bounds and any persisted drift
// offset are only meaningful in that raw-projection space. (The feature map
// and stored feature vectors are camera-domain — no display terms — so they
// survive a context change.)
export interface CalibrationContext {
  gazeProjectionMode: string;
  displayWidth: number;
  displayHeight: number;
  displaySizeInch: number;
  cameraFov: number;
  cameraWidth: number;
  cameraHeight: number;
  cameraScreenX: number;
  cameraScreenY: number;
  flipX: boolean;
  flipY: boolean;
  // Whether the appearance channel fed feature dims 36-38/43-47 when the
  // calibration was fit — a map trained with it then run without (or vice
  // versa) sees a fixed feature-space shift the fit can't know about.
  appearanceActive?: boolean;
  // Which detector produced the calibration's feature space — jaw dims
  // (jawX/jawY) exist only under RetinaFace landmarks, and headFrame differs
  // between head-box conventions, so a detector change is a feature-space
  // semantic shift as much as a projection-space one.
  detector?: string;
}

export function calibrationContextFingerprint(context: CalibrationContext): string {
  return [
    context.gazeProjectionMode,
    context.displayWidth,
    context.displayHeight,
    context.displaySizeInch,
    context.cameraFov,
    context.cameraWidth,
    context.cameraHeight,
    context.cameraScreenX,
    context.cameraScreenY,
    context.flipX ? 1 : 0,
    context.flipY ? 1 : 0,
    context.appearanceActive ? 1 : 0,
    context.detector ?? "unknown"
  ].join("|");
}

// One implicit label from ordinary use, applied to the live calibration.
// The eyes reach a target before the hand or voice confirms it, so the label
// pairs with the feature from the kind's look-back. Returns null when no
// feature from then is buffered; otherwise whether the drift correction
// saturated and the refit (or bootstrap fit) it started, if any.
export function applyImplicitLabel(
  calibration: Calibration,
  recentFeatures: TimedFeature[],
  xNorm: number,
  yNorm: number,
  kind: ImplicitLabelKind,
  now: number,
  driftMonitor: DriftMonitor
): { driftSaturated: boolean; refit: Promise<boolean> | null } | null {
  if (recentFeatures.length < 3) {
    return null;
  }
  const spec = IMPLICIT_LABEL_KINDS[kind];
  const featureAt = now - spec.lookbackMs;
  let best: TimedFeature | null = null;
  for (const entry of recentFeatures) {
    if (best === null || Math.abs(entry.at - featureAt) < Math.abs(best.at - featureAt)) {
      best = entry;
    }
  }
  if (best === null || Math.abs(best.at - featureAt) > 400) {
    return null;
  }
  const target: [number, number] = [clamp01(xNorm), clamp01(yNorm)];
  // applyFeature falls back to the raw geometric projection with no map, so
  // the error is honest from the very first label.
  const estimate = calibration.applyFeature(best.feature);
  const offset: [number, number] = [target[0] - estimate[0], target[1] - estimate[1]];
  const distance = Math.hypot(offset[0], offset[1]);
  if (spec.mainPool) {
    calibration.recordLabelError(distance);
  }
  // No map yet: nothing can gate the label, so it only feeds the bootstrap
  // fit, which waits for spread and trims outliers itself.
  if (calibration.featureMap === null && calibration.matrix === null) {
    if (!spec.bootstrap) {
      return { driftSaturated: false, refit: null };
    }
    calibration.addImplicitSample(best.feature, target);
    return { driftSaturated: false, refit: calibration.bootstrapFit(now) };
  }
  const gate = implicitAcceptGate(calibration.learnedError?.median ?? null, calibration.learning);
  // Rejected labels this close still show the map's regional bias rather
  // than a look elsewhere; low weight keeps a stray from steering the field.
  const biasBand = Math.max(0.2, gate + 0.08);
  if (!spec.mainPool) {
    // Gaze chose this target, so its centre mostly echoes the map.
    if (spec.biasWeight > 0 && distance <= biasBand) {
      calibration.addResidualBiasEvidence(best.feature, target, spec.biasWeight);
    }
    return { driftSaturated: false, refit: null };
  }
  const agreed = distance <= gate;
  // Sustained, directionally consistent rejection means the camera or laptop
  // moved: apply the rejection vector (damped) instead of interrupting for a
  // recalibration, and escalate at 0.15 cumulative (~8 confirmations). A map
  // still learning misses for its own reasons, so it stays out.
  let driftSaturated = false;
  const correction = calibration.learning || calibration.priorActive ? null : driftMonitor.record(agreed, offset, now, target);
  if (correction !== null) {
    const applied = calibration.applyDriftCorrection(correction[0] * 0.85, correction[1] * 0.85);
    driftSaturated = Math.hypot(applied[0], applied[1]) >= 0.15;
    console.info("Drift auto-corrected", JSON.stringify({ applied, saturated: driftSaturated }));
  }
  if (!agreed) {
    if (distance <= biasBand) {
      calibration.addResidualBiasEvidence(best.feature, target, 0.3);
    }
    return { driftSaturated, refit: null };
  }
  calibration.addImplicitSample(best.feature, target);
  return { driftSaturated, refit: calibration.refitWithImplicit(now) };
}

export class Calibration {
  matrix: number[][] | null = null;
  rbf: RbfCorrection | null = null;
  geometry: CalibrationGeometry | null = null;
  sourceMin: [number, number] | null = null;
  sourceMax: [number, number] | null = null;
  featureMap: FeatureMap | null = null;
  featureRbf: RbfCorrection | null = null;
  // Per-user residual-bias field layered over the map's output — the spatial
  // bias the fitted map still misses. Raw normalized-screen space: drops on
  // a context fingerprint change like the affine chain.
  residualMap: ResidualBiasMap | null = null;
  readonly sourceMargin = 0.08;
  readonly samples: Array<[GazeFeature, [number, number]]> = [];
  readonly validation: Array<{ raw: [number, number]; target: [number, number]; error: number }> = [];
  private pending: PendingFit | null = null;
  private verifyErrors: number[] = [];
  lastVerdict: VerifyVerdict | null = null;
  readonly io: CalibrationIO;
  reprojector?: CalibrationReprojector;
  // Set by the runtime before load() — see calibrationContextFingerprint.
  // When a saved file carries a fingerprint and it differs, the raw-space
  // fit state (affine, rbf, source bounds, persisted drift offset) is stale
  // and drops on load; null keeps legacy files loading as before.
  contextFingerprint: string | null = null;

  constructor(
    readonly path: string,
    readonly emit: (payload: BackendMessage) => void,
    io?: CalibrationIO,
    reprojector?: CalibrationReprojector
  ) {
    this.io = io ?? {
      read: (filePath) => window.gazeBridge.readCalibration(filePath),
      write: (filePath, payload) => window.gazeBridge.writeCalibration(filePath, payload)
    };
    this.reprojector = reprojector;
  }

  get pendingMatrix(): number[][] | null {
    return this.pending?.matrix ?? null;
  }

  async load(): Promise<void> {
    const response = await this.io.read(this.path);
    if (!response.ok) {
      this.emit({ type: "status", level: "warning", message: `Failed to load calibration: ${response.error}` });
      return;
    }
    if (response.text === null) {
      this.emit({ type: "calibration", status: "missing", path: this.path });
      return;
    }
    try {
      const payload = JSON.parse(response.text) as CalibrationPayload;
      // A projection-context change (display size, projection mode, camera
      // placement/FOV) invalidates the raw-space fit state honestly: the
      // affine chain, source bounds and persisted drift offset were learned
      // in a different projection space. Feature-space state — feature_map,
      // feature_rbf, eye weights, the sample pool — is camera-domain and
      // carries over. Files without a fingerprint (or runtimes that don't
      // set one) keep loading as before.
      const contextMismatch =
        this.contextFingerprint !== null &&
        typeof payload.context_fingerprint === "string" &&
        payload.context_fingerprint !== this.contextFingerprint;
      if (contextMismatch) {
        this.emit({
          type: "status",
          level: "info",
          message: "Calibration context changed (display/projection/camera) — dropping stale raw-space fit and drift offset"
        });
      }
      // Appearance/detector bits live inside the fingerprint (fields 11/12)
      // but gate FEATURE space, not raw space: a feature map trained with
      // appearance channels (or RetinaFace jaw dims) that now read as zeros
      // is a fixed multi-σ bias the affine drop can't fix — the map itself
      // must go. Fingerprints written before these fields existed can't
      // prove a mismatch, so they keep loading their feature state as before.
      const savedParts = typeof payload.context_fingerprint === "string" ? payload.context_fingerprint.split("|") : [];
      const liveParts = this.contextFingerprint?.split("|") ?? [];
      // MediaPipe and the legacy ONNX pipeline describe the eye in different
      // feature spaces end to end — map, sample pool and raw fit alike. A
      // switch either way starts fresh (status "missing", so first-run
      // calibration fires) instead of refitting on foreign samples.
      const liveDetector = liveParts[12];
      const savedDetector = savedParts[12];
      if (liveDetector !== undefined && (liveDetector === "mediapipe") !== (savedDetector === "mediapipe")) {
        this.emit({
          type: "status",
          level: "info",
          message: `Calibration was fit with the ${savedDetector ?? "legacy"} detector — recalibrate for ${liveDetector}`
        });
        this.emit({ type: "calibration", status: "missing", path: this.path });
        return;
      }
      const featureContextMismatch =
        (savedParts[11] !== undefined && liveParts[11] !== undefined && savedParts[11] !== liveParts[11]) ||
        (savedParts[12] !== undefined && liveParts[12] !== undefined && savedParts[12] !== liveParts[12]);
      if (featureContextMismatch) {
        this.emit({
          type: "status",
          level: "info",
          message: "Calibration feature context changed (appearance/detector) — dropping stale feature map (pool still carries over)"
        });
      }
      // Feature-space schema gate: a payload written before the pose dims
      // moved to metric degrees carries a feature_map and sample pool that
      // are ~50× scale-shifted — same dim count, wrong semantics, so the
      // per-entry validity checks can't catch it. Raw-space state
      // (affine/rbf/geometry/output_offset) is unaffected and still loads.
      const featureSpaceCurrent = payload.feature_version === FEATURE_SCHEMA_VERSION;
      if (
        !featureSpaceCurrent &&
        (payload.feature_map != null || (Array.isArray(payload.feature_samples) && payload.feature_samples.length > 0))
      ) {
        this.emit({
          type: "status",
          level: "info",
          message: `Calibration feature space is schema v${payload.feature_version ?? 1} — dropping stale feature map and sample pool (raw fit still loads)`
        });
      }
      if (payload.raw_projection !== "unclipped-v1" && payload.raw_projection !== "unclipped-v2" && payload.raw_projection !== "featuremap-v3") {
        this.emit({ type: "status", level: "warning", message: "Old calibration uses clipped raw gaze; recalibrate before using it" });
        this.emit({ type: "calibration", status: "invalid", path: this.path });
        return;
      }
      // Each payload section loads independently — a malformed feature_map
      // must not take affine/geometry/samples down with it (and vice versa).
      const fmap = payload.feature_map;
      if (
        featureSpaceCurrent &&
        !featureContextMismatch &&
        payload.raw_projection === "featuremap-v3" &&
        fmap &&
        Array.isArray(fmap.coeffs) &&
        Array.isArray(fmap.mean) &&
        Array.isArray(fmap.scale)
      ) {
        const coeffs = fmap.coeffs.map((row) => (Array.isArray(row) ? row.map(Number) : []));
        const mean = fmap.mean.map(Number);
        const scale = fmap.scale.map(Number);
        // NaN coefficients, ragged rows, or a zero scale would emit NaN gaze
        // forever — drop JUST the map and let the affine chain carry on.
        const valid =
          coeffs.length > 0 &&
          coeffs.every((row) => row.length === 2 && row.every(Number.isFinite)) &&
          mean.length === coeffs.length &&
          mean.every(Number.isFinite) &&
          scale.length === coeffs.length &&
          scale.every((s) => Number.isFinite(s) && s !== 0);
        if (valid) {
          this.featureMap = { coeffs, mean, scale };
          const frbf = payload.feature_rbf;
          if (frbf && Array.isArray(frbf.centers) && Array.isArray(frbf.weights) && frbf.centers.length === frbf.weights.length) {
            const centers = frbf.centers.map((c) => [Number(c?.[0]), Number(c?.[1])] as [number, number]);
            const weights = frbf.weights.map((w) => [Number(w?.[0]), Number(w?.[1])] as [number, number]);
            const sigma = Number(frbf.sigma);
            if (Number.isFinite(sigma) && sigma > 0 && centers.every(isFinitePoint) && weights.every(isFinitePoint)) {
              this.featureRbf = { centers, weights, sigma };
            }
          }
        }
      }
      if (!contextMismatch && Array.isArray(payload.affine) && payload.affine.length === 3) {
        const matrix = payload.affine.map((row) => (Array.isArray(row) ? row.map(Number) : []));
        if (matrix.every((row) => row.length === 2 && row.every(Number.isFinite))) {
          this.matrix = matrix;
        }
      }
      const rbf = payload.rbf;
      if (!contextMismatch && rbf && Array.isArray(rbf.centers) && Array.isArray(rbf.weights) && rbf.centers.length === rbf.weights.length) {
        const centers = rbf.centers.map((c) => [Number(c?.[0]), Number(c?.[1])] as [number, number]);
        const weights = rbf.weights.map((w) => [Number(w?.[0]), Number(w?.[1])] as [number, number]);
        const sigma = Number(rbf.sigma);
        if (Number.isFinite(sigma) && sigma > 0 && centers.every(isFinitePoint) && weights.every(isFinitePoint)) {
          this.rbf = { centers, weights, sigma };
        }
      }
      const geometry = payload.geometry;
      if (geometry && Number.isFinite(geometry.eye_position_weight_x) && Number.isFinite(geometry.eye_position_weight_y)) {
        this.geometry = {
          eye_position_weight_x: Number(geometry.eye_position_weight_x),
          eye_position_weight_y: Number(geometry.eye_position_weight_y)
        };
      }
      const bounds = payload.source_bounds;
      if (!contextMismatch && bounds?.min?.length === 2 && bounds.max?.length === 2) {
        const min: [number, number] = [Number(bounds.min[0]), Number(bounds.min[1])];
        const max: [number, number] = [Number(bounds.max[0]), Number(bounds.max[1])];
        if (min.every(Number.isFinite) && max.every(Number.isFinite)) {
          this.sourceMin = min;
          this.sourceMax = max;
        }
      }
      const offset = payload.output_offset;
      if (!contextMismatch && Array.isArray(offset) && offset.length === 2 && offset.every(Number.isFinite)) {
        // Trust no persisted magnitude — a corrupt or hand-edited file must
        // not restore a teleport-sized offset.
        const mag = Math.hypot(offset[0], offset[1]);
        const scale = mag > DRIFT_OFFSET_BOUND ? DRIFT_OFFSET_BOUND / mag : 1;
        this.outputOffset = [offset[0] * scale, offset[1] * scale];
      }
      // Personalization is raw-screen space — it drops with the rest of the
      // raw-space state on a context change, and a malformed entry drops on
      // its own like every other section.
      if (contextMismatch) {
        this.residualMap = null;
      }
      const residual = payload.residual_map;
      if (
        !contextMismatch &&
        residual &&
        Number.isInteger(residual.grid) &&
        residual.grid >= 2 &&
        residual.grid <= 8 &&
        Array.isArray(residual.offsets) &&
        residual.offsets.length === residual.grid * residual.grid
      ) {
        const offsets = residual.offsets.map(
          (o) => [Number((o as number[] | undefined)?.[0]), Number((o as number[] | undefined)?.[1])] as [number, number]
        );
        if (offsets.every(isFinitePoint)) {
          this.residualMap = {
            grid: residual.grid,
            offsets,
            counts: Array.isArray(residual.counts) && residual.counts.length === offsets.length
              ? residual.counts.map(Number)
              : offsets.map(() => 0)
          };
        }
      }
      // Restore the learned sample pool — cumulative across sessions. One
      // malformed entry must be skipped, not abort the whole load; a fully
      // finite feature vector certifies the entry reads under the current
      // schema (any missing/non-finite dim propagates NaN into the vector).
      const saved = payload.feature_samples;
      if (featureSpaceCurrent && Array.isArray(saved)) {
        for (const entry of saved) {
          if (this.isUsableSample(entry?.feature, entry?.target)) {
            this.samples.push([entry.feature, [entry.target[0], entry.target[1]]]);
          }
        }
        if (this.samples.length > MAX_POOL_SAMPLES) {
          this.samples.splice(0, this.samples.length - MAX_POOL_SAMPLES);
        }
      }
      if (contextMismatch && this.featureMap === null && this.matrix === null) {
        // Nothing usable survived the context change — report it like any
        // other unloadable file so the UI prompts a fresh calibration.
        this.emit({ type: "calibration", status: "invalid", path: this.path });
        return;
      }
      this.emit({ type: "status", level: "info", message: `Loaded calibration: ${this.path}` });
      this.emit({
        type: "calibration",
        status: "loaded",
        path: this.path,
        verified: Array.isArray(payload.validation) && payload.validation.length > 0
      });
      if (this.geometry) {
        this.emit({ type: "calibration", status: "geometry", geometry: this.geometry });
      }
    } catch (error) {
      this.emit({ type: "status", level: "warning", message: `Failed to load calibration: ${error}` });
      this.emit({ type: "calibration", status: "invalid", path: this.path });
    }
  }

  // The contract every sample pool obeys: finite point + finite target + a
  // feature the vectorizer can read without throwing or producing NaN. One
  // bad frame must never poison a fit it can't be excluded from later.
  private isUsableSample(feature: GazeFeature | null | undefined, target: [number, number] | null | undefined): boolean {
    try {
      return (
        typeof feature === "object" &&
        feature !== null &&
        Array.isArray(feature.point) &&
        feature.point.length === 2 &&
        feature.point.every(Number.isFinite) &&
        Array.isArray(target) &&
        target.length === 2 &&
        target.every(Number.isFinite) &&
        gazeFeatureVector(feature).every(Number.isFinite)
      );
    } catch {
      return false;
    }
  }

  private map(
    raw: [number, number],
    matrix: number[][],
    rbf: RbfCorrection | null,
    sourceMin: [number, number] | null,
    sourceMax: [number, number] | null
  ): [number, number] {
    let [x, y] = raw;
    if (sourceMin && sourceMax) {
      const spanX = Math.max(sourceMax[0] - sourceMin[0], 0.05);
      const spanY = Math.max(sourceMax[1] - sourceMin[1], 0.05);
      x = clamp(x, sourceMin[0] - spanX * this.sourceMargin, sourceMax[0] + spanX * this.sourceMargin);
      y = clamp(y, sourceMin[1] - spanY * this.sourceMargin, sourceMax[1] + spanY * this.sourceMargin);
    }
    let outX = x * matrix[0][0] + y * matrix[1][0] + matrix[2][0];
    let outY = x * matrix[0][1] + y * matrix[1][1] + matrix[2][1];
    if (rbf) {
      const [offsetX, offsetY] = rbfOffset(rbf, [x, y]);
      outX += offsetX;
      outY += offsetY;
    }
    return [clamp01(outX), clamp01(outY)];
  }

  apply(raw: [number, number]): [number, number] {
    if (this.matrix === null) {
      return raw;
    }
    const [x, y] = this.map(raw, this.matrix, this.rbf, this.sourceMin, this.sourceMax);
    const [rx, ry] = this.residualAt([x, y]);
    return [clamp01(x + rx + this.outputOffset[0]), clamp01(y + ry + this.outputOffset[1])];
  }

  // Preferred runtime path: direct feature→screen regression when the fit
  // chose it (learns model bias outright), falling back to the affine chain.
  applyFeature(feature: GazeFeature): [number, number] {
    const [x, y] = this.predictFeature(feature);
    const [rx, ry] = this.residualAt([x, y]);
    return [clamp01(x + rx + this.outputOffset[0]), clamp01(y + ry + this.outputOffset[1])];
  }

  // Personalization lookup — the field only exists layered on a map; with no
  // map its coordinate frame is meaningless, so it applies to nothing. No
  // residual data means output identical to the un-personalized path.
  private residualAt(point: [number, number]): [number, number] {
    if (this.residualMap === null || (this.featureMap === null && this.matrix === null)) {
      return [0, 0];
    }
    return residualBiasOffset(this.residualMap, point);
  }

  // Map output before the drift offset and before the output clamp — the
  // quantity the offset is added to. rehealDrift measures residuals against
  // exactly this; subtracting the offset after clamping (the old order) read
  // zero error at saturated borders while the offset hid the real miss.
  private predictFeature(feature: GazeFeature): [number, number] {
    if (this.featureMap !== null) {
      const pred = applyFeatureMap(this.featureMap, feature);
      let [x, y] = pred;
      if (this.featureRbf) {
        const [ox, oy] = rbfOffset(this.featureRbf, pred);
        x += ox;
        y += oy;
      }
      return [x, y];
    }
    if (this.matrix === null) {
      return feature.point;
    }
    return this.map(feature.point, this.matrix, this.rbf, this.sourceMin, this.sourceMax);
  }

  // Drift correction from the monitor's consistent-rejection vector.
  // Each event applies at most DRIFT_MAX_STEP of screen — a nudge, never a
  // teleport: a real reposition converges over successive sustained
  // confirmations, while a bogus confirmation can't move the dot far enough
  // to read as a jump. Returns the cumulative offset so callers can flag
  // when it saturates — meaning something beyond a simple reposition is
  // wrong.
  applyDriftCorrection(dx: number, dy: number): [number, number] {
    const step = Math.hypot(dx, dy);
    if (!Number.isFinite(step) || step === 0) {
      return this.outputOffset;
    }
    if (step > DRIFT_MAX_STEP) {
      dx *= DRIFT_MAX_STEP / step;
      dy *= DRIFT_MAX_STEP / step;
    }
    this.outputOffset[0] += dx;
    this.outputOffset[1] += dy;
    const mag = Math.hypot(this.outputOffset[0], this.outputOffset[1]);
    if (mag > DRIFT_OFFSET_BOUND) {
      this.outputOffset[0] *= DRIFT_OFFSET_BOUND / mag;
      this.outputOffset[1] *= DRIFT_OFFSET_BOUND / mag;
    }
    this.evictStaleSamples();
    this.persistOffset();
    return this.outputOffset;
  }

  // A reposition invalidates stored evidence: samples captured under the old
  // geometry now misfit by ~the offset — dropping them stops the next refit
  // from compromising between two camera poses. But the pool is calibration
  // capital: keep at least the best ~40% (floor 24) so a marginal or wrong
  // correction can never gut coverage in a single event — the persisted pool
  // is written immediately after this runs.
  private evictStaleSamples(): void {
    if (this.samples.length <= 30) {
      return;
    }
    const scored = this.samples.map((pair) => ({
      pair,
      error: pointError(this.applyFeature(pair[0]), pair[1])
    }));
    scored.sort((a, b) => a.error - b.error);
    const keep = scored.filter((s) => s.error <= 0.12);
    const floor = Math.max(24, Math.ceil(this.samples.length * 0.4));
    const survivors = (keep.length >= floor ? keep : scored.slice(0, floor)).map((s) => s.pair);
    const evicted = this.samples.length - survivors.length;
    if (evicted > 0) {
      this.samples.length = 0;
      this.samples.push(...survivors);
      console.info("Drift correction evicted stale samples", JSON.stringify({ evicted, kept: survivors.length }));
    }
  }

  // Re-estimate how much correction is still needed from the freshest
  // implicit evidence — call after a refit so the offset decays to zero as
  // the map itself absorbs the new camera geometry.
  private rehealDrift(): void {
    if (this.implicitSamples.length < 8 || (this.outputOffset[0] === 0 && this.outputOffset[1] === 0)) {
      return;
    }
    const residuals = this.implicitSamples.map(([feature, target]) => {
      // Measure against what the user actually sees — the residual field's
      // contribution must not be rehealed into the drift offset a second time.
      const base = this.predictFeature(feature);
      const [rx, ry] = this.residualAt(base);
      return [target[0] - base[0] - rx, target[1] - base[1] - ry] as [number, number];
    });
    const mx = medianOf(residuals.map((r) => r[0])) ?? 0;
    const my = medianOf(residuals.map((r) => r[1])) ?? 0;
    let tx = mx;
    let ty = my;
    const targetMag = Math.hypot(tx, ty);
    if (targetMag > DRIFT_OFFSET_BOUND) {
      tx *= DRIFT_OFFSET_BOUND / targetMag;
      ty *= DRIFT_OFFSET_BOUND / targetMag;
    }
    // Move toward the residual target by at most DRIFT_REHEAL_MAX_STEP — a
    // refit that truly absorbed the move converges in a couple of rounds,
    // while a bad implicit batch can't snap the output across the screen.
    let dx = tx - this.outputOffset[0];
    let dy = ty - this.outputOffset[1];
    const delta = Math.hypot(dx, dy);
    if (delta > DRIFT_REHEAL_MAX_STEP) {
      dx *= DRIFT_REHEAL_MAX_STEP / delta;
      dy *= DRIFT_REHEAL_MAX_STEP / delta;
    }
    this.outputOffset = [this.outputOffset[0] + dx, this.outputOffset[1] + dy];
  }

  private persistOffset(): void {
    void this.io.write(this.path, this.toPayload()).catch(() => {});
  }

  private toPayload(): CalibrationPayload {
    return {
      raw_projection: this.featureMap !== null ? "featuremap-v3" : "unclipped-v2",
      affine: this.matrix ?? [],
      rbf: this.rbf,
      feature_map: this.featureMap,
      feature_rbf: this.featureRbf,
      geometry: this.geometry,
      source_bounds: this.sourceMin && this.sourceMax ? { min: this.sourceMin, max: this.sourceMax, margin: this.sourceMargin } : undefined,
      samples: this.samples.concat(this.implicitSamples).map(([feature, target]) => ({ raw: feature.point, target })),
      feature_samples: this.samples
        .concat(this.implicitSamples)
        .slice(-800)
        .map(([feature, target]) => ({ feature, target })),
      validation: this.validation.slice(),
      verify_verdict: this.lastVerdict ?? undefined,
      output_offset: this.outputOffset[0] !== 0 || this.outputOffset[1] !== 0 ? [this.outputOffset[0], this.outputOffset[1]] : undefined,
      residual_map: this.residualMap,
      context_fingerprint: this.contextFingerprint ?? undefined,
      feature_version: FEATURE_SCHEMA_VERSION
    };
  }

  // One full fit over the given pairs: affine candidates + feature-map
  // regression, LOO-chosen model, gate scored on whichever map will run.
  // Returns the fit or a rejection reason.
  private fitOnce(samplePairs: Array<[GazeFeature, [number, number]]>, minFeatureMapSamples = 9): PendingFit | string {
    const features = samplePairs.map(([feature]) => feature);
    const targets = samplePairs.map(([, target]) => target);
    const liveXs = features.map((feature) => feature.point[0]);
    const liveYs = features.map((feature) => feature.point[1]);
    if (Math.max(...liveXs) - Math.min(...liveXs) < 0.08 || Math.max(...liveYs) - Math.min(...liveYs) < 0.08) {
      return "Raw gaze does not separate calibration targets";
    }
    let best: PendingFit | null = null;
    if (this.reprojector) {
      for (const weightX of WEIGHT_X_CANDIDATES) {
        for (const weightY of WEIGHT_Y_CANDIDATES) {
          const raws = features.map((feature) => this.reprojector!(feature, weightX, weightY));
          if (!raws.every((raw) => raw.every(Number.isFinite))) {
            continue;
          }
          try {
            const matrix = solveAffine(raws.map((raw, index) => [raw, targets[index]]));
            const error = Math.max(...raws.map((raw, index) => pointError(applyMatrix(matrix, raw), targets[index])));
            if (best === null || error < best.error) {
              best = {
                matrix,
                rbf: null,
                geometry: { eye_position_weight_x: weightX, eye_position_weight_y: weightY },
                sourceMin: [Math.min(...raws.map((r) => r[0])), Math.min(...raws.map((r) => r[1]))],
                sourceMax: [Math.max(...raws.map((r) => r[0])), Math.max(...raws.map((r) => r[1]))],
                raws,
                error,
                featureMap: null,
                featureRbf: null,
                useFeatureMap: false
              };
            }
          } catch {
            continue;
          }
        }
      }
      if (best === null) {
        return "Calibration geometry fit produced no valid candidate";
      }
    } else {
      const raws = features.map((feature) => feature.point);
      try {
        const matrix = solveAffine(raws.map((raw, index) => [raw, targets[index]]));
        const error = Math.max(...raws.map((raw, index) => pointError(applyMatrix(matrix, raw), targets[index])));
        best = {
          matrix,
          rbf: null,
          geometry: null,
          sourceMin: [Math.min(...liveXs), Math.min(...liveYs)],
          sourceMax: [Math.max(...liveXs), Math.max(...liveYs)],
          raws,
          error,
          featureMap: null,
          featureRbf: null,
          useFeatureMap: false
        };
      } catch (error) {
        return error instanceof Error ? error.message : String(error);
      }
    }
    const residuals = best.raws.map((raw, index) => {
      const [px, py] = applyMatrix(best!.matrix, raw);
      return [targets[index][0] - px, targets[index][1] - py] as [number, number];
    });
    best.rbf = rbfFit(best.raws, residuals);

    // Feature-space regression vs the affine chain — pick by leave-one-out so
    // the richer model has to win honestly rather than on in-sample fit. The
    // feature map can rescue a calibration whose geometric projection is poor
    // (it learns the model's systematic bias), so score the gate on whichever
    // map will actually run. Both sides are LOO now: gating the affine on its
    // max in-sample error while the map is judged by LOO was an asymmetry —
    // the affine looked artificially bad next to its own generalization gap.
    const looAffine = looAffineError(best.raws, targets);
    let looFeature = Infinity;
    const featureMap = fitFeatureMap(features, targets);
    if (featureMap !== null && features.length >= minFeatureMapSamples) {
      looFeature = looFeatureError(features, targets);
      best.featureMap = featureMap;
      const preds = features.map((f) => applyFeatureMap(featureMap, f));
      const featResiduals = preds.map((p, i) => [targets[i][0] - p[0], targets[i][1] - p[1]] as [number, number]);
      best.featureRbf = rbfFit(preds, featResiduals);
      best.useFeatureMap = Number.isFinite(looFeature) && (!Number.isFinite(looAffine) || looFeature <= looAffine * 1.1);
      console.info(
        "Calibration map comparison",
        JSON.stringify({ affineLoo: Number(looAffine.toFixed(4)), featureLoo: Number(looFeature.toFixed(4)), useFeatureMap: best.useFeatureMap })
      );
    }
    const gateError = best.useFeatureMap ? looFeature : looAffine;
    if (!Number.isFinite(gateError) || gateError > CALIBRATION_FIT_MAX_ERROR) {
      return `Calibration fit error ${gateError.toFixed(3)} exceeds ${CALIBRATION_FIT_MAX_ERROR.toFixed(2)}`;
    }
    best.error = gateError;
    return best;
  }

  // Score a sample against a candidate fit through whichever map it selected.
  private pendingEstimate(fit: PendingFit, feature: GazeFeature): [number, number] {
    if (fit.useFeatureMap && fit.featureMap) {
      const est = applyFeatureMap(fit.featureMap, feature);
      let x = est[0];
      let y = est[1];
      if (fit.featureRbf) {
        const [ox, oy] = rbfOffset(fit.featureRbf, est);
        x += ox;
        y += oy;
      }
      return [clamp01(x), clamp01(y)];
    }
    const raw = fit.geometry && this.reprojector
      ? this.reprojector(feature, fit.geometry.eye_position_weight_x, fit.geometry.eye_position_weight_y)
      : feature.point;
    return this.map(raw, fit.matrix, fit.rbf, fit.sourceMin, fit.sourceMax);
  }

  private fit(): void {
    const first = this.fitOnce(this.samples);
    if (typeof first === "string") {
      this.rejectFit(first);
      return;
    }
    let best = first;
    // Robust refit for dense (pursuit) captures: samples the map can't explain
    // are blinks/attention lapses, not geometry — drop them once and refit.
    if (this.samples.length >= 30) {
      const residuals = this.samples.map(([feature, target]) => pointError(this.pendingEstimate(best, feature), target));
      const sorted = residuals.slice().sort((a, b) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      const threshold = Math.max(0.09, 2.5 * median);
      const kept = this.samples.filter((_, index) => residuals[index] <= threshold);
      if (kept.length >= Math.max(24, Math.floor(this.samples.length * 0.7)) && kept.length < this.samples.length) {
        const second = this.fitOnce(kept);
        if (typeof second !== "string") {
          console.info(
            "Calibration pursuit trim",
            JSON.stringify({ dropped: this.samples.length - kept.length, kept: kept.length, threshold: Number(threshold.toFixed(4)) })
          );
          this.samples.length = 0;
          this.samples.push(...kept);
          best = second;
        }
      }
    }
    this.pending = best;
    console.info("Calibration fit complete", JSON.stringify({ maxError: Number(best.error.toFixed(4)), geometry: best.geometry, samples: this.samples.length }));
  }

  // Pursuit calibration (Pfeuffer et al., UIST'13): a moving target produces a
  // dense sample stream; capture tags each accepted frame with the target's
  // current position and the fit runs once the path completes.
  beginPursuit(): void {
    this.pursuitBackup ??= {
      samples: this.samples.slice(),
      implicitSamples: this.implicitSamples.slice(),
      rejectedBiasEvidence: this.rejectedBiasEvidence.slice(),
      sameSpotRun: this.sameSpotRun
    };
    this.samples.length = 0;
    // Old-map implicit labels are biased evidence for the fit about to run —
    // a new calibration must not inherit labels learned under its predecessor.
    this.implicitSamples.length = 0;
    this.rejectedBiasEvidence.length = 0;
    this.sameSpotRun = 0;
    this.validation.length = 0;
    this.pending = null;
    // Stale verify state must not attach to the next fit's save/reject.
    this.verifyErrors.length = 0;
    this.lastVerdict = null;
  }

  capturePursuit(feature: GazeFeature, target: [number, number]): void {
    if (!this.isUsableSample(feature, target)) {
      return;
    }
    this.samples.push([feature, target]);
    // Bounded pool: oldest frames are the stalest evidence — drop them first.
    if (this.samples.length > MAX_POOL_SAMPLES) {
      this.samples.shift();
    }
  }

  finishPursuit(): void {
    if (this.samples.length < 24) {
      this.rejectFit(`Only ${this.samples.length} pursuit samples — follow the dot for the full path`);
      return;
    }
    this.fit();
  }

  // User-aborted pursuit/verify: drop the in-flight state WITHOUT emitting —
  // no fit, no verify verdict, no write. (finishPursuit/finishVerify emit a
  // status for every outcome; an abort must be silent or the renderer would
  // treat the cancel as a rejection and reopen the modal.)
  abortPursuit(): void {
    this.samples.length = 0;
    this.validation.length = 0;
    this.pending = null;
    this.verifyErrors.length = 0;
    this.lastVerdict = null;
    this.restorePursuitBackup();
  }

  // A rejected or aborted run leaves the live map in place, so it must also
  // leave the pools that map learned from — not an empty pool to relearn.
  private restorePursuitBackup(): void {
    const backup = this.pursuitBackup;
    if (backup === null) {
      return;
    }
    this.pursuitBackup = null;
    this.samples.length = 0;
    this.samples.push(...backup.samples);
    this.implicitSamples.length = 0;
    this.implicitSamples.push(...backup.implicitSamples);
    this.rejectedBiasEvidence.length = 0;
    this.rejectedBiasEvidence.push(...backup.rejectedBiasEvidence);
    this.sameSpotRun = backup.sameSpotRun;
  }

  // Verification sweep: same UX as pursuit — the user keeps following the dot
  // while the pending map's predictions are compared to the target stream.
  // A median over ~100 samples is far more robust than two discrete stares.
  get verifyCount(): number {
    return this.verifyErrors.length;
  }

  beginVerify(): void {
    this.validation.length = 0;
    this.verifyErrors.length = 0;
  }

  captureVerifyError(feature: GazeFeature, target: [number, number]): void {
    if (this.pending === null || !this.isUsableSample(feature, target)) {
      return;
    }
    const estimate = this.pendingEstimate(this.pending, feature);
    const error = pointError(estimate, target);
    if (!Number.isFinite(error)) {
      return;
    }
    this.verifyErrors.push(error);
    this.validation.push({ raw: feature.point, target, error });
  }

  async finishVerify(): Promise<void> {
    if (this.pending === null) {
      return;
    }
    // ~20 qualifying frames is ~1.5-2s of sweep — enough for a robust median;
    // the old 30 floor made a slightly-fast sweep reject a good fit.
    if (this.verifyErrors.length < 20) {
      this.rejectFit(`Only ${this.verifyErrors.length} verification samples — follow the dot through the check path`);
      return;
    }
    const sorted = this.verifyErrors.slice().sort((a, b) => a - b);
    const median = sorted[Math.floor(sorted.length / 2)];
    const p90 = sorted[Math.floor(sorted.length * 0.9)];
    this.lastVerdict = buildVerifyVerdict(this.validation);
    // Corners carry the worst systematic error in a cone-projection fit — a
    // map can look fine on median while its corners are a quarter-screen
    // off. Gate them explicitly so the dead-zone doesn't ship.
    const corner = this.lastVerdict?.regions.corner ?? 0;
    console.info(
      "Calibration verify",
      JSON.stringify({ median: Number(median.toFixed(4)), p90: Number(p90.toFixed(4)), samples: this.verifyErrors.length, regions: this.lastVerdict?.regions })
    );
    if (median > 0.08 || p90 > 0.18 || corner > 0.28) {
      this.rejectFit(
        `Verification error median=${median.toFixed(3)} p90=${p90.toFixed(3)} corner=${corner.toFixed(3)} exceeds gate`
      );
      return;
    }
    await this.commitPending();
  }

  // Implicit labels collected during normal interaction (WebGazer/COMETIC
  // style): a fixation at a known on-screen position is a free ground-truth
  // pair that lets the map keep correcting drift over time.
  readonly implicitSamples: Array<[GazeFeature, [number, number]]> = [];
  // Bundled starting samples (see seedPrior) — fit-pool filler only.
  readonly priorSamples: Array<[GazeFeature, [number, number]]> = [];
  private readonly learnedErrors: number[] = [];
  private lastImplicitRefit = 0;
  // Consecutive implicit labels resting on (nearly) the same spot — a parked
  // cursor must not flood the pool or it starves spread (see refit gate).
  private sameSpotRun = 0;
  // Rejected-but-bounded implicit labels, kept as LOW-WEIGHT residual-bias
  // evidence: a consistent 0.09-0.2 regional miss is real signal (the only
  // mechanism that repairs it without recalibration), but a label the accept
  // gate already distrusted must not join the main pool or steer it.
  // Stored as (feature, target, weight) so each residual fit re-derives the
  // error against whatever map is being scored.
  private readonly rejectedBiasEvidence: Array<[GazeFeature, [number, number], number]> = [];
  // Pools as they stood before the in-flight pursuit run; null once it commits or is undone.
  private pursuitBackup: {
    samples: Array<[GazeFeature, [number, number]]>;
    implicitSamples: Array<[GazeFeature, [number, number]]>;
    rejectedBiasEvidence: Array<[GazeFeature, [number, number], number]>;
    sameSpotRun: number;
  } | null = null;
  // Translation correction layered over the map — applied when the drift
  // monitor sees consistent rejection (camera/laptop moved). Bounded so a
  // bad estimate can't teleport the dot; decays back toward zero as the
  // implicit refit absorbs the shift into the map itself.
  private outputOffset: [number, number] = [0, 0];

  addImplicitSample(feature: GazeFeature, target: [number, number]): void {
    // A fit awaiting its verify sweep owns the pools until it commits or is
    // rejected; a background label landing now would be restored away, or
    // refit the live map on the new run's samples.
    if (this.pending !== null || !this.isUsableSample(feature, target)) {
      return;
    }
    // Same-spot dedupe: the OS emits one label per rest, and a docked cursor
    // rests at the same place for minutes — cap the run at a few samples so
    // 30 rests at one spot can't masquerade as coverage.
    const last = this.implicitSamples[this.implicitSamples.length - 1];
    if (last && Math.hypot(last[1][0] - target[0], last[1][1] - target[1]) <= 0.03) {
      this.sameSpotRun += 1;
      if (this.sameSpotRun >= 3) {
        return;
      }
    } else {
      this.sameSpotRun = 0;
    }
    this.implicitSamples.push([feature, target]);
    if (this.implicitSamples.length > 300) {
      this.implicitSamples.shift();
    }
  }

  // A rejected implicit label in the bounded 0.09-0.2 band: it stays out of
  // the main pool (the accept gate exists for a reason) but its residual is
  // evidence about the regional bias the fitted map still carries. Weight
  // ~0.3 keeps it subordinate to calibrated samples inside the bias fit.
  addResidualBiasEvidence(feature: GazeFeature, target: [number, number], weight = 0.3): void {
    if (weight <= 0 || this.pending !== null || !this.isUsableSample(feature, target)) {
      return;
    }
    this.rejectedBiasEvidence.push([feature, target, weight]);
    if (this.rejectedBiasEvidence.length > 120) {
      this.rejectedBiasEvidence.shift();
    }
  }

  async refitWithImplicit(now: number): Promise<boolean> {
    // Refit only when there's enough fresh evidence and enough time has passed;
    // adopt only if the new map scores no worse than the current one. Either
    // map kind can adapt — an affine-only calibration shouldn't freeze.
    const learning = this.learning;
    const minLabels = learning ? LEARNING_REFIT_MIN_LABELS : 30;
    const cadence = learning ? LEARNING_REFIT_INTERVAL_MS : 90_000;
    if (
      this.pending !== null ||
      (this.featureMap === null && this.matrix === null) ||
      this.implicitSamples.length < minLabels ||
      now - this.lastImplicitRefit < cadence
    ) {
      return false;
    }
    // Pool-spread gate: a cursor parked at one spot yields dozens of rests at
    // one target — the refit would only tighten a local screw, not heal the
    // map. Require the fresh evidence to actually cover some screen.
    {
      let minX = 1;
      let maxX = 0;
      let minY = 1;
      let maxY = 0;
      for (const [, target] of this.implicitSamples) {
        minX = Math.min(minX, target[0]);
        maxX = Math.max(maxX, target[0]);
        minY = Math.min(minY, target[1]);
        maxY = Math.max(maxY, target[1]);
      }
      if (Math.max(maxX - minX, maxY - minY) < 0.04) {
        this.lastImplicitRefit = now;
        return false;
      }
    }
    // Cap the fit pool — a session-aged pool made the O(nk² + k³) fit and the
    // RBF solve grow without bound. Keep the freshest evidence and fill the
    // rest by max-min target spread so coverage survives the cap.
    const merged = this.fitPool();
    const result = this.fitOnce(merged, IMPLICIT_FEATURE_MAP_MIN_SAMPLES);
    if (typeof result === "string") {
      // A failed refit already paid for the fit attempt — honor the cadence
      // anyway or every later implicit sample re-runs it.
      this.lastImplicitRefit = now;
      return false;
    }
    // Both sides are judged on the same labels, and neither was fitted to
    // them: the fresh labels the live map hasn't absorbed. The residual RBF
    // interpolates its own pool, so an in-sample comparison adopted memorising
    // maps every time (logged 0.152 → 0.016 on a map whose held-out error was
    // no better than guessing the screen centre). The candidate scores each
    // fresh label from a refit that left that label's target out.
    const oldError = medianOf(this.implicitSamples.map(([feature, target]) => pointError(this.applyFeature(feature), target))) ?? Infinity;
    const newError = this.heldOutError(merged, this.implicitSamples);
    if (!(newError < oldError)) {
      console.info("Implicit refit kept old map", JSON.stringify({ oldError: Number(oldError.toFixed(4)), heldOutError: Number(newError.toFixed(4)) }));
      this.lastImplicitRefit = now;
      return false;
    }
    this.adopt(result, merged, now, true);
    console.info("Implicit refit adopted", JSON.stringify({ oldError: Number(oldError.toFixed(4)), heldOutError: Number(newError.toFixed(4)) }));
    return true;
  }

  // Median error of the refit procedure on the scored labels (the whole
  // pool by default), each predicted by a fit that never saw it. Four folds
  // keep the cost to four fits per refit; a fold whose training share can't
  // be fitted contributes nothing, and no scored label is Infinity. Folds
  // split by target, not by index: a point run labels several frames at
  // each target, and a sibling frame left in training teaches the fit that
  // point's own miss, which made the score in-sample again. A pool entry
  // leaves training whenever its target is scored in the fold, so labels
  // already absorbed at a fresh label's target can't leak it either.
  heldOutError(
    pool: Array<[GazeFeature, [number, number]]>,
    scored: Array<[GazeFeature, [number, number]]> = pool
  ): number {
    const keyOf = ([, target]: [GazeFeature, [number, number]]) => `${target[0]},${target[1]}`;
    const groups = new Map<string, number>();
    for (const entry of scored) {
      const key = keyOf(entry);
      if (!groups.has(key)) {
        groups.set(key, groups.size);
      }
    }
    const folds = Math.min(4, groups.size);
    const errors: number[] = [];
    for (let fold = 0; fold < folds; fold += 1) {
      const inFold = (entry: [GazeFeature, [number, number]]) => (groups.get(keyOf(entry)) ?? -1) % folds === fold;
      const fit = this.fitOnce(
        pool.filter((entry) => !inFold(entry)),
        IMPLICIT_FEATURE_MAP_MIN_SAMPLES
      );
      if (typeof fit === "string") {
        continue;
      }
      for (const entry of scored) {
        if (inFold(entry)) {
          errors.push(pointError(this.pendingEstimate(fit, entry[0]), entry[1]));
        }
      }
    }
    return medianOf(errors.filter(Number.isFinite)) ?? Infinity;
  }

  // Swap a fit in as the live map: retune geometry, refit the residual field
  // over the pool, consolidate the pending labels into the durable pool and
  // optionally persist. Shared by the implicit refit, the bootstrap fit and
  // the prior seed.
  private adopt(result: PendingFit, merged: Array<[GazeFeature, [number, number]]>, now: number, persist: boolean): void {
    const previousGeometry = this.geometry;
    this.matrix = result.matrix;
    this.rbf = result.rbf;
    // When the refit prefers the affine chain the old feature map must go —
    // keeping it left applyFeature running a stale map while the adopted
    // affine sat unused underneath.
    this.featureMap = result.useFeatureMap ? result.featureMap : null;
    this.featureRbf = result.useFeatureMap ? result.featureRbf : null;
    this.geometry = result.geometry;
    // The adopted fit may carry a different eye-position geometry — emit the
    // change so the projector retunes instead of projecting in stale space.
    if (
      this.geometry !== null &&
      (previousGeometry === null ||
        previousGeometry.eye_position_weight_x !== this.geometry.eye_position_weight_x ||
        previousGeometry.eye_position_weight_y !== this.geometry.eye_position_weight_y)
    ) {
      this.emit({ type: "calibration", status: "geometry", geometry: this.geometry });
    }
    this.sourceMin = result.sourceMin;
    this.sourceMax = result.sourceMax;
    // Refit personalization against the map that now runs — same merged pool,
    // same residual measurement the commit path uses, plus the bounded
    // rejected-label evidence at its reduced weight.
    const residualPool: [number, number][] = [];
    const residualErrors: [number, number][] = [];
    const residualWeights: number[] = [];
    for (const [feature, target] of merged) {
      const est = this.pendingEstimate(result, feature);
      residualPool.push(est);
      residualErrors.push([target[0] - est[0], target[1] - est[1]]);
      residualWeights.push(1);
    }
    for (const [feature, target, weight] of this.rejectedBiasEvidence) {
      const est = this.pendingEstimate(result, feature);
      if (!est.every(Number.isFinite)) {
        continue;
      }
      residualPool.push(est);
      residualErrors.push([target[0] - est[0], target[1] - est[1]]);
      residualWeights.push(weight);
    }
    this.residualMap = fitResidualBias(residualPool, residualErrors, RESIDUAL_BIAS_GRID, residualWeights);
    this.rehealDrift();
    // Consolidate the adopted labels into the durable pool BEFORE persisting
    // — the payload concatenates both pools, so clearing first wrote a file
    // that silently forgot the labels that earned the refit. MAX_POOL bounds
    // the consolidation exactly like capturePursuit does.
    this.samples.push(...this.implicitSamples);
    if (this.samples.length > MAX_POOL_SAMPLES) {
      this.samples.splice(0, this.samples.length - MAX_POOL_SAMPLES);
    }
    this.implicitSamples.length = 0;
    this.sameSpotRun = 0;
    this.lastImplicitRefit = now;
    if (persist) {
      void this.io.write(this.path, this.toPayload()).catch(() => {});
    }
  }

  // Fit pool for a refit: the personal pools under the cap, plus a share of
  // the bundled prior that shrinks as personal evidence grows.
  private fitPool(): Array<[GazeFeature, [number, number]]> {
    const personal =
      this.samples.length + this.implicitSamples.length <= FIT_POOL_CAP
        ? this.samples.concat(this.implicitSamples)
        : selectFitPool(this.samples, this.implicitSamples, FIT_POOL_CAP);
    const priorShare = Math.max(0, Math.min(this.priorSamples.length, this.priorSamples.length - 2 * personal.length));
    if (priorShare === 0) {
      return personal;
    }
    const step = this.priorSamples.length / priorShare;
    const prior = Array.from({ length: priorShare }, (_, i) => this.priorSamples[Math.floor(i * step)]);
    return personal.concat(prior);
  }

  // Personal samples behind the live map — calibration plus adopted and
  // pending implicit labels. The prior never counts.
  get personalSampleCount(): number {
    return this.samples.length + this.implicitSamples.length;
  }

  // The map is still learning: too little personal evidence to call settled.
  get learning(): boolean {
    return this.samples.length < LEARNING_POOL_TARGET;
  }

  // The bundled prior still shapes the fit.
  get priorActive(): boolean {
    return this.priorSamples.length > 0 && this.priorSamples.length > 2 * this.personalSampleCount;
  }

  // Out-of-sample error of each label against the map that was live when it
  // arrived — the honest running accuracy the host's error band reads.
  recordLabelError(error: number): void {
    if (!Number.isFinite(error)) {
      return;
    }
    this.learnedErrors.push(error);
    if (this.learnedErrors.length > LEARNED_ERROR_WINDOW) {
      this.learnedErrors.shift();
    }
  }

  get learnedError(): { median: number; labels: number } | null {
    if (this.learnedErrors.length < LEARNED_ERROR_MIN_LABELS) {
      return null;
    }
    return { median: medianOf(this.learnedErrors) ?? 0, labels: this.learnedErrors.length };
  }

  // Seed a starting map from the bundled prior (other people's labelled
  // samples, or the owner's own) when no calibration loaded. Never persisted:
  // the prior is not this user's evidence, and it fades from the fit pool as
  // personal labels arrive.
  seedPrior(entries: Array<{ feature: GazeFeature; target: [number, number] }>, now: number): boolean {
    if (this.featureMap !== null || this.matrix !== null) {
      return false;
    }
    for (const entry of entries) {
      if (this.isUsableSample(entry?.feature, entry?.target)) {
        this.priorSamples.push([entry.feature, [entry.target[0], entry.target[1]]]);
      }
    }
    const result = this.priorSamples.length >= 9 ? this.fitOnce(this.priorSamples) : "too few prior samples";
    if (typeof result === "string") {
      this.priorSamples.length = 0;
      return false;
    }
    this.adopt(result, this.priorSamples, now, false);
    return true;
  }

  // First map from nothing: no map exists to gate the labels, so wait for a
  // screen's worth of spread, trim the worst quarter (looks elsewhere while
  // the cursor rested) and adopt only a fit that clearly beats the raw
  // geometric projection.
  async bootstrapFit(now: number): Promise<boolean> {
    if (this.featureMap !== null || this.matrix !== null) {
      return false;
    }
    if (this.implicitSamples.length < BOOTSTRAP_MIN_LABELS || now - this.lastImplicitRefit < LEARNING_REFIT_INTERVAL_MS) {
      return false;
    }
    const xs = this.implicitSamples.map(([, target]) => target[0]);
    const ys = this.implicitSamples.map(([, target]) => target[1]);
    if (Math.max(...xs) - Math.min(...xs) < BOOTSTRAP_MIN_SPREAD[0] || Math.max(...ys) - Math.min(...ys) < BOOTSTRAP_MIN_SPREAD[1]) {
      return false;
    }
    this.lastImplicitRefit = now;
    const pool = this.implicitSamples.slice();
    const first = this.fitOnce(pool, IMPLICIT_FEATURE_MAP_MIN_SAMPLES);
    if (typeof first === "string") {
      return false;
    }
    // Two trim passes: an outlier drags the first fit toward itself, so the
    // second ranking against the cleaner fit catches what the first missed.
    const keep = Math.max(BOOTSTRAP_MIN_LABELS - 4, Math.ceil(pool.length * 0.75));
    let result = first;
    let kept = pool;
    for (let pass = 0; pass < 2; pass += 1) {
      const fit = result;
      kept = pool
        .map((pair) => ({ pair, error: pointError(this.pendingEstimate(fit, pair[0]), pair[1]) }))
        .sort((a, b) => a.error - b.error)
        .slice(0, keep)
        .map(({ pair }) => pair);
      const trimmed = this.fitOnce(kept, IMPLICIT_FEATURE_MAP_MIN_SAMPLES);
      if (typeof trimmed === "string") {
        break;
      }
      result = trimmed;
    }
    // Judge the fit on labels it never saw: half fits, the other half scores
    // it against the raw projection. In-sample error means nothing here —
    // the residual RBF interpolates its own pool exactly.
    const half = this.fitOnce(kept.filter((_, i) => i % 2 === 0), IMPLICIT_FEATURE_MAP_MIN_SAMPLES);
    const probe = kept.filter((_, i) => i % 2 === 1);
    const rawError = medianOf(probe.map(([feature, target]) => pointError(feature.point, target))) ?? Infinity;
    const fitError =
      typeof half === "string" ? Infinity : (medianOf(probe.map(([feature, target]) => pointError(this.pendingEstimate(half, feature), target))) ?? Infinity);
    if (!(fitError < rawError * 0.9)) {
      console.info("Bootstrap fit kept raw projection", JSON.stringify({ rawError: Number(rawError.toFixed(4)), fitError: Number(fitError.toFixed(4)) }));
      return false;
    }
    this.implicitSamples.length = 0;
    this.implicitSamples.push(...kept);
    this.adopt(result, kept, now, true);
    // Errors measured against the raw projection say nothing about the map
    // that replaces it.
    this.learnedErrors.length = 0;
    console.info("Bootstrap fit adopted", JSON.stringify({ rawError: Number(rawError.toFixed(4)), fitError: Number(fitError.toFixed(4)), labels: kept.length }));
    return true;
  }

  private async commitPending(): Promise<void> {
    const pending = this.pending;
    if (pending === null) {
      return;
    }
    // Personalization: the per-user spatial bias the verified map still
    // misses, fit over the calibration + implicit pools plus the bounded
    // rejected-label evidence at its reduced weight. O(n) binning — far
    // under the in-browser training budget.
    const residualPool: [number, number][] = [];
    const residualErrors: [number, number][] = [];
    const residualWeights: number[] = [];
    for (const [feature, target] of this.samples.concat(this.implicitSamples)) {
      const est = this.pendingEstimate(pending, feature);
      residualPool.push(est);
      residualErrors.push([target[0] - est[0], target[1] - est[1]]);
      residualWeights.push(1);
    }
    for (const [feature, target, weight] of this.rejectedBiasEvidence) {
      const est = this.pendingEstimate(pending, feature);
      if (!est.every(Number.isFinite)) {
        continue;
      }
      residualPool.push(est);
      residualErrors.push([target[0] - est[0], target[1] - est[1]]);
      residualWeights.push(weight);
    }
    const residualMap = fitResidualBias(residualPool, residualErrors, RESIDUAL_BIAS_GRID, residualWeights);
    const payload: CalibrationPayload = {
      raw_projection: pending.useFeatureMap ? "featuremap-v3" : "unclipped-v2",
      affine: pending.matrix,
      rbf: pending.rbf,
      feature_map: pending.useFeatureMap ? pending.featureMap : null,
      feature_rbf: pending.useFeatureMap ? pending.featureRbf : null,
      geometry: pending.geometry,
      source_bounds: { min: pending.sourceMin, max: pending.sourceMax, margin: this.sourceMargin },
      // `raw` is the uncalibrated gaze point — same space toPayload writes,
      // not the reprojected fit-space points in pending.raws.
      samples: this.samples.map(([feature, target]) => ({ raw: feature.point, target })),
      feature_samples: this.samples.slice(-800).map(([feature, target]) => ({ feature, target })),
      validation: this.validation.slice(),
      verify_verdict: this.lastVerdict ?? undefined,
      output_offset: undefined,
      residual_map: residualMap,
      context_fingerprint: this.contextFingerprint ?? undefined,
      feature_version: FEATURE_SCHEMA_VERSION
    };
    let response;
    try {
      response = await this.io.write(this.path, payload);
    } catch (error) {
      // A rejecting bridge (IPC teardown racing the save, crashed renderer)
      // must still close the calibration verdict — silence after a verified
      // run reads as success and leaves the user on the old map.
      this.emit({
        type: "calibration",
        status: "save_failed",
        message: `Failed to save calibration: ${error instanceof Error ? error.message : String(error)}`
      });
      return;
    }
    if (response.ok) {
      this.outputOffset = [0, 0];
      this.residualMap = residualMap;
      this.matrix = pending.matrix;
      this.rbf = pending.rbf;
      this.featureMap = pending.useFeatureMap ? pending.featureMap : null;
      this.featureRbf = pending.useFeatureMap ? pending.featureRbf : null;
      this.geometry = pending.geometry;
      this.sourceMin = pending.sourceMin;
      this.sourceMax = pending.sourceMax;
      this.pending = null;
      this.pursuitBackup = null;
      console.info("Calibration saved", JSON.stringify({ path: response.path, verdict: this.lastVerdict }));
      this.emit({ type: "calibration", status: "saved", path: response.path, geometry: this.geometry, verdict: this.lastVerdict ?? undefined });
    } else {
      this.emit({ type: "calibration", status: "save_failed", message: `Failed to save calibration: ${response.error}` });
    }
  }

  private rejectFit(message: string): void {
    console.warn("Calibration fit rejected:", message);
    this.samples.length = 0;
    this.validation.length = 0;
    this.pending = null;
    this.restorePursuitBackup();
    this.emit({ type: "calibration", status: "rejected_fit", message, verdict: this.lastVerdict ?? undefined });
  }
}

function rbfOffset(rbf: RbfCorrection, point: [number, number]): [number, number] {
  let offsetX = 0;
  let offsetY = 0;
  for (let i = 0; i < rbf.centers.length; i += 1) {
    const radius = Math.hypot(rbf.centers[i][0] - point[0], rbf.centers[i][1] - point[1]);
    const weight = Math.exp(-((radius / rbf.sigma) ** 2));
    offsetX += weight * rbf.weights[i][0];
    offsetY += weight * rbf.weights[i][1];
  }
  return [offsetX, offsetY];
}

function solveLinearSystem(a: number[][], b: number[][]): number[][] | null {
  const n = a.length;
  const m = b[0].length;
  const width = a[0].length + m;
  const aug = a.map((row, index) => row.concat(b[index]));
  for (let col = 0; col < n; col += 1) {
    let pivot = col;
    for (let r = col + 1; r < n; r += 1) {
      if (Math.abs(aug[r][col]) > Math.abs(aug[pivot][col])) {
        pivot = r;
      }
    }
    if (!Number.isFinite(aug[pivot][col]) || Math.abs(aug[pivot][col]) < 1e-12) {
      return null;
    }
    if (pivot !== col) {
      const tmp = aug[pivot];
      aug[pivot] = aug[col];
      aug[col] = tmp;
    }
    for (let r = 0; r < n; r += 1) {
      if (r === col) continue;
      const factor = aug[r][col] / aug[col][col];
      for (let c = col; c < width; c += 1) {
        aug[r][c] -= factor * aug[col][c];
      }
    }
  }
  return aug.map((row, index) => row.slice(a[0].length).map((value) => value / aug[index][index]));
}

// Greedy max-min subsample: the first point seeds it, each next pick is the
// point farthest from everything already chosen — a coverage-preserving way
// to thin a pool without biasing toward the newest or densest regions.
function farthestPointSubset(points: [number, number][], k: number): [number, number][] {
  if (points.length <= k) {
    return points.slice();
  }
  const chosen = [points[0]];
  const dist = points.map((p) => Math.hypot(p[0] - chosen[0][0], p[1] - chosen[0][1]));
  while (chosen.length < k) {
    let bestIdx = -1;
    let bestDist = -1;
    for (let i = 0; i < points.length; i += 1) {
      if (dist[i] > bestDist) {
        bestDist = dist[i];
        bestIdx = i;
      }
    }
    if (bestIdx < 0 || bestDist <= 0) {
      break;
    }
    const picked = points[bestIdx];
    chosen.push(picked);
    dist[bestIdx] = -1;
    for (let i = 0; i < points.length; i += 1) {
      const d = Math.hypot(points[i][0] - picked[0], points[i][1] - picked[1]);
      if (d < dist[i]) {
        dist[i] = d;
      }
    }
  }
  return chosen;
}

// Same farthest-point walk returning indices — lets a tagged pool keep its
// (feature, target) pairing while selection runs on the target geometry.
function farthestPointIndices(points: [number, number][], k: number): number[] {
  if (points.length <= k) {
    return points.map((_, i) => i);
  }
  const chosen = [0];
  const dist = points.map((p) => Math.hypot(p[0] - points[0][0], p[1] - points[0][1]));
  dist[0] = -1;
  while (chosen.length < k) {
    let bestIdx = -1;
    let bestDist = -1;
    for (let i = 0; i < points.length; i += 1) {
      if (dist[i] > bestDist) {
        bestDist = dist[i];
        bestIdx = i;
      }
    }
    if (bestIdx < 0 || bestDist <= 0) {
      break;
    }
    chosen.push(bestIdx);
    dist[bestIdx] = -1;
    for (let i = 0; i < points.length; i += 1) {
      const d = Math.hypot(points[i][0] - points[bestIdx][0], points[i][1] - points[bestIdx][1]);
      if (d < dist[i]) {
        dist[i] = d;
      }
    }
  }
  return chosen;
}

// Merge calibration + implicit pools under a hard cap. All implicit samples
// are kept — they are the fresh evidence the refit exists for — and the
// calibrated remainder is filled by max-spread subsampling on the targets so
// a dense cluster can't evict coverage of the rest of the screen.
function selectFitPool(
  samples: Array<[GazeFeature, [number, number]]>,
  implicit: Array<[GazeFeature, [number, number]]>,
  cap: number
): Array<[GazeFeature, [number, number]]> {
  if (implicit.length >= cap) {
    return implicit.slice(implicit.length - cap);
  }
  const room = cap - implicit.length;
  if (samples.length <= room) {
    return samples.concat(implicit);
  }
  const picked = farthestPointIndices(samples.map(([, target]) => target), room).map((i) => samples[i]);
  return picked.concat(implicit);
}

// Bound the RBF center count — kernel cost is O(centers²) at fit and O(centers)
// per lookup, so an unbounded merged pool would make every apply and every
// refit quadratic in session age.
const RBF_MAX_CENTERS = 40;

function rbfFit(raws: [number, number][], residuals: [number, number][], ridge = 1e-3): RbfCorrection | null {
  if (raws.length < 4) {
    return null;
  }
  // Centers: all raw points while the pool is small, a max-min subsample once
  // it grows — coverage spread is preserved so the correction still spans the
  // calibrated region instead of collapsing onto the densest cluster.
  const centers = farthestPointSubset(raws, RBF_MAX_CENTERS);
  const nearest: number[] = [];
  for (let i = 0; i < centers.length; i += 1) {
    let best = Infinity;
    for (let j = 0; j < centers.length; j += 1) {
      if (i === j) continue;
      best = Math.min(best, Math.hypot(centers[i][0] - centers[j][0], centers[i][1] - centers[j][1]));
    }
    if (Number.isFinite(best)) {
      nearest.push(best);
    }
  }
  nearest.sort((a, b) => a - b);
  const median = nearest.length ? nearest[Math.floor(nearest.length / 2)] : 0;
  const sigma = Math.max(0.05, Math.min(0.5, median * 0.5));
  if (!Number.isFinite(sigma) || sigma <= 0) {
    return null;
  }
  let weights: number[][];
  if (centers.length === raws.length) {
    // Interpolation path: one center per sample, classic kernel solve.
    const kernel = raws.map((a, i) =>
      raws.map((b, j) => Math.exp(-((Math.hypot(a[0] - b[0], a[1] - b[1]) / sigma) ** 2)) + (i === j ? ridge : 0))
    );
    const solved = solveLinearSystem(kernel, residuals.map((r) => [r[0], r[1]]));
    if (solved === null) {
      return null;
    }
    weights = solved;
  } else {
    // Subset-of-regressors ridge solve: (ΦᵀΦ + λn·I) w = Φᵀ r with
    // Φ[i][j] = kernel(sample_i, center_j) — O(n·m² + m³) instead of O(n³).
    const m = centers.length;
    const ata = Array.from({ length: m }, () => new Array<number>(m).fill(0));
    const atb = Array.from({ length: m }, () => new Array<number>(2).fill(0));
    for (let i = 0; i < raws.length; i += 1) {
      const row: number[] = new Array<number>(m);
      for (let j = 0; j < m; j += 1) {
        row[j] = Math.exp(-((Math.hypot(raws[i][0] - centers[j][0], raws[i][1] - centers[j][1]) / sigma) ** 2));
      }
      for (let a = 0; a < m; a += 1) {
        const ka = row[a];
        if (ka === 0) continue;
        for (let b = 0; b < m; b += 1) {
          ata[a][b] += ka * row[b];
        }
        atb[a][0] += ka * residuals[i][0];
        atb[a][1] += ka * residuals[i][1];
      }
    }
    for (let j = 0; j < m; j += 1) {
      ata[j][j] += ridge * raws.length;
    }
    const solved = solveLinearSystem(ata, atb);
    if (solved === null) {
      return null;
    }
    weights = solved;
  }
  if (!weights.every((row) => row.every(Number.isFinite))) {
    return null;
  }
  return {
    centers: centers.map((r) => [r[0], r[1]] as [number, number]),
    weights: weights.map((w) => [w[0], w[1]] as [number, number]),
    sigma
  };
}

function applyMatrix(matrix: number[][], raw: [number, number]): [number, number] {
  return [
    raw[0] * matrix[0][0] + raw[1] * matrix[1][0] + matrix[2][0],
    raw[0] * matrix[0][1] + raw[1] * matrix[1][1] + matrix[2][1]
  ];
}

function pointError(a: [number, number], b: [number, number]): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

export class GazeJumpGate {
  private accepted: { point: [number, number]; at: number } | null = null;
  private candidate: { point: [number, number]; at: number } | null = null;

  // Tolerances are constructor-overridable: the raw-space gate wants the
  // generous 0.35 jump (a broken estimate can land anywhere), while the
  // corrected-space guard sits after a fitted map where a 0.1 jump is a
  // genuine outlier, not a sanity check.
  constructor(
    private readonly maxJump = 0.35,
    private readonly candidateRadius = 0.12,
    private readonly candidateWindowMs = 500,
    private readonly staleMs = 1000
  ) {}

  accept(point: [number, number], at: number): [number, number] | null {
    if (!point.every(Number.isFinite)) return null;
    const previous = this.accepted;
    if (previous === null || at - previous.at > this.staleMs || pointError(point, previous.point) <= this.maxJump ||
      (this.candidate !== null && at - this.candidate.at <= this.candidateWindowMs && pointError(point, this.candidate.point) <= this.candidateRadius)) {
      this.accepted = { point, at };
      this.candidate = null;
      return point;
    }
    this.candidate = { point, at };
    return null;
  }

  // A saved calibration rewrites the raw→screen mapping — the last accepted
  // pre-save point anchors a space that no longer exists, so the gate would
  // pin the post-save output for a full second.
  reset(): void {
    this.accepted = null;
    this.candidate = null;
  }
}

export type EyeValidityState = "tracking" | "closing" | "closed";

// Eye-openness as a state machine, not a flag (Soukupova–Čech EAR: blinks are
// a temporal pattern, not a threshold). The corrupting frames are the
// *transition* — the mesh mid-closure emits garbage before any confirmed-blink
// flag could latch — so output holds the moment eyeOpen drops into the band,
// before a blink is even confirmed.
//
//   tracking → closing  (eyeOpen < 0.55: hold immediately)
//   closing  → closed   (2 consecutive frames < 0.28)
//   closing  → tracking (recovers ≥0.6, or hovers mid-band >450ms — a squint
//                        or talking posture, not a blink in progress)
//   closed   → tracking (2 consecutive frames ≥0.6 — real reopen, not flicker;
//                        or held >2.5s — occlusion/pathology, not a blink)
export class EyeValidity {
  private state: EyeValidityState = "tracking";
  private closedStreak = 0;
  private reopenStreak = 0;
  private closingSince = 0;
  private closedSince = 0;
  private midBandSince = 0;
  private settleUntil = 0;
  private lastNow = 0;

  update(eyeOpen: number, now: number): EyeValidityState {
    this.lastNow = now;
    if (!Number.isFinite(eyeOpen)) {
      return this.state;
    }
    if (this.state === "tracking") {
      if (eyeOpen < EYE_VALIDITY_ENTER) {
        this.state = "closing";
        this.closingSince = now;
        this.closedStreak = 0;
      }
      return this.state;
    }
    if (this.state === "closing") {
      if (eyeOpen < BLINK_CLOSE_THRESHOLD) {
        this.closedStreak += 1;
        if (this.closedStreak >= 2) {
          this.state = "closed";
          this.closedSince = now;
          this.reopenStreak = 0;
          this.midBandSince = 0;
        }
      } else if (eyeOpen >= EYE_VALIDITY_RECOVER || now - this.closingSince > CLOSING_TIMEOUT_MS) {
        this.state = "tracking";
        this.closedStreak = 0;
        // A dip that never confirmed still passed mid-closure frames through —
        // give the signal a beat to stabilize before emitting again.
        this.settleUntil = now + 90;
      }
      return this.state;
    }
    // "closed": a real blink runs well under a second. A "blink" held past
    // CLOSED_TIMEOUT_MS is occlusion or a pathological lid reading (squint,
    // glare, hair over the eye), not a blink — release instead of freezing
    // the output forever. If the signal still reads mid-band it re-enters
    // closing on its own.
    if (now - this.closedSince > CLOSED_TIMEOUT_MS) {
      this.state = "tracking";
      this.closedStreak = 0;
      this.reopenStreak = 0;
      this.midBandSince = 0;
      return this.state;
    }
    // Squint trap: a mid-band reading (lid partially open) sustained ~1s is
    // this user's open posture — ptosis, squint, glare — not a held blink.
    // Reopen requires ≥0.6 which some users never produce; without this they
    // park in "closed" until the 2.5s occlusion timeout on every blink.
    if (eyeOpen >= BLINK_CLOSE_THRESHOLD && eyeOpen < EYE_VALIDITY_RECOVER) {
      if (this.midBandSince === 0) {
        this.midBandSince = now;
      } else if (now - this.midBandSince >= SQUINT_RELEASE_MS) {
        this.state = "tracking";
        this.closedStreak = 0;
        this.reopenStreak = 0;
        this.midBandSince = 0;
        this.settleUntil = now + 90;
        return this.state;
      }
    } else {
      this.midBandSince = 0;
    }
    if (eyeOpen >= EYE_VALIDITY_RECOVER) {
      this.reopenStreak += 1;
      if (this.reopenStreak >= 2) {
        this.state = "tracking";
        this.closedStreak = 0;
        this.reopenStreak = 0;
        // Reopen frames carry unstable angles (lid still recovering, iris
        // contour half-occluded) — holding ~140ms is what stops the
        // post-blink jump the user sees.
        this.settleUntil = now + 140;
      }
    } else {
      this.reopenStreak = 0;
    }
    return this.state;
  }

  get holding(): boolean {
    return this.state !== "tracking" || this.lastNow < this.settleUntil;
  }

  get blinking(): boolean {
    return this.state === "closed";
  }

  get current(): EyeValidityState {
    return this.state;
  }

  reset(): void {
    this.state = "tracking";
    this.closedStreak = 0;
    this.reopenStreak = 0;
    this.closingSince = 0;
    this.closedSince = 0;
    this.midBandSince = 0;
    this.settleUntil = 0;
  }
}

const EYE_VALIDITY_ENTER = 0.55;
const EYE_VALIDITY_RECOVER = 0.6;
const CLOSING_TIMEOUT_MS = 450;
// Mid-band-open threshold while "closed": ~1s of sustained squint means the
// lid simply doesn't open past it — treat it as this user's open posture.
const SQUINT_RELEASE_MS = 1000;
// ~2.5s: longer than any real blink, short enough that a stuck mid-band
// reading (occlusion/pathology) un-freezes the marker instead of holding it.
const CLOSED_TIMEOUT_MS = 2500;

// Drift correction guards — a confirmed correction is trusted with the dot,
// so the evidence bar is deliberately high:
//   SPAN: the rejection window must stretch over ≥30s of real use. Labels
//   arrive per cursor-rest (a >8px move + 700ms stillness in main.cjs), so a
//   burst of rests while attention is elsewhere — or right after a
//   calibration save — used to confirm "drift" in seconds. Real drift is
//   still there in 30s; a labeling artifact often isn't.
//   TARGET SPREAD: real drift rejects labels *everywhere*; rejections
//   anchored on one rest spot (a cursor parked where nobody is looking)
//   describe that spot's label quality, not the map.
//   STEP: each confirmation moves the output offset by ≤0.02 of screen
//   (~30px on a 13" panel) — a nudge, never a teleport. Genuine drift still
//   converges over successive confirmations; a bogus one can't.
const DRIFT_MIN_EVIDENCE_SPAN_MS = 30_000;
const DRIFT_MIN_TARGET_SPREAD = 0.06;
const DRIFT_MAX_STEP = 0.02;
// rehealDrift re-derives the offset after a refit — bounded per call for the
// same reason: a bad implicit batch must not snap the output across the
// screen in one step.
const DRIFT_REHEAL_MAX_STEP = 0.05;
// Cumulative bound for the translation correction — saturation means the
// problem is bigger than a reposition and the UI escalates to recalibration.
const DRIFT_OFFSET_BOUND = 0.35;

// Drift detection (Smooth-i direction): implicit labels that the live map
// keeps *rejecting* are evidence of systematic map shift — a laptop reposition
// or camera nudge — as long as the rejections point the same way. Random
// scatter means the user just looked elsewhere; a consistent median offset
// means the geometry moved. `record` returns the correction once per cooldown
// when the window proves drift, so the UI can escalate to recalibration.
export class DriftMonitor {
  private history: Array<{ agreed: boolean; dx: number; dy: number; at: number; tx?: number; ty?: number }> = [];
  private lastWarnAt = -Infinity;

  // Returns the median consistent rejection offset when drift is confirmed —
  // that vector IS the correction: applying it to map outputs undoes the
  // camera/laptop move without any recalibration. `target` (the implicit
  // label's screen position) is optional; when most rejected entries carry
  // one, the targets must also spread across the screen — see above.
  record(agreed: boolean, offset: [number, number], now: number, target?: [number, number]): [number, number] | null {
    this.history.push({ agreed, dx: offset[0], dy: offset[1], at: now, tx: target?.[0], ty: target?.[1] });
    if (this.history.length > 12) {
      this.history.shift();
    }
    if (this.history.length < 8 || now - this.lastWarnAt < 90_000) {
      return null;
    }
    // Sustained evidence only: the whole window must span ≥30s. A burst of
    // bad labels in a few seconds must never reach the correction path.
    if (now - this.history[0].at < DRIFT_MIN_EVIDENCE_SPAN_MS) {
      return null;
    }
    const rejected = this.history.filter((h) => !h.agreed);
    if (rejected.length < Math.ceil(this.history.length * 0.75)) {
      return null;
    }
    // Rejections from (nearly) a single rest spot are a parked-cursor
    // artifact, not drift — demand the evidence cover some of the screen.
    const tagged = rejected.filter((h) => h.tx !== undefined && h.ty !== undefined);
    if (tagged.length >= Math.ceil(rejected.length * 0.5)) {
      const xs = tagged.map((h) => h.tx ?? 0);
      const ys = tagged.map((h) => h.ty ?? 0);
      const spread = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
      if (spread < DRIFT_MIN_TARGET_SPREAD) {
        return null;
      }
    }
    const mx = medianOf(rejected.map((h) => h.dx)) ?? 0;
    const my = medianOf(rejected.map((h) => h.dy)) ?? 0;
    const medMag = Math.hypot(mx, my);
    // Same magnitude as the accept gate (0.09): a sustained offset just past
    // it is real systematic shift, not scatter — with a higher bar here the
    // 0.09-0.1 band was a dead zone that neither admitted samples nor healed.
    if (medMag <= 0.09) {
      return null;
    }
    const ax = rejected.reduce((sum, h) => sum + h.dx, 0) / rejected.length;
    const ay = rejected.reduce((sum, h) => sum + h.dy, 0) / rejected.length;
    if (Math.hypot(ax, ay) < medMag * 0.7) {
      return null;
    }
    this.lastWarnAt = now;
    this.history.length = 0;
    return [mx, my];
  }

  reset(): void {
    this.history.length = 0;
    // The 90s warn cooldown must not survive a reset — it's called on
    // calibration save, precisely when a new drift baseline begins.
    this.lastWarnAt = -Infinity;
  }
}

export function isHeadTurned(eyeSpanPx: number, headWidthPx: number): boolean {
  return Number.isFinite(eyeSpanPx) && eyeSpanPx < Math.max(1, headWidthPx) * MIN_EYE_SPAN_RATIO;
}

// Constant-velocity coast during holds (the I-KF behaviour that beat I-VT on
// ISO-9241 pointing evals): for the first ~400ms of a blink/loss the marker
// eases along its last velocity instead of freezing mid-gesture; displacement
// is capped so a stale velocity can't fly the dot away.
export function coastPosition(
  pos: [number, number],
  vel: [number, number],
  heldMs: number,
  maxMs = 400,
  maxStep = 0.045
): [number, number] {
  const t = Math.min(Math.max(heldMs, 0), maxMs) / 1000;
  let dx = vel[0] * t;
  let dy = vel[1] * t;
  const d = Math.hypot(dx, dy);
  if (d > maxStep) {
    const s = maxStep / d;
    dx *= s;
    dy *= s;
  }
  return [clamp01(pos[0] + dx), clamp01(pos[1] + dy)];
}

export type TimedFeature = { feature: GazeFeature; at: number };

// Pursuit labels: renderer-clock target positions streamed ahead of frames;
// interpolating back to the frame's capture instant removes the pursuit lag
// that otherwise contaminates every (feature, target) pair.
export function interpolateTargetAt(history: Array<{ at: number; pos: [number, number] }>, t: number): [number, number] | null {
  if (history.length === 0) {
    return null;
  }
  if (t <= history[0].at) {
    return history[0].pos;
  }
  for (let i = 1; i < history.length; i += 1) {
    if (history[i].at >= t) {
      const span = history[i].at - history[i - 1].at;
      const k = span > 0 ? (t - history[i - 1].at) / span : 1;
      return [
        history[i - 1].pos[0] + (history[i].pos[0] - history[i - 1].pos[0]) * k,
        history[i - 1].pos[1] + (history[i].pos[1] - history[i - 1].pos[1]) * k
      ];
    }
  }
  return history[history.length - 1].pos;
}

export interface FeatureMap {
  coeffs: number[][];
  mean: number[];
  scale: number[];
}

// Optional feature fields read through this: `?? 0` misses NaN/Infinity, and
// either would propagate through the whole vector into the regression.
function fin(v: number | undefined, fallback = 0): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

// Direct feature→screen regression: bypasses the projection chain's
// compounded approximations (FOV, distance, display size, tan) and learns the
// model's systematic bias per user. Quadratic-ish basis over both eyes' angles
// + head position + iris-distance proxy.
export function gazeFeatureVector(f: GazeFeature): number[] {
  // Roll-align the per-eye angles: a tilted head rotates the camera-frame
  // pitch/yaw axes together, so express them in the head's frame first —
  // otherwise a lean reads as a gaze change.
  const roll = fin(f.headRollRad);
  const cosR = Math.cos(roll);
  const sinR = Math.sin(roll);
  const leftYawH = f.leftYawDeg * cosR + f.leftPitchDeg * sinR;
  const leftPitchH = -f.leftYawDeg * sinR + f.leftPitchDeg * cosR;
  const rightYawH = f.rightYawDeg * cosR + f.rightPitchDeg * sinR;
  const rightPitchH = -f.rightYawDeg * sinR + f.rightPitchDeg * cosR;
  const yawM = (leftYawH + rightYawH) * 0.5;
  const pitchM = (leftPitchH + rightPitchH) * 0.5;
  const yawD = leftYawH - rightYawH;
  const pitchD = leftPitchH - rightPitchH;
  // Frame-relative terms must normalize by the size the feature was
  // actually captured at — under the 720p default (or a VGA fallback) the
  // same physical pose lands at different pixels. Persisted samples that
  // predate frameWidth/frameHeight were all captured at VGA, which is what
  // the CAMERA_* constants mean here.
  const frameW = Math.max(1, fin(f.frameWidth, CAMERA_WIDTH));
  const frameH = Math.max(1, fin(f.frameHeight, CAMERA_HEIGHT));
  const ecx = f.eyeCenterPx[0] / frameW;
  const ecy = f.eyeCenterPx[1] / frameH;
  // Iris diameter is a px *size*, not a position — its ~18px "typical"
  // constant is a VGA figure, so scale it by the frame's linear resolution
  // to keep the dim resolution-invariant across a mixed pool.
  const irisScale = frameW / CAMERA_WIDTH;
  const iris = (f.irisDiameterPx || 18 * irisScale) / (18 * irisScale);
  const lox = fin(f.leftIrisOffset?.[0]);
  const loy = fin(f.leftIrisOffset?.[1]);
  const rox = fin(f.rightIrisOffset?.[0]);
  const roy = fin(f.rightIrisOffset?.[1]);
  const y = yawM / 30;
  const p = pitchM / 30;
  // Metric head pose now arrives in degrees — /30 like the other angle dims.
  // Persisted samples captured under the proxies hold ~unitless ratios;
  // scaled down they read as near-neutral rather than corrupting the pool.
  const hyaw = fin(f.headYawProxy) / 30;
  const hpitch = fin(f.headPitchProxy) / 30;
  // Appended dims keep older featuremap-v3 payloads working — a saved map
  // iterates only its own coefficient count and sees its original features.
  const lmx = fin(f.leftMeshOffset?.[0]);
  const lmy = fin(f.leftMeshOffset?.[1]);
  const rmx = fin(f.rightMeshOffset?.[0]);
  const rmy = fin(f.rightMeshOffset?.[1]);
  return [
    1, y, p, y * y, p * p, y * p, yawD / 30, pitchD / 30,
    ecx, ecy, ecx * ecx, ecy * ecy, ecx * ecy, iris, y * ecx, p * ecy,
    lox, loy, rox, roy,
    hyaw, hpitch, sinR, cosR - 1,
    lmx, lmy, rmx, rmy,
    fin(f.leftEllipseEcc, 0.8) - 0.8,
    fin(f.rightEllipseEcc, 0.8) - 0.8,
    fin(f.leftEllipseAngle?.[0]),
    fin(f.leftEllipseAngle?.[1]),
    fin(f.rightEllipseAngle?.[0]),
    fin(f.rightEllipseAngle?.[1]),
    fin(f.leftApertureRatio, 1.6) - 1.6,
    fin(f.rightApertureRatio, 1.6) - 1.6,
    fin(f.appYawDeg) / 30,
    fin(f.appPitchDeg) / 30,
    fin(f.appConf),
    fin(f.jawX),
    fin(f.jawY),
    fin(f.headFrameX),
    fin(f.headFrameY),
    // Required dims (NaN fallback, not the usual 0): a persisted 43-dim
    // sample lacks these fields and must fail isUsableSample rather than
    // zero-fill into a 48-dim pool it was never captured under.
    fin(f.appYawHeadFrameX, NaN) / 30,
    fin(f.appYawHeadFrameY, NaN) / 30,
    fin(f.appPitchHeadFrameX, NaN) / 30,
    fin(f.appPitchHeadFrameY, NaN) / 30,
    fin(f.appConfHeadFrameRadius, NaN)
  ];
}

export function applyFeatureMap(map: FeatureMap, f: GazeFeature): [number, number] {
  const v = gazeFeatureVector(f);
  let x = 0;
  let y = 0;
  for (let j = 0; j < map.coeffs.length; j += 1) {
    // Clip each standardized dim: a feature that was near-constant during
    // capture (jaw closed, head still) has a floored scale — without the
    // clip a runtime shift would amplify through that dim ×200 instead of
    // saturating at ±5σ.
    const z = j === 0 ? 1 : Math.max(-5, Math.min(5, (v[j] - map.mean[j]) / map.scale[j]));
    if (!Number.isFinite(z)) {
      continue; // a malformed map dim must not take the whole output NaN
    }
    x += z * map.coeffs[j][0];
    y += z * map.coeffs[j][1];
  }
  return [x, y];
}

// Leave-one-out error for the affine map over the fitted raw points.
// Closed-form hat-matrix LOO: for a linear fit, e_loo_i = e_i / (1 - h_ii)
// where h_ii = aᵢᵀ(AᵀA)⁻¹aᵢ — one 3×3 solve replaces the per-fold refit.
function looAffineError(raws: [number, number][], targets: [number, number][]): number {
  if (raws.length < 4) {
    return Infinity;
  }
  const ata = [
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0]
  ];
  const atb = [
    [0, 0],
    [0, 0],
    [0, 0]
  ];
  for (let i = 0; i < raws.length; i += 1) {
    const row = [raws[i][0], raws[i][1], 1];
    for (let a = 0; a < 3; a += 1) {
      for (let b = 0; b < 3; b += 1) {
        ata[a][b] += row[a] * row[b];
      }
      atb[a][0] += row[a] * targets[i][0];
      atb[a][1] += row[a] * targets[i][1];
    }
  }
  let inv: number[][];
  try {
    inv = invert3x3(ata);
  } catch {
    return Infinity;
  }
  const coeffs = inv.map((row) => [
    row[0] * atb[0][0] + row[1] * atb[1][0] + row[2] * atb[2][0],
    row[0] * atb[0][1] + row[1] * atb[1][1] + row[2] * atb[2][1]
  ]);
  let sum = 0;
  for (let i = 0; i < raws.length; i += 1) {
    const row = [raws[i][0], raws[i][1], 1];
    let h = 0;
    for (let a = 0; a < 3; a += 1) {
      for (let b = 0; b < 3; b += 1) {
        h += row[a] * inv[a][b] * row[b];
      }
    }
    // A degenerate fold reads as h→1 (the point can't be predicted without
    // itself) — floor the denominator so the LOO error blows up honestly
    // instead of dividing by ~0 or going negative on numerical noise.
    const denom = Math.max(1e-3, 1 - h);
    const [px, py] = applyMatrix(coeffs, raws[i]);
    sum += pointError([px, py], targets[i]) / denom;
  }
  return sum / raws.length;
}

// Build the standardized design matrix + normal equations shared by
// fitFeatureMap and the closed-form LOO path — one place to keep the ridge
// penalty honest (every dim except the intercept gets λ·n).
function featureDesign(
  features: GazeFeature[],
  targets: [number, number][],
  ridgeLambda = 1e-2
): { phi: number[][]; ata: number[][]; atb: number[][]; mean: number[]; scale: number[] } | null {
  const n = features.length;
  if (n < 10) {
    return null;
  }
  const k = gazeFeatureVector(features[0]).length;
  const rawPhi = features.map(gazeFeatureVector);
  const mean = new Array<number>(k).fill(0);
  const scale = new Array<number>(k).fill(1);
  for (let j = 1; j < k; j += 1) {
    for (let i = 0; i < n; i += 1) {
      mean[j] += rawPhi[i][j];
    }
    mean[j] /= n;
    for (let i = 0; i < n; i += 1) {
      scale[j] += Math.abs(rawPhi[i][j] - mean[j]);
    }
    scale[j] = Math.max(scale[j] / n, 1e-3);
  }
  const phi = rawPhi.map((row) => row.map((v, j) => (j === 0 ? 1 : (v - mean[j]) / scale[j])));
  const ata = Array.from({ length: k }, () => new Array<number>(k).fill(0));
  const atb = Array.from({ length: k }, () => new Array<number>(2).fill(0));
  for (let i = 0; i < n; i += 1) {
    for (let a = 0; a < k; a += 1) {
      for (let b = 0; b < k; b += 1) {
        ata[a][b] += phi[i][a] * phi[i][b];
      }
      atb[a][0] += phi[i][a] * targets[i][0];
      atb[a][1] += phi[i][a] * targets[i][1];
    }
  }
  for (let j = 1; j < k; j += 1) {
    ata[j][j] += ridgeLambda * n;
  }
  return { phi, ata, atb, mean, scale };
}

function fitFeatureMap(features: GazeFeature[], targets: [number, number][], ridgeLambda = 1e-2): FeatureMap | null {
  const built = featureDesign(features, targets, ridgeLambda);
  if (built === null) {
    return null;
  }
  const coeffs = solveLinearSystem(built.ata, built.atb);
  if (coeffs === null || !coeffs.every((row) => row.every(Number.isFinite))) {
    return null;
  }
  return { coeffs, mean: built.mean, scale: built.scale };
}

// Leave-one-out error for feature-space ridge regression, closed form:
// ridge is a linear smoother, so e_loo_i = e_i / (1 - h_ii) with
// h_ii = φᵢᵀ(ΦᵀΦ+Λ)⁻¹φᵢ — one k×k solve for coeffs and the penalized inverse
// together replaces the O(n) per-fold refits (each itself O(nk² + k³)).
function looFeatureError(features: GazeFeature[], targets: [number, number][]): number {
  const built = featureDesign(features, targets);
  if (built === null || features.length < 5) {
    return Infinity;
  }
  const k = built.phi[0].length;
  // Solve ata · X = [atb | I] in one elimination — columns 0-1 come back as
  // the fitted coefficients, columns 2..k+1 as (ΦᵀΦ+Λ)⁻¹.
  const rhs = built.atb.map((row, i) => {
    const ident = new Array<number>(k).fill(0);
    ident[i] = 1;
    return row.concat(ident);
  });
  const solved = solveLinearSystem(built.ata, rhs);
  if (solved === null) {
    return Infinity;
  }
  const coeffs = solved.map((row) => row.slice(0, 2));
  const inv = solved.map((row) => row.slice(2));
  let sum = 0;
  for (let i = 0; i < features.length; i += 1) {
    const phi = built.phi[i];
    const px = phi.reduce((acc, v, j) => acc + v * coeffs[j][0], 0);
    const py = phi.reduce((acc, v, j) => acc + v * coeffs[j][1], 0);
    let h = 0;
    for (let a = 0; a < k; a += 1) {
      const phiA = phi[a];
      for (let b = 0; b < k; b += 1) {
        h += phiA * inv[a][b] * phi[b];
      }
    }
    const denom = Math.max(1e-3, 1 - h);
    sum += pointError([px, py], targets[i]) / denom;
  }
  return sum / features.length;
}

function solveAffine(samples: Array<[[number, number], [number, number]]>): number[][] {
  const ata = [
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0]
  ];
  const atb = [
    [0, 0],
    [0, 0],
    [0, 0]
  ];
  for (const [[x, y], [tx, ty]] of samples) {
    const row = [x, y, 1];
    for (let i = 0; i < 3; i += 1) {
      for (let j = 0; j < 3; j += 1) {
        ata[i][j] += row[i] * row[j];
      }
      atb[i][0] += row[i] * tx;
      atb[i][1] += row[i] * ty;
    }
  }
  const inv = invert3x3(ata);
  return inv.map((row) => [
    row[0] * atb[0][0] + row[1] * atb[1][0] + row[2] * atb[2][0],
    row[0] * atb[0][1] + row[1] * atb[1][1] + row[2] * atb[2][1]
  ]);
}

function invert3x3(m: number[][]): number[][] {
  const a = m[0][0];
  const b = m[0][1];
  const c = m[0][2];
  const d = m[1][0];
  const e = m[1][1];
  const f = m[1][2];
  const g = m[2][0];
  const h = m[2][1];
  const i = m[2][2];
  const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (Math.abs(det) <= 1e-12) {
    throw new Error("Calibration samples are singular");
  }
  return [
    [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
    [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
    [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
  ];
}

export const PREVIEW_WIDTH = 320;
let imageDataScratchCanvas: HTMLCanvasElement | null = null;

export function previewHeightFor(frameWidth: number, frameHeight: number): number {
  return Math.max(1, Math.round((frameHeight * PREVIEW_WIDTH) / Math.max(1, frameWidth)));
}

// Renders the camera frame plus detection overlays onto a preview-sized
// context. Annotations are drawn in preview space via a scale transform so no
// full-resolution canvas copy is needed.
export function renderPreviewAnnotations(
  ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D,
  frameWidth: number,
  frameHeight: number,
  head: Detection | null,
  eyes: Detection[],
  mouth: Detection | null,
  message: string | null,
  widthRatio: number | null,
  gazeAngles?: [number, number],
  irisContours?: [number, number][][]
): void {
  const sx = PREVIEW_WIDTH / Math.max(1, frameWidth);
  const sy = previewHeightFor(frameWidth, frameHeight) / Math.max(1, frameHeight);
  ctx.save();
  ctx.scale(sx, sy);
  const lw = 2 / sx;
  if (head) {
    drawBox(ctx, head, "#14dc5a", "Head", lw);
  }
  for (const eye of eyes) {
    drawBox(ctx, eye, "#00d2ff", "Eye", lw);
    const [cx, cy] = center(eye);
    ctx.fillStyle = "#00d2ff";
    ctx.beginPath();
    ctx.arc(cx, cy, 4 / sx, 0, Math.PI * 2);
    ctx.fill();
  }
  if (mouth) {
    drawBox(ctx, lipMotionCropDetection({ width: frameWidth, height: frameHeight }, mouth), "#ff8c00", "Mouth", lw);
  }
  if (irisContours) {
    ctx.strokeStyle = "#ff8c00";
    ctx.lineWidth = 1.5 / sx;
    for (const contour of irisContours) {
      if (contour.length < 3) continue;
      ctx.beginPath();
      ctx.moveTo(contour[0][0], contour[0][1]);
      for (let i = 1; i < contour.length; i += 1) {
        ctx.lineTo(contour[i][0], contour[i][1]);
      }
      ctx.closePath();
      ctx.stroke();
    }
  }
  if (gazeAngles && eyes.length >= 2) {
    drawGazeLines(ctx, eyes, gazeAngles[0], gazeAngles[1], lw / 2, Math.sqrt(frameWidth * frameHeight));
  }
  if (message) {
    strokeText(ctx, message, 12, 28, 22);
  }
  if (widthRatio !== null) {
    strokeText(ctx, `Head/Face ${widthRatio.toFixed(3)}x`, 12, frameHeight - 14, 18);
  }
  ctx.restore();
}

export function createPreviewImage(
  source: ImageData | CanvasImageSource,
  frameWidth: number,
  frameHeight: number,
  head: Detection | null,
  eyes: Detection[],
  mouth: Detection | null,
  message: string | null,
  widthRatio: number | null,
  gazeAngles?: [number, number],
  irisContours?: [number, number][][]
): string {
  let src: CanvasImageSource;
  if (source instanceof ImageData) {
    if (imageDataScratchCanvas === null) {
      imageDataScratchCanvas = document.createElement("canvas");
    }
    if (imageDataScratchCanvas.width !== source.width || imageDataScratchCanvas.height !== source.height) {
      imageDataScratchCanvas.width = source.width;
      imageDataScratchCanvas.height = source.height;
    }
    imageDataScratchCanvas.getContext("2d")?.putImageData(source, 0, 0);
    src = imageDataScratchCanvas;
  } else {
    src = source;
  }
  const preview = document.createElement("canvas");
  preview.width = PREVIEW_WIDTH;
  preview.height = previewHeightFor(frameWidth, frameHeight);
  const previewCtx = preview.getContext("2d");
  if (!previewCtx) {
    return "";
  }
  previewCtx.drawImage(src, 0, 0, preview.width, preview.height);
  renderPreviewAnnotations(previewCtx, frameWidth, frameHeight, head, eyes, mouth, message, widthRatio, gazeAngles, irisContours);
  return preview.toDataURL("image/jpeg", 0.72);
}

function drawBox(
  ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D,
  det: Detection,
  color: string,
  label: string,
  lineWidth = 2
): void {
  ctx.lineWidth = lineWidth;
  ctx.strokeStyle = color;
  ctx.strokeRect(det.x1, det.y1, width(det), height(det));
  strokeText(ctx, `${label} ${det.score.toFixed(2)}`, det.x1, Math.max(18, det.y1 - 6), 16, color);
}

function strokeText(
  ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
  fill = "#ffffff"
): void {
  ctx.font = `${size}px sans-serif`;
  ctx.lineWidth = 4;
  ctx.strokeStyle = "#000000";
  ctx.strokeText(text, x, y);
  ctx.fillStyle = fill;
  ctx.fillText(text, x, y);
}

function drawGazeLines(
  ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D,
  eyes: Detection[],
  yawDeg: number,
  pitchDeg: number,
  lineScale = 1,
  frameDiagonalPx?: number
): void {
  const diag = frameDiagonalPx ?? Math.sqrt(ctx.canvas.width * ctx.canvas.height);
  const length = 0.4 * diag;
  const dx = length * Math.sin((yawDeg * Math.PI) / 180);
  const dy = length * Math.sin((-pitchDeg * Math.PI) / 180);
  for (const eye of eyes.slice(0, 2)) {
    const [cx, cy] = center(eye);
    ctx.lineCap = "round";
    ctx.lineWidth = 7 * lineScale;
    ctx.strokeStyle = "#000000";
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + dx, cy + dy);
    ctx.stroke();
    ctx.lineWidth = 4 * lineScale;
    ctx.strokeStyle = "#00ff00";
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + dx, cy + dy);
    ctx.stroke();
  }
}
