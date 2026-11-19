import { describe, expect, it } from "vitest";
import { faceFromLandmarkerResult, gazeAnglesDeg, headRotation, mediapipeFrame, type FaceLandmark, type MediaPipeFace } from "./mediapipe";

const W = 640;
const H = 480;
const CX = 320;
const CY = 240;

interface SyntheticOptions {
  irisShift?: [number, number];
  headYawDeg?: number;
  swapIrisGroups?: boolean;
  rowMajor?: boolean;
  blendshapes?: Record<string, number>;
}

// A schematic 478-point face in pixel space: an oval of filler points, two
// eyes (corners, lids, 16-point contours) and two 5-point irises. Rotations
// are applied in the tracker's camera axes and mirrored into the GL matrix
// the landmarker would report.
function syntheticFace(options: SyntheticOptions = {}): MediaPipeFace {
  const pts: [number, number, number][] = [];
  for (let i = 0; i < 478; i += 1) {
    const t = (i / 478) * Math.PI * 2;
    pts.push([CX + 70 * Math.cos(t), CY + 90 * Math.sin(t), 0]);
  }
  const eye = (outer: number, inner: number, upper: number, lower: number, contour: number[], outerX: number, innerX: number) => {
    const y = CY - 20;
    const mid = (outerX + innerX) / 2;
    const half = Math.abs(outerX - innerX) / 2;
    contour.forEach((index, k) => {
      const t = (k / contour.length) * Math.PI * 2;
      pts[index] = [mid + half * Math.cos(t), y + 6 * Math.sin(t), 0];
    });
    pts[outer] = [outerX, y, 0];
    pts[inner] = [innerX, y, 0];
    pts[upper] = [mid, y - 6, 0];
    pts[lower] = [mid, y + 6, 0];
    return [mid, y] as [number, number];
  };
  const a = eye(33, 133, 159, 145, [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246], CX - 55, CX - 20);
  const b = eye(263, 362, 386, 374, [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466], CX + 55, CX + 20);
  const [sx, sy] = options.irisShift ?? [0, 0];
  const iris = (center: number, at: [number, number]) => {
    const c: [number, number, number] = [at[0] + sx, at[1] + sy, 0];
    pts[center] = c;
    pts[center + 1] = [c[0] + 6, c[1], 0];
    pts[center + 2] = [c[0], c[1] - 6, 0];
    pts[center + 3] = [c[0] - 6, c[1], 0];
    pts[center + 4] = [c[0], c[1] + 6, 0];
  };
  iris(options.swapIrisGroups ? 473 : 468, a);
  iris(options.swapIrisGroups ? 468 : 473, b);
  const yaw = ((options.headYawDeg ?? 0) * Math.PI) / 180;
  const c = Math.cos(yaw);
  const s = Math.sin(yaw);
  const rotated = pts.map(([x, y, z]) => {
    const dx = x - CX;
    const dz = z;
    return [CX + c * dx - s * dz, y, s * dx + c * dz] as [number, number, number];
  });
  const landmarks: FaceLandmark[] = rotated.map(([x, y, z]) => ({ x: x / W, y: y / H, z: z / W }));
  // GL rotation = S·R·S, S = diag(1,-1,-1); translation 50 cm in front.
  const gl = [
    [c, 0, s],
    [0, 1, 0],
    [-s, 0, c]
  ];
  const t = [0, 0, -50];
  const matrix: number[] = [];
  if (options.rowMajor) {
    for (let r = 0; r < 4; r += 1) for (let col = 0; col < 4; col += 1) matrix.push(r < 3 ? (col < 3 ? gl[r][col] : t[r]) : col === 3 ? 1 : 0);
  } else {
    for (let col = 0; col < 4; col += 1) for (let r = 0; r < 4; r += 1) matrix.push(r < 3 ? (col < 3 ? gl[r][col] : t[r]) : col === 3 ? 1 : 0);
  }
  return { landmarks, matrix, blendshapes: options.blendshapes };
}

describe("mediapipe gaze front end", () => {
  it("reads a frontal face with centered irises as straight ahead", () => {
    const { detection, estimate } = mediapipeFrame(syntheticFace(), W, H);
    expect(Math.abs(estimate.yawDeg)).toBeLessThan(0.5);
    expect(Math.abs(estimate.pitchDeg)).toBeLessThan(0.5);
    expect(estimate.irisDiameterPx).toBeCloseTo(12, 5);
    expect(estimate.agreement).toBeCloseTo(1, 5);
    expect(detection.eyes).toHaveLength(2);
    const eyeX = detection.eyes.map((e) => (e.x1 + e.x2) / 2);
    expect(eyeX[0]).toBeLessThan(eyeX[1]);
    expect(estimate.leftIrisCenterPx?.[0]).toBeLessThan(CX);
    const head = detection.head!;
    for (const e of detection.eyes) {
      expect(e.x1).toBeGreaterThanOrEqual(head.x1);
      expect(e.x2).toBeLessThanOrEqual(head.x2);
    }
    expect(detection.mouthCenter).toBeDefined();
    expect(estimate.headPosePoints?.length).toBe(21 * 3);
  });

  it("turns an iris shift toward image right into positive yaw on both eyes", () => {
    const { estimate } = mediapipeFrame(syntheticFace({ irisShift: [3, 0] }), W, H);
    const expected = (Math.asin((2.8 * 3) / 35) * 180) / Math.PI;
    expect(estimate.leftYawDeg).toBeCloseTo(expected, 3);
    expect(estimate.rightYawDeg).toBeCloseTo(expected, 3);
    expect(Math.abs(estimate.pitchDeg)).toBeLessThan(0.5);
  });

  it("turns an iris shift up the image into positive pitch", () => {
    const { estimate } = mediapipeFrame(syntheticFace({ irisShift: [0, -2] }), W, H);
    expect(estimate.pitchDeg).toBeGreaterThan(5);
    expect(Math.abs(estimate.yawDeg)).toBeLessThan(0.5);
  });

  it("carries head yaw into the gaze when the eyes stay centered in the head", () => {
    const { estimate } = mediapipeFrame(syntheticFace({ headYawDeg: 20 }), W, H);
    expect(estimate.yawDeg).toBeCloseTo(20, 1);
    expect(Math.abs(estimate.pitchDeg)).toBeLessThan(0.5);
  });

  it("reads row-major and column-major matrices the same way", () => {
    const col = mediapipeFrame(syntheticFace({ headYawDeg: -15, irisShift: [2, 1] }), W, H).estimate;
    const row = mediapipeFrame(syntheticFace({ headYawDeg: -15, irisShift: [2, 1], rowMajor: true }), W, H).estimate;
    expect(row.yawDeg).toBeCloseTo(col.yawDeg, 6);
    expect(row.pitchDeg).toBeCloseTo(col.pitchDeg, 6);
  });

  it("pairs each iris with its nearest eye whatever the index groups are", () => {
    const direct = mediapipeFrame(syntheticFace({ irisShift: [2, 0] }), W, H).estimate;
    const swapped = mediapipeFrame(syntheticFace({ irisShift: [2, 0], swapIrisGroups: true }), W, H).estimate;
    expect(swapped.leftYawDeg).toBeCloseTo(direct.leftYawDeg, 6);
    expect(swapped.leftIrisCenterPx).toEqual(direct.leftIrisCenterPx);
  });

  it("maps blink and look-down blendshapes onto the eye-validity scale", () => {
    const closed = mediapipeFrame(syntheticFace({ blendshapes: { eyeBlinkLeft: 0.95, eyeBlinkRight: 0.9 } }), W, H).estimate;
    expect(closed.eyeOpen).toBeLessThan(0.28);
    const lookingDown = mediapipeFrame(
      syntheticFace({ blendshapes: { eyeBlinkLeft: 0.45, eyeBlinkRight: 0.45, eyeLookDownLeft: 0.6, eyeLookDownRight: 0.6 } }),
      W,
      H
    ).estimate;
    expect(lookingDown.eyeOpen).toBeGreaterThanOrEqual(0.55);
    expect(lookingDown.pitchDeg).toBeLessThan(0);
  });

  it("folds eyeLook blendshapes into yaw with the subject-left = image-right convention", () => {
    const { estimate } = mediapipeFrame(syntheticFace({ blendshapes: { eyeLookOutLeft: 0.5, eyeLookInRight: 0.5 } }), W, H);
    expect(estimate.yawDeg).toBeGreaterThan(2);
  });

  it("parses landmarker output and rejects frames without a face", () => {
    expect(faceFromLandmarkerResult({ faceLandmarks: [] })).toBeNull();
    const face = syntheticFace();
    const parsed = faceFromLandmarkerResult({
      faceLandmarks: [face.landmarks],
      facialTransformationMatrixes: [{ data: face.matrix! }],
      faceBlendshapes: [{ categories: [{ categoryName: "eyeBlinkLeft", score: 0.2 }] }]
    });
    expect(parsed?.blendshapes).toEqual({ eyeBlinkLeft: 0.2 });
    expect(parsed?.matrix).toBe(face.matrix);
  });

  it("falls back to identity for a missing or degenerate matrix", () => {
    expect(headRotation(undefined)).toEqual([
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1]
    ]);
    expect(headRotation(new Array(16).fill(0))[0][0]).toBe(1);
    const [yaw, pitch] = gazeAnglesDeg([0, 0, -1]);
    expect(yaw).toBeCloseTo(0, 9);
    expect(pitch).toBeCloseTo(0, 9);
  });
});
