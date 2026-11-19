import type { Detection, DetectionResult, GazeEstimate } from "./core";

// MediaPipe Face Landmarker (Apache-2.0) as the gaze front end: one model
// call per frame yields 478 landmarks (468 face + 2×5 iris), the facial
// transformation matrix and 52 blendshapes. This module turns that output
// into the DetectionResult + GazeEstimate shapes the existing calibration,
// filters and projector already consume — pure functions, no runtime state.

// Face-oval bbox → head width. The oval spans the cheekbones (~14 cm); the
// distance fallback models a 16 cm head (AVERAGE_HEAD_WIDTH_M).
export const MEDIAPIPE_HEAD_FACE_RATIO = 1.15;

export function headFaceWidthRatio(config: { detector: string; retinafaceHeadFaceRatio: number }): number {
  return config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : config.detector === "mediapipe" ? MEDIAPIPE_HEAD_FACE_RATIO : 1;
}

// Palpebral fissure width (~29 mm) over the iris rotation radius (~10.5 mm):
// converts an iris offset in eye widths into sin(eye-in-head angle). The
// per-user calibration map absorbs the individual gain error.
const EYE_GAIN = 2.8;
// Blendshape priors (degrees at score 1) and their weight against geometry.
const BLEND_YAW_DEG = 30;
const BLEND_PITCH_DEG = 25;
const BLEND_YAW_WEIGHT = 0.3;
const BLEND_PITCH_WEIGHT = 0.5;

export interface FaceLandmark {
  x: number;
  y: number;
  z: number;
}

export interface MediaPipeFace {
  landmarks: FaceLandmark[];
  matrix?: ArrayLike<number>;
  blendshapes?: Record<string, number>;
}

interface EyeIndices {
  outer: number;
  inner: number;
  upper: number;
  lower: number;
  contour: number[];
}

const EYES: EyeIndices[] = [
  { outer: 33, inner: 133, upper: 159, lower: 145, contour: [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246] },
  { outer: 263, inner: 362, upper: 386, lower: 374, contour: [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466] }
];
const IRISES = [
  { center: 468, contour: [469, 470, 471, 472] },
  { center: 473, contour: [474, 475, 476, 477] }
];
// Rigid skull points for the metric head-pose fit: eye corners, nose bridge
// and tip, forehead, cheek edges. No lips, jaw, brows or iris — those move.
export const MEDIAPIPE_POSE_SUBSET = [33, 133, 362, 263, 168, 6, 197, 195, 5, 4, 1, 10, 151, 9, 8, 234, 454, 127, 356, 93, 323];
const NOSE_TIP = 1;
const UPPER_INNER_LIP = 13;
const LOWER_INNER_LIP = 14;
export const MEDIAPIPE_LANDMARK_COUNT = 478;

type Vec3 = [number, number, number];
type Mat3 = [Vec3, Vec3, Vec3];

interface FaceLandmarkerOutput {
  faceLandmarks?: FaceLandmark[][];
  facialTransformationMatrixes?: Array<{ data: ArrayLike<number> }>;
  faceBlendshapes?: Array<{ categories: Array<{ categoryName: string; score: number }> }>;
}

export function faceFromLandmarkerResult(result: FaceLandmarkerOutput): MediaPipeFace | null {
  const landmarks = result.faceLandmarks?.[0];
  if (!landmarks || landmarks.length < MEDIAPIPE_LANDMARK_COUNT) {
    return null;
  }
  const categories = result.faceBlendshapes?.[0]?.categories;
  let blendshapes: Record<string, number> | undefined;
  if (categories && categories.length > 0) {
    blendshapes = {};
    for (const category of categories) {
      blendshapes[category.categoryName] = category.score;
    }
  }
  return { landmarks, matrix: result.facialTransformationMatrixes?.[0]?.data, blendshapes };
}

function px(face: MediaPipeFace, index: number, w: number, h: number): Vec3 {
  const p = face.landmarks[index];
  return [p.x * w, p.y * h, p.z * w];
}

function bbox(points: Vec3[]): { x1: number; y1: number; x2: number; y2: number } {
  let x1 = Infinity;
  let y1 = Infinity;
  let x2 = -Infinity;
  let y2 = -Infinity;
  for (const [x, y] of points) {
    x1 = Math.min(x1, x);
    y1 = Math.min(y1, y);
    x2 = Math.max(x2, x);
    y2 = Math.max(y2, y);
  }
  return { x1, y1, x2, y2 };
}

// The landmarker reports the canonical-face → camera transform in OpenGL
// axes (y up, z toward the viewer), flattened column-major by default. The
// layout is detected from where the large translation sits, then converted
// to the tracker's camera axes (x = image right, y = image down, z = into
// the scene) as S·R·S with S = diag(1, -1, -1); columns are renormalized so
// any uniform scale in the transform drops out.
export function headRotation(matrix: ArrayLike<number> | undefined): Mat3 {
  const identity: Mat3 = [
    [1, 0, 0],
    [0, 1, 0],
    [0, 0, 1]
  ];
  if (!matrix || matrix.length < 16) {
    return identity;
  }
  const columnMajor = Math.abs(matrix[14]) >= Math.abs(matrix[11]);
  const at = (r: number, c: number): number => Number(columnMajor ? matrix[c * 4 + r] : matrix[r * 4 + c]);
  const sign = [1, -1, -1];
  const rot: Mat3 = [
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0]
  ];
  for (let c = 0; c < 3; c += 1) {
    const norm = Math.hypot(at(0, c), at(1, c), at(2, c));
    if (!Number.isFinite(norm) || norm < 1e-9) {
      return identity;
    }
    for (let r = 0; r < 3; r += 1) {
      rot[r][c] = (sign[r] * sign[c] * at(r, c)) / norm;
    }
  }
  return rot;
}

function apply(rot: Mat3, v: Vec3): Vec3 {
  return [
    rot[0][0] * v[0] + rot[0][1] * v[1] + rot[0][2] * v[2],
    rot[1][0] * v[0] + rot[1][1] * v[1] + rot[1][2] * v[2],
    rot[2][0] * v[0] + rot[2][1] * v[1] + rot[2][2] * v[2]
  ];
}

function applyTransposed(rot: Mat3, v: Vec3): Vec3 {
  return [
    rot[0][0] * v[0] + rot[1][0] * v[1] + rot[2][0] * v[2],
    rot[0][1] * v[0] + rot[1][1] * v[1] + rot[2][1] * v[2],
    rot[0][2] * v[0] + rot[1][2] * v[1] + rot[2][2] * v[2]
  ];
}

// Camera-frame gaze vector → the tracker's angle convention: yaw > 0 looks
// toward image right, pitch > 0 looks up (matches the legacy mesh decoder).
export function gazeAnglesDeg(g: Vec3): [number, number] {
  const toward = -g[2];
  const yaw = Math.atan2(g[0], toward);
  const pitch = Math.atan2(-g[1], Math.hypot(g[0], toward));
  return [(yaw * 180) / Math.PI, (pitch * 180) / Math.PI];
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function clampSin(value: number): number {
  return Math.min(0.95, Math.max(-0.95, value));
}

interface EyeMeasurement {
  cornerMid: Vec3;
  box: Detection;
  irisCenter: [number, number];
  irisContour: [number, number][];
  irisDiameterPx: number;
  yawDeg: number;
  pitchDeg: number;
  apertureRatio: number;
  meshOffset: [number, number];
  ellipseRatio: number;
  ellipseAngle: [number, number];
}

function measureEye(
  face: MediaPipeFace,
  eye: EyeIndices,
  iris: { center: number; contour: number[] },
  rot: Mat3,
  blend: { yawDeg: number; pitchDeg: number } | null,
  w: number,
  h: number
): EyeMeasurement {
  const outer = px(face, eye.outer, w, h);
  const inner = px(face, eye.inner, w, h);
  const cornerMid: Vec3 = [(outer[0] + inner[0]) / 2, (outer[1] + inner[1]) / 2, (outer[2] + inner[2]) / 2];
  const eyeWidth = Math.max(1e-6, Math.hypot(outer[0] - inner[0], outer[1] - inner[1], outer[2] - inner[2]));
  const center = px(face, iris.center, w, h);
  // Iris offset from the corner midpoint, de-rotated into the head frame and
  // normalized by eye width: the eye-in-head rotation, scale-free.
  const inHead = applyTransposed(rot, [center[0] - cornerMid[0], center[1] - cornerMid[1], center[2] - cornerMid[2]]);
  const geomYaw = (Math.asin(clampSin((EYE_GAIN * inHead[0]) / eyeWidth)) * 180) / Math.PI;
  const geomPitch = (Math.asin(clampSin((-EYE_GAIN * inHead[1]) / eyeWidth)) * 180) / Math.PI;
  const eyeYaw = blend ? (1 - BLEND_YAW_WEIGHT) * geomYaw + BLEND_YAW_WEIGHT * blend.yawDeg : geomYaw;
  const eyePitch = blend ? (1 - BLEND_PITCH_WEIGHT) * geomPitch + BLEND_PITCH_WEIGHT * blend.pitchDeg : geomPitch;
  const yr = (eyeYaw * Math.PI) / 180;
  const pr = (eyePitch * Math.PI) / 180;
  // Head-frame gaze (forward is -z, toward the camera) rotated into camera
  // space: gaze = head pose ∘ eye-in-head.
  const gaze = apply(rot, [Math.sin(yr) * Math.cos(pr), -Math.sin(pr), -Math.cos(yr) * Math.cos(pr)]);
  const [yawDeg, pitchDeg] = gazeAnglesDeg(gaze);

  const contour3 = iris.contour.map((index) => px(face, index, w, h));
  const irisContour = contour3.map(([x, y]) => [x, y] as [number, number]);
  const irisDiameterPx =
    (Math.hypot(irisContour[0][0] - irisContour[2][0], irisContour[0][1] - irisContour[2][1]) +
      Math.hypot(irisContour[1][0] - irisContour[3][0], irisContour[1][1] - irisContour[3][1])) /
    2;
  const eyeBox = bbox(eye.contour.map((index) => px(face, index, w, h)));
  const boxW = Math.max(1e-6, eyeBox.x2 - eyeBox.x1);
  const boxH = Math.max(1e-6, eyeBox.y2 - eyeBox.y1);
  const upper = px(face, eye.upper, w, h);
  const lower = px(face, eye.lower, w, h);
  let meanX = 0;
  let meanY = 0;
  for (const [x, y] of irisContour) {
    meanX += x / irisContour.length;
    meanY += y / irisContour.length;
  }
  let varX = 0;
  let varY = 0;
  let covXY = 0;
  for (const [x, y] of irisContour) {
    varX += (x - meanX) ** 2;
    varY += (y - meanY) ** 2;
    covXY += (x - meanX) * (y - meanY);
  }
  const trace = varX + varY;
  const disc = Math.sqrt(Math.max(0, (trace * trace) / 4 - (varX * varY - covXY * covXY)));
  const major = trace / 2 + disc;
  const minor = trace / 2 - disc;
  const angle = 0.5 * Math.atan2(2 * covXY, varX - varY);
  return {
    cornerMid,
    box: { classId: 17, score: 1, ...eyeBox },
    irisCenter: [center[0], center[1]],
    irisContour,
    irisDiameterPx,
    yawDeg,
    pitchDeg,
    apertureRatio: irisDiameterPx > 1e-6 ? Math.hypot(upper[0] - lower[0], upper[1] - lower[1]) / irisDiameterPx : 0,
    meshOffset: [(center[0] - (eyeBox.x1 + eyeBox.x2) / 2) / (boxW / 2), (center[1] - (eyeBox.y1 + eyeBox.y2) / 2) / (boxH / 2)],
    ellipseRatio: major > 1e-12 ? clamp01(Math.sqrt(Math.max(0, minor / major))) : 0,
    ellipseAngle: [Math.sin(2 * angle), Math.cos(2 * angle)]
  };
}

// The model's eyeLook* blendshapes, folded into one binocular prior. ARKit
// naming: "Left" is the subject's left eye, which looks toward image right
// when it looks "out" — so out-left and in-right both read as +yaw.
function blendPrior(blendshapes: Record<string, number> | undefined): { yawDeg: number; pitchDeg: number } | null {
  if (!blendshapes) {
    return null;
  }
  const b = (name: string): number => blendshapes[name] ?? 0;
  const yaw = (b("eyeLookOutLeft") + b("eyeLookInRight") - b("eyeLookInLeft") - b("eyeLookOutRight")) / 2;
  const pitch = (b("eyeLookUpLeft") + b("eyeLookUpRight") - b("eyeLookDownLeft") - b("eyeLookDownRight")) / 2;
  return { yawDeg: yaw * BLEND_YAW_DEG, pitchDeg: pitch * BLEND_PITCH_DEG };
}

// Openness on the tracker's 0..1 scale (EyeValidity enters at 0.55, closes
// below 0.28). Lids follow a downward gaze, which lifts eyeBlink without a
// blink, so half of eyeLookDown is credited back. Without blendshapes the
// lid gap over eye width stands in (~0.3 open, ~0.05 shut).
function eyeOpenness(face: MediaPipeFace, eyes: EyeMeasurement[], w: number, h: number): number {
  const bs = face.blendshapes;
  if (bs) {
    const side = (suffix: "Left" | "Right"): number =>
      clamp01(1 - (bs[`eyeBlink${suffix}`] ?? 0) + 0.5 * (bs[`eyeLookDown${suffix}`] ?? 0));
    return Math.min(side("Left"), side("Right"));
  }
  let open = 1;
  for (const eye of EYES) {
    const upper = px(face, eye.upper, w, h);
    const lower = px(face, eye.lower, w, h);
    const outer = px(face, eye.outer, w, h);
    const inner = px(face, eye.inner, w, h);
    const ratio = Math.hypot(upper[0] - lower[0], upper[1] - lower[1]) / Math.max(1e-6, Math.hypot(outer[0] - inner[0], outer[1] - inner[1]));
    open = Math.min(open, clamp01(ratio / 0.25));
  }
  return eyes.length ? open : 0;
}

export interface MediaPipeFrameResult {
  detection: DetectionResult;
  estimate: GazeEstimate;
}

// One landmarker result → detector boxes + gaze estimate. Eyes come back in
// image order (eyes[0] is image-left), each iris paired with the eye whose
// corner midpoint it sits nearest — robust to the model's left/right naming.
export function mediapipeFrame(face: MediaPipeFace, w: number, h: number): MediaPipeFrameResult {
  const rot = headRotation(face.matrix);
  const blend = blendPrior(face.blendshapes);
  const mids = EYES.map((eye) => {
    const a = px(face, eye.outer, w, h);
    const b = px(face, eye.inner, w, h);
    return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
  });
  const irisCenters = IRISES.map((iris) => px(face, iris.center, w, h));
  const direct =
    Math.hypot(irisCenters[0][0] - mids[0][0], irisCenters[0][1] - mids[0][1]) +
    Math.hypot(irisCenters[1][0] - mids[1][0], irisCenters[1][1] - mids[1][1]);
  const swapped =
    Math.hypot(irisCenters[1][0] - mids[0][0], irisCenters[1][1] - mids[0][1]) +
    Math.hypot(irisCenters[0][0] - mids[1][0], irisCenters[0][1] - mids[1][1]);
  const irisFor = direct <= swapped ? [IRISES[0], IRISES[1]] : [IRISES[1], IRISES[0]];
  const measured = EYES.map((eye, i) => measureEye(face, eye, irisFor[i], rot, blend, w, h)).sort(
    (a, b) => a.cornerMid[0] - b.cornerMid[0]
  );
  const [left, right] = measured;
  const head = bbox(face.landmarks.slice(0, 468).map((p) => [p.x * w, p.y * h, p.z * w] as Vec3));
  const nose = px(face, NOSE_TIP, w, h);
  const upperLip = px(face, UPPER_INNER_LIP, w, h);
  const lowerLip = px(face, LOWER_INNER_LIP, w, h);
  const posePoints = new Float32Array(MEDIAPIPE_POSE_SUBSET.length * 3);
  MEDIAPIPE_POSE_SUBSET.forEach((index, k) => {
    const p = px(face, index, w, h);
    posePoints[k * 3] = p[0];
    posePoints[k * 3 + 1] = p[1];
    posePoints[k * 3 + 2] = p[2];
  });
  const disagreement = Math.max(Math.abs(left.yawDeg - right.yawDeg), Math.abs(left.pitchDeg - right.pitchDeg));
  const diameters = [left.irisDiameterPx, right.irisDiameterPx].filter((d) => Number.isFinite(d) && d > 0);
  return {
    detection: {
      head: { classId: 7, score: 1, ...head },
      eyes: [left.box, right.box],
      mouth: null,
      nose: [nose[0], nose[1]],
      mouthCenter: [(upperLip[0] + lowerLip[0]) / 2, (upperLip[1] + lowerLip[1]) / 2]
    },
    estimate: {
      yawDeg: (left.yawDeg + right.yawDeg) / 2,
      pitchDeg: (left.pitchDeg + right.pitchDeg) / 2,
      leftYawDeg: left.yawDeg,
      leftPitchDeg: left.pitchDeg,
      rightYawDeg: right.yawDeg,
      rightPitchDeg: right.pitchDeg,
      irisDiameterPx: diameters.length ? diameters.reduce((a, b) => a + b, 0) / diameters.length : 0,
      eyeOpen: eyeOpenness(face, measured, w, h),
      agreement: clamp01(1 - disagreement / 30),
      leftIrisPx: left.irisContour,
      rightIrisPx: right.irisContour,
      leftIrisCenterPx: left.irisCenter,
      rightIrisCenterPx: right.irisCenter,
      depthHealthy: true,
      leftEllipseEcc: left.ellipseRatio,
      rightEllipseEcc: right.ellipseRatio,
      leftEllipseAngle: left.ellipseAngle,
      rightEllipseAngle: right.ellipseAngle,
      leftApertureRatio: left.apertureRatio,
      rightApertureRatio: right.apertureRatio,
      leftMeshOffset: left.meshOffset,
      rightMeshOffset: right.meshOffset,
      headPosePoints: posePoints
    }
  };
}
