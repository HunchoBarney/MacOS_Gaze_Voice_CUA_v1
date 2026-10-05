import type { BackendMessage, GazeProjectionMode } from "../global";

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
export const BLINK_REOPEN_THRESHOLD = 0.45;
export const MIN_EYE_SPAN_RATIO = 0.2;
export const DISTANCE_MIN_M = 0.15;
export const DISTANCE_MAX_M = 3.0;
export const DISTANCE_SMOOTHING_ALPHA = 0.35;
export const CALIBRATION_SAMPLE_TARGET = 13;
export const CALIBRATION_FIT_MAX_ERROR = 0.18;
const WEIGHT_X_CANDIDATES = [1.0, 0.7, 1.3];
const WEIGHT_Y_CANDIDATES = [0.25, 0.0, 0.15, 0.4, 0.6];
const RETINAFACE_SCORE_THRESHOLD_FLOOR = 0.7;
const RETINAFACE_CENTER_VARIANCE = 0.1;
const RETINAFACE_SIZE_VARIANCE = 0.2;
const RETINAFACE_PRIOR_COUNT = 12600;
let retinaFacePriors: Float32Array | null = null;

export interface CameraResolution {
  name?: string;
  width: number;
  height: number;
}

export const DEFAULT_CAMERA_RESOLUTION: CameraResolution = { name: "VGA", width: CAMERA_WIDTH, height: CAMERA_HEIGHT };

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
  return preset;
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
  validation?: Array<{ raw: [number, number]; target: [number, number]; error: number }>;
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

export function createRetinaFaceInputNhwc(frame: ImageData): Float32Array {
  const input = new Float32Array(1 * RETINAFACE_INPUT_HEIGHT * RETINAFACE_INPUT_WIDTH * 3);
  const data = frame.data;
  for (let y = 0; y < RETINAFACE_INPUT_HEIGHT; y += 1) {
    const srcY = Math.min(frame.height - 1, Math.floor(((y + 0.5) * frame.height) / RETINAFACE_INPUT_HEIGHT));
    for (let x = 0; x < RETINAFACE_INPUT_WIDTH; x += 1) {
      const srcX = Math.min(frame.width - 1, Math.floor(((x + 0.5) * frame.width) / RETINAFACE_INPUT_WIDTH));
      const src = (srcY * frame.width + srcX) * 4;
      const dst = (y * RETINAFACE_INPUT_WIDTH + x) * 3;
      input[dst] = data[src] - 104;
      input[dst + 1] = data[src + 1] - 117;
      input[dst + 2] = data[src + 2] - 123;
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

export function createYoloInputNhwc(frame: ImageData): Float32Array {
  const input = new Float32Array(1 * YOLO_INPUT_HEIGHT * YOLO_INPUT_WIDTH * 3);
  const data = frame.data;
  for (let y = 0; y < YOLO_INPUT_HEIGHT; y += 1) {
    const srcY = Math.min(frame.height - 1, Math.floor(((y + 0.5) * frame.height) / YOLO_INPUT_HEIGHT));
    for (let x = 0; x < YOLO_INPUT_WIDTH; x += 1) {
      const srcX = Math.min(frame.width - 1, Math.floor(((x + 0.5) * frame.width) / YOLO_INPUT_WIDTH));
      const src = (srcY * frame.width + srcX) * 4;
      const dst = (y * YOLO_INPUT_WIDTH + x) * 3;
      input[dst] = data[src] / 255;
      input[dst + 1] = data[src + 1] / 255;
      input[dst + 2] = data[src + 2] / 255;
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

export function createLipMotionInputNhwc(frame: ImageData, mouth: Detection): Float32Array {
  const input = new Float32Array(1 * LIP_MOTION_INPUT_HEIGHT * LIP_MOTION_INPUT_WIDTH * 3);
  forEachDetectionPixel(frame, mouth, LIP_MOTION_INPUT_WIDTH, LIP_MOTION_INPUT_HEIGHT, (dstPixel, src) => {
    const dst = dstPixel * 3;
    input[dst] = frame.data[src] / 255;
    input[dst + 1] = frame.data[src + 1] / 255;
    input[dst + 2] = frame.data[src + 2] / 255;
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
  return { head, eyes, mouth: null };
}

export function parseRetinaFacePreNmsOutput(
  boxes: ArrayLike<number>,
  scores: ArrayLike<number>,
  landms: ArrayLike<number>,
  scoreThreshold: number,
  targetWidth = CAMERA_WIDTH,
  targetHeight = CAMERA_HEIGHT
): DetectionResult {
  const threshold = Math.max(scoreThreshold, RETINAFACE_SCORE_THRESHOLD_FLOOR);
  const candidateCount = Math.min(Math.floor(boxes.length / 4), scores.length, Math.floor(landms.length / 10));
  let bestIndex = -1;
  let bestScore = -Infinity;
  for (let index = 0; index < candidateCount; index += 1) {
    const score = Number(scores[index]);
    if (Number.isFinite(score) && score >= threshold && score > bestScore) {
      bestScore = score;
      bestIndex = index;
    }
  }
  if (bestIndex < 0) {
    return { head: null, eyes: [], mouth: null };
  }

  const boxOffset = bestIndex * 4;
  const rawX1 = Number(boxes[boxOffset]);
  const rawY1 = Number(boxes[boxOffset + 1]);
  const rawX2 = Number(boxes[boxOffset + 2]);
  const rawY2 = Number(boxes[boxOffset + 3]);
  if (![rawX1, rawY1, rawX2, rawY2].every(Number.isFinite)) {
    return { head: null, eyes: [], mouth: null };
  }
  const x1 = scaleRetinaFaceX(rawX1, targetWidth);
  const y1 = scaleRetinaFaceY(rawY1, targetHeight);
  const x2 = scaleRetinaFaceX(rawX2, targetWidth);
  const y2 = scaleRetinaFaceY(rawY2, targetHeight);
  if (x2 <= x1 || y2 <= y1) {
    return { head: null, eyes: [], mouth: null };
  }

  const landmOffset = bestIndex * 10;
  const rightEye: [number, number] = [
    scaleRetinaFaceX(Number(landms[landmOffset]), targetWidth),
    scaleRetinaFaceY(Number(landms[landmOffset + 1]), targetHeight)
  ];
  const leftEye: [number, number] = [
    scaleRetinaFaceX(Number(landms[landmOffset + 2]), targetWidth),
    scaleRetinaFaceY(Number(landms[landmOffset + 3]), targetHeight)
  ];
  if (!isFinitePoint(rightEye) || !isFinitePoint(leftEye)) {
    return { head: null, eyes: [], mouth: null };
  }

  const head: Detection = { classId: HEAD_CLASS_ID, score: bestScore, x1, y1, x2, y2 };
  const eyeBoxSize = Math.max(10, width(head) * 0.08);
  const eyes = [eyeDetection(leftEye, eyeBoxSize, bestScore), eyeDetection(rightEye, eyeBoxSize, bestScore)].sort(
    (a, b) => center(a)[0] - center(b)[0]
  );
  return { head, eyes, mouth: null };
}

export function parseRetinaFaceRawOutput(
  loc: ArrayLike<number>,
  confLogits: ArrayLike<number>,
  landms: ArrayLike<number>,
  scoreThreshold: number,
  targetWidth = CAMERA_WIDTH,
  targetHeight = CAMERA_HEIGHT
): DetectionResult {
  const threshold = Math.max(scoreThreshold, RETINAFACE_SCORE_THRESHOLD_FLOOR);
  const priors = getRetinaFacePriors();
  const candidateCount = Math.min(
    Math.floor(loc.length / 4),
    Math.floor(confLogits.length / 2),
    Math.floor(landms.length / 10),
    RETINAFACE_PRIOR_COUNT
  );
  let bestIndex = -1;
  let bestScore = -Infinity;
  for (let index = 0; index < candidateCount; index += 1) {
    const logitOffset = index * 2;
    const score = sigmoid(Number(confLogits[logitOffset + 1]) - Number(confLogits[logitOffset]));
    if (Number.isFinite(score) && score >= threshold && score > bestScore) {
      bestScore = score;
      bestIndex = index;
    }
  }
  if (bestIndex < 0) {
    return { head: null, eyes: [], mouth: null };
  }

  const priorOffset = bestIndex * 4;
  const locOffset = bestIndex * 4;
  const priorCx = priors[priorOffset];
  const priorCy = priors[priorOffset + 1];
  const priorW = priors[priorOffset + 2];
  const priorH = priors[priorOffset + 3];
  const cx = priorCx + Number(loc[locOffset]) * RETINAFACE_CENTER_VARIANCE * priorW;
  const cy = priorCy + Number(loc[locOffset + 1]) * RETINAFACE_CENTER_VARIANCE * priorH;
  const boxW = priorW * Math.exp(Number(loc[locOffset + 2]) * RETINAFACE_SIZE_VARIANCE);
  const boxH = priorH * Math.exp(Number(loc[locOffset + 3]) * RETINAFACE_SIZE_VARIANCE);
  const rawX1 = (cx - boxW * 0.5) * RETINAFACE_INPUT_WIDTH;
  const rawY1 = (cy - boxH * 0.5) * RETINAFACE_INPUT_HEIGHT;
  const rawX2 = (cx + boxW * 0.5) * RETINAFACE_INPUT_WIDTH;
  const rawY2 = (cy + boxH * 0.5) * RETINAFACE_INPUT_HEIGHT;
  if (![rawX1, rawY1, rawX2, rawY2].every(Number.isFinite)) {
    return { head: null, eyes: [], mouth: null };
  }

  const x1 = scaleRetinaFaceX(rawX1, targetWidth);
  const y1 = scaleRetinaFaceY(rawY1, targetHeight);
  const x2 = scaleRetinaFaceX(rawX2, targetWidth);
  const y2 = scaleRetinaFaceY(rawY2, targetHeight);
  if (x2 <= x1 || y2 <= y1) {
    return { head: null, eyes: [], mouth: null };
  }

  const landmOffset = bestIndex * 10;
  const rightEye = decodeLandmark(landms, landmOffset, priorCx, priorCy, priorW, priorH, targetWidth, targetHeight);
  const leftEye = decodeLandmark(landms, landmOffset + 2, priorCx, priorCy, priorW, priorH, targetWidth, targetHeight);
  if (!isFinitePoint(rightEye) || !isFinitePoint(leftEye)) {
    return { head: null, eyes: [], mouth: null };
  }

  const head: Detection = { classId: HEAD_CLASS_ID, score: bestScore, x1, y1, x2, y2 };
  const eyeBoxSize = Math.max(10, width(head) * 0.08);
  const eyes = [eyeDetection(leftEye, eyeBoxSize, bestScore), eyeDetection(rightEye, eyeBoxSize, bestScore)].sort(
    (a, b) => center(a)[0] - center(b)[0]
  );
  return { head, eyes, mouth: null };
}

function decodeLandmark(
  landms: ArrayLike<number>,
  offset: number,
  priorCx: number,
  priorCy: number,
  priorW: number,
  priorH: number,
  targetWidth: number,
  targetHeight: number
): [number, number] {
  return [
    scaleRetinaFaceX(
      (priorCx + Number(landms[offset]) * RETINAFACE_CENTER_VARIANCE * priorW) * RETINAFACE_INPUT_WIDTH,
      targetWidth
    ),
    scaleRetinaFaceY(
      (priorCy + Number(landms[offset + 1]) * RETINAFACE_CENTER_VARIANCE * priorH) * RETINAFACE_INPUT_HEIGHT,
      targetHeight
    )
  ];
}

function scaleRetinaFaceX(value: number, targetWidth: number): number {
  return clamp((value * targetWidth) / RETINAFACE_INPUT_WIDTH, 0, targetWidth - 1);
}

function scaleRetinaFaceY(value: number, targetHeight: number): number {
  return clamp((value * targetHeight) / RETINAFACE_INPUT_HEIGHT, 0, targetHeight - 1);
}

function sigmoid(value: number): number {
  return value >= 0 ? 1 / (1 + Math.exp(-value)) : Math.exp(value) / (1 + Math.exp(value));
}

function getRetinaFacePriors(): Float32Array {
  if (retinaFacePriors !== null) {
    return retinaFacePriors;
  }
  const priors = new Float32Array(RETINAFACE_PRIOR_COUNT * 4);
  const steps = [8, 16, 32];
  const minSizes = [
    [16, 32],
    [64, 128],
    [256, 512]
  ];
  let offset = 0;
  for (let level = 0; level < steps.length; level += 1) {
    const step = steps[level];
    const featureHeight = Math.ceil(RETINAFACE_INPUT_HEIGHT / step);
    const featureWidth = Math.ceil(RETINAFACE_INPUT_WIDTH / step);
    for (let y = 0; y < featureHeight; y += 1) {
      for (let x = 0; x < featureWidth; x += 1) {
        for (const minSize of minSizes[level]) {
          priors[offset] = ((x + 0.5) * step) / RETINAFACE_INPUT_WIDTH;
          priors[offset + 1] = ((y + 0.5) * step) / RETINAFACE_INPUT_HEIGHT;
          priors[offset + 2] = minSize / RETINAFACE_INPUT_WIDTH;
          priors[offset + 3] = minSize / RETINAFACE_INPUT_HEIGHT;
          offset += 4;
        }
      }
    }
  }
  retinaFacePriors = priors;
  return priors;
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
  for (let y = 0; y < GAZE_INPUT_SIZE; y += 1) {
    for (let x = 0; x < GAZE_INPUT_SIZE; x += 1) {
      const srcX = x * inverseScale + inverseTx;
      const srcY = y * inverseScale + inverseTy;
      const [r, g, b] = sampleRgb(frame, srcX, srcY);
      const dst = y * GAZE_INPUT_SIZE + x;
      input[dst] = r / 127.5 - 1;
      input[plane + dst] = g / 127.5 - 1;
      input[plane * 2 + dst] = b / 127.5 - 1;
    }
  }
  return { input, inverseScale, inverseTx, inverseTy };
}

export function createGazeInputNhwc(frame: ImageData, head: Detection, eyes: Detection[]): GazeCrop {
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
  const input = new Float32Array(1 * GAZE_INPUT_SIZE * GAZE_INPUT_SIZE * 3);
  for (let y = 0; y < GAZE_INPUT_SIZE; y += 1) {
    for (let x = 0; x < GAZE_INPUT_SIZE; x += 1) {
      const srcX = x * inverseScale + inverseTx;
      const srcY = y * inverseScale + inverseTy;
      const [r, g, b] = sampleRgb(frame, srcX, srcY);
      const dst = (y * GAZE_INPUT_SIZE + x) * 3;
      input[dst] = r / 127.5 - 1;
      input[dst + 1] = g / 127.5 - 1;
      input[dst + 2] = b / 127.5 - 1;
    }
  }
  return { input, inverseScale, inverseTx, inverseTy };
}

function sampleRgb(frame: ImageData, x: number, y: number): [number, number, number] {
  if (x < 0 || y < 0 || x > frame.width - 1 || y > frame.height - 1) {
    return [0, 0, 0];
  }
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const x1 = Math.min(frame.width - 1, x0 + 1);
  const y1 = Math.min(frame.height - 1, y0 + 1);
  const wx = x - x0;
  const wy = y - y0;
  const c00 = pixel(frame, x0, y0);
  const c10 = pixel(frame, x1, y0);
  const c01 = pixel(frame, x0, y1);
  const c11 = pixel(frame, x1, y1);
  return [0, 1, 2].map((channel) => {
    const top = c00[channel] * (1 - wx) + c10[channel] * wx;
    const bottom = c01[channel] * (1 - wx) + c11[channel] * wx;
    return top * (1 - wy) + bottom * wy;
  }) as [number, number, number];
}

function pixel(frame: ImageData, x: number, y: number): [number, number, number] {
  const offset = (y * frame.width + x) * 4;
  return [frame.data[offset], frame.data[offset + 1], frame.data[offset + 2]];
}

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
  const diameters = [leftMetrics.diameterPx, rightMetrics.diameterPx].filter(Number.isFinite);
  const disagreement = Math.max(Math.abs(leftYawDeg - rightYawDeg), Math.abs(leftPitchDeg - rightPitchDeg));
  return {
    yawDeg: (leftYawDeg + rightYawDeg) * 0.5,
    pitchDeg: (leftPitchDeg + rightPitchDeg) * 0.5,
    leftYawDeg,
    leftPitchDeg,
    rightYawDeg,
    rightPitchDeg,
    irisDiameterPx: diameters.length ? diameters.reduce((a, b) => a + b, 0) / diameters.length : 0,
    eyeOpen: clamp01(Math.min(leftMetrics.openRatio, rightMetrics.openRatio)),
    agreement: clamp01(1 - disagreement / 30),
    leftIrisPx: leftMetrics.contour,
    rightIrisPx: rightMetrics.contour,
    leftIrisCenterPx: contourCenter(leftMetrics.contour),
    rightIrisCenterPx: contourCenter(rightMetrics.contour),
    leftEyeballPx: [leftBall[1], leftBall[0]],
    rightEyeballPx: [rightBall[1], rightBall[0]],
    depthHealthy
  };
}

function eyeIrisMetrics(points: Float32Array, pointOffset: number): { diameterPx: number; openRatio: number; contour: [number, number][] } {
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
  return { diameterPx, openRatio: clamp01(openRatio), contour };
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
// white, so a light EMA on the per-eye angles removes most of it; real saccades
// move both eyes by far more than noise in a single frame, so a large
// frame-to-frame jump snaps the filter instead of smearing the saccade.
export class GazeAngleSmoother {
  private smoothed: [number, number, number, number] | null = null;

  constructor(
    readonly alpha = 0.35,
    readonly snapDeg = 12
  ) {}

  update(estimate: GazeEstimate): GazeEstimate {
    const raw: [number, number, number, number] = [
      estimate.leftYawDeg,
      estimate.leftPitchDeg,
      estimate.rightYawDeg,
      estimate.rightPitchDeg
    ];
    if (this.smoothed === null) {
      this.smoothed = raw;
    } else {
      let maxDelta = 0;
      for (let i = 0; i < 4; i += 1) {
        maxDelta = Math.max(maxDelta, Math.abs(raw[i] - this.smoothed[i]));
      }
      if (maxDelta > this.snapDeg) {
        this.smoothed = raw;
      } else {
        for (let i = 0; i < 4; i += 1) {
          this.smoothed[i] += this.alpha * (raw[i] - this.smoothed[i]);
        }
      }
    }
    const [leftYawDeg, leftPitchDeg, rightYawDeg, rightPitchDeg] = this.smoothed;
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
  }
}

// Velocity-threshold gaze filter inspired by Tobii's I-VT fixation
// classification: when angular gaze velocity is low the eye is fixating and the
// output should converge on the local mean (heavy smoothing removes sensor
// noise); above the saccade threshold the eye is genuinely moving and the
// output passes through with no lag. Fixation exit uses hysteresis and a
// minimum streak so a single noisy velocity spike cannot flap the state.
export class SaccadeAwareGazeFilter {
  private out: [number, number] | null = null;
  private lastAngles: [number, number] | null = null;
  private lastT = 0;
  private velocity = 0;
  private saccade = false;
  private belowExitStreak = 0;

  constructor(
    readonly enterDegS = 40,
    readonly exitDegS = 22,
    readonly exitSamples = 2,
    readonly fixAlpha = 0.15,
    readonly deadzone = 0.005,
    readonly velAlpha = 0.5,
    readonly maxFixationStep = 0.06
  ) {}

  update(x: number, y: number, tMs: number, yawDeg: number, pitchDeg: number): [number, number] {
    if (this.out === null || this.lastAngles === null || this.lastT === 0) {
      this.out = [x, y];
      this.lastAngles = [yawDeg, pitchDeg];
      this.lastT = tMs;
      return this.out;
    }
    const dt = Math.max((tMs - this.lastT) / 1000, 1e-3);
    const instantaneous = Math.hypot(yawDeg - this.lastAngles[0], pitchDeg - this.lastAngles[1]) / dt;
    this.velocity += this.velAlpha * (instantaneous - this.velocity);
    this.lastAngles = [yawDeg, pitchDeg];
    this.lastT = tMs;
    if (this.saccade) {
      if (this.velocity < this.exitDegS) {
        this.belowExitStreak += 1;
        if (this.belowExitStreak >= this.exitSamples) {
          this.saccade = false;
          this.belowExitStreak = 0;
        }
      } else {
        this.belowExitStreak = 0;
      }
      this.out = [x, y];
      return this.out;
    }
    if (this.velocity > this.enterDegS) {
      this.saccade = true;
      this.out = [x, y];
      return this.out;
    }
    if (Math.hypot(x - this.out[0], y - this.out[1]) < this.deadzone) {
      return this.out;
    }
    // Adaptive fixation smoothing: heavy only at true standstill, easing toward
    // pass-through as the smoothed velocity approaches the saccade threshold.
    // Slow scanning should glide, not crawl.
    const ratio = Math.min(1, this.velocity / this.enterDegS);
    const alpha = this.fixAlpha + (1 - this.fixAlpha) * ratio * ratio;
    const nx = this.out[0] + alpha * (x - this.out[0]);
    const ny = this.out[1] + alpha * (y - this.out[1]);
    const step = Math.hypot(nx - this.out[0], ny - this.out[1]);
    if (step > this.maxFixationStep) {
      const s = this.maxFixationStep / step;
      this.out = [this.out[0] + (nx - this.out[0]) * s, this.out[1] + (ny - this.out[1]) * s];
      return this.out;
    }
    this.out = [nx, ny];
    return this.out;
  }

  get velocityDegS(): number {
    return this.velocity;
  }

  get inSaccade(): boolean {
    return this.saccade;
  }

  reset(): void {
    this.out = null;
    this.lastAngles = null;
    this.lastT = 0;
    this.velocity = 0;
    this.saccade = false;
    this.belowExitStreak = 0;
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
let learnedBallVecNorm = 0;
export function resetBallVecBaseline(): void {
  learnedBallVecNorm = 0;
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
  const minHealthyNorm = Math.max(1e-6, irisDiameterPx * 0.6);
  const radius = learnedBallVecNorm > 0 ? learnedBallVecNorm : Math.max(1, irisDiameterPx * 2.7);
  let healthy = norm >= Math.max(minHealthyNorm, radius * 0.65);
  if (healthy) {
    learnedBallVecNorm =
      learnedBallVecNorm === 0 ? norm : learnedBallVecNorm + 0.05 * (norm - learnedBallVecNorm);
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
  readonly focalPx: number;
  focalScale = 1;
  readonly cameraWidth: number;
  readonly cameraHeight: number;

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
      this.eyePositionWeightX = clamp(weightX, 0, 1);
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
    const wx = weightX === undefined ? this.eyePositionWeightX : clamp(weightX, 0, 1);
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

export class Calibration {
  matrix: number[][] | null = null;
  rbf: RbfCorrection | null = null;
  geometry: CalibrationGeometry | null = null;
  sourceMin: [number, number] | null = null;
  sourceMax: [number, number] | null = null;
  featureMap: FeatureMap | null = null;
  featureRbf: RbfCorrection | null = null;
  readonly sourceMargin = 0.08;
  readonly samples: Array<[GazeFeature, [number, number]]> = [];
  readonly validation: Array<{ raw: [number, number]; target: [number, number]; error: number }> = [];
  private pending: PendingFit | null = null;
  private validationRetries = 0;
  private readonly maxValidationRetries = 3;
  readonly io: CalibrationIO;
  reprojector?: CalibrationReprojector;
  readonly fitCount: number;

  constructor(
    readonly path: string,
    readonly emit: (payload: BackendMessage) => void,
    io?: CalibrationIO,
    reprojector?: CalibrationReprojector,
    fitCount = CALIBRATION_SAMPLE_TARGET
  ) {
    this.io = io ?? {
      read: (filePath) => window.gazeBridge.readCalibration(filePath),
      write: (filePath, payload) => window.gazeBridge.writeCalibration(filePath, payload)
    };
    this.reprojector = reprojector;
    this.fitCount = fitCount;
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
      return;
    }
    try {
      const payload = JSON.parse(response.text) as CalibrationPayload;
      if (payload.raw_projection !== "unclipped-v1" && payload.raw_projection !== "unclipped-v2" && payload.raw_projection !== "featuremap-v3") {
        this.emit({ type: "status", level: "warning", message: "Old calibration uses clipped raw gaze; recalibrate before using it" });
        return;
      }
      const fmap = payload.feature_map;
      if (payload.raw_projection === "featuremap-v3" && fmap && Array.isArray(fmap.coeffs) && Array.isArray(fmap.mean) && Array.isArray(fmap.scale)) {
        this.featureMap = {
          coeffs: fmap.coeffs.map((row) => row.map(Number)),
          mean: fmap.mean.map(Number),
          scale: fmap.scale.map(Number)
        };
        const frbf = payload.feature_rbf;
        if (frbf && Array.isArray(frbf.centers) && Array.isArray(frbf.weights) && frbf.centers.length === frbf.weights.length && frbf.sigma > 0) {
          this.featureRbf = {
            centers: frbf.centers.map((c) => [Number(c[0]), Number(c[1])] as [number, number]),
            weights: frbf.weights.map((w) => [Number(w[0]), Number(w[1])] as [number, number]),
            sigma: Number(frbf.sigma)
          };
        }
      }
      if (Array.isArray(payload.affine) && payload.affine.length === 3 && payload.affine.every((row) => row.length === 2)) {
        this.matrix = payload.affine.map((row) => [Number(row[0]), Number(row[1])]);
        const rbf = payload.rbf;
        if (rbf && Array.isArray(rbf.centers) && Array.isArray(rbf.weights) && rbf.centers.length === rbf.weights.length && rbf.sigma > 0) {
          this.rbf = {
            centers: rbf.centers.map((c) => [Number(c[0]), Number(c[1])] as [number, number]),
            weights: rbf.weights.map((w) => [Number(w[0]), Number(w[1])] as [number, number]),
            sigma: Number(rbf.sigma)
          };
        }
        const geometry = payload.geometry;
        if (geometry && Number.isFinite(geometry.eye_position_weight_x) && Number.isFinite(geometry.eye_position_weight_y)) {
          this.geometry = {
            eye_position_weight_x: Number(geometry.eye_position_weight_x),
            eye_position_weight_y: Number(geometry.eye_position_weight_y)
          };
        }
        const bounds = payload.source_bounds;
        if (bounds?.min?.length === 2 && bounds.max?.length === 2) {
          this.sourceMin = [Number(bounds.min[0]), Number(bounds.min[1])];
          this.sourceMax = [Number(bounds.max[0]), Number(bounds.max[1])];
        }
        this.emit({ type: "status", level: "info", message: `Loaded calibration: ${this.path}` });
        if (this.geometry) {
          this.emit({ type: "calibration", status: "geometry", geometry: this.geometry });
        }
      }
    } catch (error) {
      this.emit({ type: "status", level: "warning", message: `Failed to load calibration: ${error}` });
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
    return this.map(raw, this.matrix, this.rbf, this.sourceMin, this.sourceMax);
  }

  // Preferred runtime path: direct feature→screen regression when the fit
  // chose it (learns model bias outright), falling back to the affine chain.
  applyFeature(feature: GazeFeature): [number, number] {
    if (this.featureMap !== null) {
      const pred = applyFeatureMap(this.featureMap, feature);
      let [x, y] = pred;
      if (this.featureRbf) {
        const [ox, oy] = rbfOffset(this.featureRbf, pred);
        x += ox;
        y += oy;
      }
      return [clamp01(x), clamp01(y)];
    }
    return this.apply(feature.point);
  }

  private fit(): void {
    const features = this.samples.map(([feature]) => feature);
    const targets = this.samples.map(([, target]) => target);
    const liveXs = features.map((feature) => feature.point[0]);
    const liveYs = features.map((feature) => feature.point[1]);
    if (Math.max(...liveXs) - Math.min(...liveXs) < 0.08 || Math.max(...liveYs) - Math.min(...liveYs) < 0.08) {
      this.rejectFit("Raw gaze does not separate calibration targets");
      return;
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
        this.rejectFit("Calibration geometry fit produced no valid candidate");
        return;
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
        this.rejectFit(error instanceof Error ? error.message : String(error));
        return;
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
    // map will actually run.
    let looFeature = Infinity;
    const featureMap = fitFeatureMap(features, targets);
    if (featureMap !== null && features.length >= 9) {
      const looAffine = looAffineError(best.raws, targets);
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
    const gateError = best.useFeatureMap ? looFeature : best.error;
    if (!Number.isFinite(gateError) || gateError > CALIBRATION_FIT_MAX_ERROR) {
      this.rejectFit(`Calibration fit error ${gateError.toFixed(3)} exceeds ${CALIBRATION_FIT_MAX_ERROR.toFixed(2)}`);
      return;
    }
    this.pending = best;
    console.info("Calibration fit complete", JSON.stringify({ maxError: Number(best.error.toFixed(4)), gateError: Number(gateError.toFixed(4)), geometry: best.geometry, samples: this.samples.length }));
  }

  async capture(feature: GazeFeature | null, target: [number, number]): Promise<void> {
    if (feature === null) {
      this.emit({ type: "calibration", status: "no_sample", message: "No gaze sample is available yet" });
      return;
    }
    this.samples.push([feature, target]);
    console.info("Calibration sample accepted", JSON.stringify({ count: this.samples.length, raw: feature.point, target }));
    this.emit({ type: "calibration", status: "sampled", count: this.samples.length });
    if (this.samples.length < this.fitCount) {
      return;
    }
    this.fit();
  }

  async validate(feature: GazeFeature | null, target: [number, number]): Promise<void> {
    if (feature === null || this.pending === null) {
      this.emit({ type: "calibration", status: "no_sample", message: "No fresh validation sample is available" });
      return;
    }
    const raw =
      this.pending.geometry && this.reprojector
        ? this.reprojector(feature, this.pending.geometry.eye_position_weight_x, this.pending.geometry.eye_position_weight_y)
        : feature.point;
    let estimate: [number, number];
    if (this.pending.useFeatureMap && this.pending.featureMap) {
      estimate = applyFeatureMap(this.pending.featureMap, feature);
      if (this.pending.featureRbf) {
        const [ox, oy] = rbfOffset(this.pending.featureRbf, estimate);
        estimate = [clamp01(estimate[0] + ox), clamp01(estimate[1] + oy)];
      }
    } else {
      estimate = this.map(raw, this.pending.matrix, this.pending.rbf, this.pending.sourceMin, this.pending.sourceMax);
    }
    const error = pointError(estimate, target);
    if (!Number.isFinite(error) || error > 0.18) {
      this.validationRetries += 1;
      console.warn("Calibration validation miss", JSON.stringify({ error: Number.isFinite(error) ? Number(error.toFixed(4)) : null, attempt: this.validationRetries }));
      if (this.validationRetries <= this.maxValidationRetries) {
        this.validation.length = 0;
        this.emit({
          type: "calibration",
          status: "validation_retry",
          message: `Validation error ${Number.isFinite(error) ? error.toFixed(3) : "n/a"} — hold still at the two check points again (${this.validationRetries}/${this.maxValidationRetries})`
        });
        return;
      }
      this.rejectFit(`Validation error ${error.toFixed(3)} exceeds 0.18 after ${this.maxValidationRetries} retries`);
      return;
    }
    this.validation.push({ raw, target, error });
    if (this.validation.length < 2) {
      this.emit({ type: "calibration", status: "sampled", count: this.fitCount + this.validation.length });
      return;
    }
    const pending = this.pending;
    const payload: CalibrationPayload = {
      raw_projection: pending.useFeatureMap ? "featuremap-v3" : "unclipped-v2",
      affine: pending.matrix,
      rbf: pending.rbf,
      feature_map: pending.useFeatureMap ? pending.featureMap : null,
      feature_rbf: pending.useFeatureMap ? pending.featureRbf : null,
      geometry: pending.geometry,
      source_bounds: { min: pending.sourceMin, max: pending.sourceMax, margin: this.sourceMargin },
      samples: pending.raws.map((rawPoint, index) => ({ raw: rawPoint, target: this.samples[index][1] })),
      validation: this.validation.slice()
    };
    const response = await this.io.write(this.path, payload);
    if (response.ok) {
      this.matrix = pending.matrix;
      this.rbf = pending.rbf;
      this.featureMap = pending.useFeatureMap ? pending.featureMap : null;
      this.featureRbf = pending.useFeatureMap ? pending.featureRbf : null;
      this.geometry = pending.geometry;
      this.sourceMin = pending.sourceMin;
      this.sourceMax = pending.sourceMax;
      this.pending = null;
      this.validationRetries = 0;
      console.info("Calibration saved", JSON.stringify({ path: response.path }));
      this.emit({ type: "calibration", status: "saved", path: response.path, geometry: this.geometry });
    } else {
      this.validation.pop();
      this.emit({ type: "calibration", status: "save_failed", message: `Failed to save calibration: ${response.error}` });
    }
  }

  private rejectFit(message: string): void {
    console.warn("Calibration fit rejected:", message);
    this.samples.length = 0;
    this.validation.length = 0;
    this.pending = null;
    this.validationRetries = 0;
    this.emit({ type: "calibration", status: "rejected_fit", message });
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

function rbfFit(raws: [number, number][], residuals: [number, number][], ridge = 1e-3): RbfCorrection | null {
  if (raws.length < 4) {
    return null;
  }
  const nearest: number[] = [];
  for (let i = 0; i < raws.length; i += 1) {
    let best = Infinity;
    for (let j = 0; j < raws.length; j += 1) {
      if (i === j) continue;
      best = Math.min(best, Math.hypot(raws[i][0] - raws[j][0], raws[i][1] - raws[j][1]));
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
  const kernel = raws.map((a, i) =>
    raws.map((b, j) => Math.exp(-((Math.hypot(a[0] - b[0], a[1] - b[1]) / sigma) ** 2)) + (i === j ? ridge : 0))
  );
  const weights = solveLinearSystem(kernel, residuals.map((r) => [r[0], r[1]]));
  if (weights === null || !weights.every((row) => row.every(Number.isFinite))) {
    return null;
  }
  return {
    centers: raws.map((r) => [r[0], r[1]] as [number, number]),
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

  accept(point: [number, number], at: number): [number, number] | null {
    if (!point.every(Number.isFinite)) return null;
    const previous = this.accepted;
    if (previous === null || at - previous.at > 1000 || pointError(point, previous.point) <= 0.35 ||
      (this.candidate !== null && at - this.candidate.at <= 500 && pointError(point, this.candidate.point) <= 0.12)) {
      this.accepted = { point, at };
      this.candidate = null;
      return point;
    }
    this.candidate = { point, at };
    return null;
  }
}

export function updateBlinkState(closed: boolean, eyeOpen: number): boolean {
  if (closed) {
    return !Number.isFinite(eyeOpen) || eyeOpen < BLINK_REOPEN_THRESHOLD;
  }
  return Number.isFinite(eyeOpen) && eyeOpen < BLINK_CLOSE_THRESHOLD;
}

export function isHeadTurned(eyeSpanPx: number, headWidthPx: number): boolean {
  return Number.isFinite(eyeSpanPx) && eyeSpanPx < Math.max(1, headWidthPx) * MIN_EYE_SPAN_RATIO;
}

export type TimedFeature = { feature: GazeFeature; at: number };

export function stableFeatureSample(samples: TimedFeature[], now: number): { feature: GazeFeature | null; reason?: string } {
  const recent = samples.filter(({ feature, at }) => now - at <= 900 && now - at >= 0 && feature.point.every(Number.isFinite));
  if (recent.length < 3) {
    return { feature: null, reason: "Need at least three fresh gaze frames" };
  }
  const median = (values: number[]) => {
    values.sort((a, b) => a - b);
    const middle = Math.floor(values.length / 2);
    return values.length % 2 === 0 ? (values[middle - 1] + values[middle]) * 0.5 : values[middle];
  };
  const point: [number, number] = [median(recent.map((entry) => entry.feature.point[0])), median(recent.map((entry) => entry.feature.point[1]))];
  const distances = recent.map((entry) => pointError(entry.feature.point, point));
  if (median(distances) > 0.06) {
    return { feature: null, reason: "Gaze is moving; hold still and retry" };
  }
  if (median(recent.map((entry) => entry.feature.eyeOpen)) < BLINK_OPEN_THRESHOLD) {
    return { feature: null, reason: "Eyes appear closed; keep them open" };
  }
  const med = (select: (feature: GazeFeature) => number) => median(recent.map((entry) => select(entry.feature)));
  const med2 = (select: (feature: GazeFeature) => [number, number]): [number, number] => [
    med((feature) => select(feature)[0]),
    med((feature) => select(feature)[1])
  ];
  return {
    feature: {
      point,
      eyeCenterPx: med2((feature) => feature.eyeCenterPx),
      leftEyePx: med2((feature) => feature.leftEyePx),
      rightEyePx: med2((feature) => feature.rightEyePx),
      leftYawDeg: med((feature) => feature.leftYawDeg),
      leftPitchDeg: med((feature) => feature.leftPitchDeg),
      rightYawDeg: med((feature) => feature.rightYawDeg),
      rightPitchDeg: med((feature) => feature.rightPitchDeg),
      headWidthPx: med((feature) => feature.headWidthPx),
      irisDiameterPx: med((feature) => feature.irisDiameterPx),
      eyeOpen: med((feature) => feature.eyeOpen),
      distanceM: med((feature) => feature.distanceM)
    }
  };
}

export interface FeatureMap {
  coeffs: number[][];
  mean: number[];
  scale: number[];
}

// Direct feature→screen regression: bypasses the projection chain's
// compounded approximations (FOV, distance, display size, tan) and learns the
// model's systematic bias per user. Quadratic-ish basis over both eyes' angles
// + head position + iris-distance proxy.
export function gazeFeatureVector(f: GazeFeature): number[] {
  const yawM = (f.leftYawDeg + f.rightYawDeg) * 0.5;
  const pitchM = (f.leftPitchDeg + f.rightPitchDeg) * 0.5;
  const yawD = f.leftYawDeg - f.rightYawDeg;
  const pitchD = f.leftPitchDeg - f.rightPitchDeg;
  const ecx = f.eyeCenterPx[0] / CAMERA_WIDTH;
  const ecy = f.eyeCenterPx[1] / CAMERA_HEIGHT;
  const iris = (f.irisDiameterPx || 18) / 18;
  const y = yawM / 30;
  const p = pitchM / 30;
  return [1, y, p, y * y, p * p, y * p, yawD / 30, pitchD / 30, ecx, ecy, ecx * ecx, ecy * ecy, ecx * ecy, iris, y * ecx, p * ecy];
}

function fitFeatureMap(features: GazeFeature[], targets: [number, number][], ridgeLambda = 1e-2): FeatureMap | null {
  const n = features.length;
  const k = gazeFeatureVector(features[0]).length;
  if (n < k - 6) {
    return null;
  }
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
  const coeffs = solveLinearSystem(ata, atb);
  if (coeffs === null || !coeffs.every((row) => row.every(Number.isFinite))) {
    return null;
  }
  return { coeffs, mean, scale };
}

export function applyFeatureMap(map: FeatureMap, f: GazeFeature): [number, number] {
  const v = gazeFeatureVector(f);
  let x = 0;
  let y = 0;
  for (let j = 0; j < map.coeffs.length; j += 1) {
    const z = j === 0 ? 1 : (v[j] - map.mean[j]) / map.scale[j];
    x += z * map.coeffs[j][0];
    y += z * map.coeffs[j][1];
  }
  return [x, y];
}

// Leave-one-out error for the affine map over the fitted raw points.
function looAffineError(raws: [number, number][], targets: [number, number][]): number {
  if (raws.length < 4) {
    return Infinity;
  }
  let sum = 0;
  let count = 0;
  for (let i = 0; i < raws.length; i += 1) {
    const keptRaws = raws.filter((_, j) => j !== i);
    const keptTargets = targets.filter((_, j) => j !== i);
    try {
      const m = solveAffine(keptRaws.map((r, j) => [r, keptTargets[j]]));
      sum += pointError(applyMatrix(m, raws[i]), targets[i]);
      count += 1;
    } catch {
      // degenerate fold — skip
    }
  }
  return count > 0 ? sum / count : Infinity;
}

// Leave-one-out error for feature-space ridge regression.
function looFeatureError(features: GazeFeature[], targets: [number, number][]): number {
  if (features.length < 5) {
    return Infinity;
  }
  let sum = 0;
  let count = 0;
  for (let i = 0; i < features.length; i += 1) {
    const keptF = features.filter((_, j) => j !== i);
    const keptT = targets.filter((_, j) => j !== i);
    const fm = fitFeatureMap(keptF, keptT);
    if (fm === null) {
      continue;
    }
    sum += pointError(applyFeatureMap(fm, features[i]), targets[i]);
    count += 1;
  }
  return count > 0 ? sum / count : Infinity;
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
