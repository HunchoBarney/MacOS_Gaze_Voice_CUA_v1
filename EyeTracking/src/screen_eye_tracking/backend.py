from __future__ import annotations

import argparse
import base64
import json
import math
import queue
import re
import statistics
import sys
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np
import onnxruntime as ort


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RETINAFACE_MODEL = REPO_ROOT / "public" / "models" / "retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx"
DEFAULT_YOLO_MODEL = REPO_ROOT / "public" / "models" / "yolomit_t_wholebody28_1x3x480x640.onnx"
DEFAULT_GAZE_MODEL = REPO_ROOT / "public" / "models" / "gaze_Nx3x160x160.onnx"
DEFAULT_LIP_MOTION_MODEL = REPO_ROOT / "public" / "models" / "vsdlm_l.onnx"
DEFAULT_CALIBRATION_FILE = REPO_ROOT / ".gaze_calibration.json"

HEAD_CLASS_ID = 7
EYE_CLASS_ID = 17
MOUTH_CLASS_ID = 19
AVERAGE_HEAD_WIDTH_M = 0.16
RETINAFACE_HEAD_FACE_WIDTH_RATIO = 1.545
CAMERA_WIDTH = 640
CAMERA_HEIGHT = 480
CAMERA_HORIZONTAL_FOV_DEG = 90.0
GAZE_INPUT_SIZE = 160
YOLO_INPUT_WIDTH = 640
YOLO_INPUT_HEIGHT = 480
YOLO_CLASS_COUNT = 28
YOLO_EYE_SCORE_THRESHOLD = 0.20
YOLO_NMS_IOU_THRESHOLD = 0.45
LIP_MOTION_INPUT_WIDTH = 48
LIP_MOTION_INPUT_HEIGHT = 30
LIP_MOTION_OPEN_THRESHOLD = 0.50
LIP_MOTION_MARGIN_TOP = 2
LIP_MOTION_MARGIN_BOTTOM = 6
LIP_MOTION_MARGIN_LEFT = 2
LIP_MOTION_MARGIN_RIGHT = 2
IRIS_IDX_481 = np.asarray([248, 252, 224, 228, 232, 236, 240, 244], dtype=np.int64)
IRIS_DIAMETER_M = 0.0117
BLINK_OPEN_THRESHOLD = 0.35
BLINK_CLOSE_THRESHOLD = 0.28
BLINK_REOPEN_THRESHOLD = 0.45
MIN_EYE_SPAN_RATIO = 0.20
DISTANCE_MIN_M = 0.15
DISTANCE_MAX_M = 3.0
DISTANCE_SMOOTHING_ALPHA = 0.35
CALIBRATION_SAMPLE_TARGET = 13
CALIBRATION_FIT_MAX_ERROR = 0.18
# Mirror of DETECT_INTERVAL_MS in web/src/inference/inferenceWorker.ts: the
# face/eye detector runs at most this often; between passes the cached boxes
# are re-anchored to the per-frame iris centers produced by the gaze model.
DETECT_INTERVAL_S = 1.0
# A re-anchor shift beyond this fraction of the head width forces an early
# re-detection. The TS worker uses a fixed 30 px, which is ~0.15 of a typical
# ~200 px head box.
REANCHOR_MAX_SHIFT_RATIO = 0.15
# Fitted during calibration: eye-origin translation weights. Focal length is
# intentionally not searched — hit_m = origin + tan(angle) * distance with
# distance ∝ focal makes focal-vs-affine structurally degenerate, while the
# per-eye origin weights are identifiable whenever head position varies.
WEIGHT_X_CANDIDATES = (1.0, 0.7, 1.3)
WEIGHT_Y_CANDIDATES = (0.25, 0.0, 0.15, 0.4, 0.6)


@dataclass(frozen=True)
class CameraResolution:
    name: str | None
    width: int
    height: int


DEFAULT_CAMERA_RESOLUTION = CameraResolution("VGA", CAMERA_WIDTH, CAMERA_HEIGHT)
CAMERA_RESOLUTION_PRESETS: dict[str, CameraResolution] = {}
for _name, _width, _height, _aliases in [
    ("QQVGA", 160, 120, ("QQVGA",)),
    ("QVGA", 320, 240, ("QVGA",)),
    ("VGA", 640, 480, ("VGA",)),
    ("SVGA", 800, 600, ("SVGA",)),
    ("XGA", 1024, 768, ("XGA",)),
    ("HD", 1280, 720, ("HD", "720p")),
    ("SXGA", 1280, 1024, ("SXGA",)),
    ("UXGA", 1600, 1200, ("UXGA",)),
    ("Full HD", 1920, 1080, ("Full HD", "1080p")),
    ("3MP", 2048, 1536, ("3MP",)),
    ("QHD", 2560, 1440, ("QHD", "WQHD", "1440p")),
    ("5MP", 2592, 1944, ("5MP",)),
    ("6MP", 3072, 2048, ("6MP",)),
    ("4K UHD", 3840, 2160, ("4K UHD",)),
    ("DCI 4K", 4096, 2160, ("DCI 4K",)),
    ("12MP", 4000, 3000, ("12MP",)),
    ("5K", 5120, 2880, ("5K",)),
    ("6K", 6144, 3456, ("6K",)),
    ("8K UHD", 7680, 4320, ("8K UHD",)),
    ("12K", 12288, 6480, ("12K",)),
]:
    _resolution = CameraResolution(_name, _width, _height)
    for _alias in _aliases:
        CAMERA_RESOLUTION_PRESETS["".join(ch.lower() for ch in _alias if ch.isalnum())] = _resolution
REJECTED_CAMERA_RESOLUTION_NAMES = {"2mp", "4mp", "8mp"}


@dataclass(frozen=True)
class Detection:
    class_id: int
    score: float
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def width(self) -> float:
        return max(0.0, self.x2 - self.x1)

    @property
    def height(self) -> float:
        return max(0.0, self.y2 - self.y1)

    @property
    def center(self) -> tuple[float, float]:
        return ((self.x1 + self.x2) * 0.5, (self.y1 + self.y2) * 0.5)


@dataclass(frozen=True)
class DetectionResult:
    head: Detection | None
    eyes: list[Detection]
    mouth: Detection | None = None


@dataclass(frozen=True)
class DisplayGeometry:
    width_px: int
    height_px: int
    diagonal_inch: float

    @property
    def size_m(self) -> tuple[float, float]:
        diagonal_m = self.diagonal_inch * 0.0254
        pixel_diagonal = math.hypot(self.width_px, self.height_px)
        return (
            diagonal_m * self.width_px / pixel_diagonal,
            diagonal_m * self.height_px / pixel_diagonal,
        )


@dataclass(frozen=True)
class GazeEstimate:
    yaw_deg: float
    pitch_deg: float
    left_yaw_deg: float
    left_pitch_deg: float
    right_yaw_deg: float
    right_pitch_deg: float
    iris_diameter_px: float
    eye_open: float
    agreement: float
    left_iris_px: tuple[tuple[float, float], ...] = ()
    right_iris_px: tuple[tuple[float, float], ...] = ()
    left_iris_center_px: tuple[float, float] | None = None
    right_iris_center_px: tuple[float, float] | None = None
    depth_healthy: bool = True


@dataclass(frozen=True)
class GazeFeature:
    point: tuple[float, float]
    eye_center_px: tuple[float, float]
    left_eye_px: tuple[float, float]
    right_eye_px: tuple[float, float]
    left_yaw_deg: float
    left_pitch_deg: float
    right_yaw_deg: float
    right_pitch_deg: float
    head_width_px: float
    iris_diameter_px: float
    eye_open: float
    distance_m: float


@dataclass(frozen=True)
class ProjectionResult:
    point: tuple[float, float]
    fallback_reason: str | None = None


@dataclass(frozen=True)
class ReanchoredDetection:
    head: Detection
    eyes: list[Detection]
    dx: float
    dy: float


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def build_providers(backend: str, model_path: Path) -> list[Any]:
    available = set(ort.get_available_providers())
    requested = backend.lower()

    def cuda_or_cpu(reason: str) -> list[Any]:
        if "CUDAExecutionProvider" in available:
            emit({"type": "status", "level": "warning", "message": f"{reason}; falling back to CUDAExecutionProvider"})
            return ["CUDAExecutionProvider", "CPUExecutionProvider"]
        emit({"type": "status", "level": "warning", "message": f"{reason}; falling back to CPUExecutionProvider"})
        return ["CPUExecutionProvider"]

    if requested == "cpu":
        return ["CPUExecutionProvider"]
    if requested == "cuda":
        if "CUDAExecutionProvider" in available:
            return ["CUDAExecutionProvider", "CPUExecutionProvider"]
        return cuda_or_cpu("CUDAExecutionProvider is not available")
    if requested == "tensorrt":
        if "TensorrtExecutionProvider" not in available:
            return cuda_or_cpu("TensorrtExecutionProvider is not available")
        providers: list[Any] = [
            (
                "TensorrtExecutionProvider",
                {
                    "trt_engine_cache_enable": True,
                    "trt_engine_cache_path": str(model_path.parent),
                    "trt_fp16_enable": True,
                    "trt_op_types_to_exclude": "NonMaxSuppression,NonZero,RoiAlign",
                },
            )
        ]
        if "CUDAExecutionProvider" in available:
            providers.append("CUDAExecutionProvider")
        providers.append("CPUExecutionProvider")
        return providers
    raise ValueError(f"Unsupported backend: {backend}")


def session_options() -> ort.SessionOptions:
    options = ort.SessionOptions()
    options.log_severity_level = 3
    return options


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def valid_camera_fov_deg(value: float, fallback: float = CAMERA_HORIZONTAL_FOV_DEG) -> float:
    return value if math.isfinite(value) and 0.0 < value < 180.0 else fallback


def draw_box(image: np.ndarray, detection: Detection, color: tuple[int, int, int], label: str) -> None:
    x1, y1, x2, y2 = [int(round(v)) for v in (detection.x1, detection.y1, detection.x2, detection.y2)]
    cv2.rectangle(image, (x1, y1), (x2, y2), color, 2)
    text = f"{label} {detection.score:.2f}"
    y = max(18, y1 - 6)
    cv2.putText(image, text, (x1, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 3, cv2.LINE_AA)
    cv2.putText(image, text, (x1, y), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 1, cv2.LINE_AA)


def detection_with_margin(
    image: np.ndarray,
    detection: Detection,
    margin_top: int = 0,
    margin_bottom: int = 0,
    margin_left: int = 0,
    margin_right: int = 0,
) -> Detection:
    image_h, image_w = image.shape[:2]
    x1 = max(0, min(image_w - 1, int(math.floor(detection.x1)) - margin_left))
    y1 = max(0, min(image_h - 1, int(math.floor(detection.y1)) - margin_top))
    x2 = max(x1 + 1, min(image_w, int(math.ceil(detection.x2)) + margin_right))
    y2 = max(y1 + 1, min(image_h, int(math.ceil(detection.y2)) + margin_bottom))
    return Detection(detection.class_id, detection.score, float(x1), float(y1), float(x2), float(y2))


def mouth_detection_with_margin(image: np.ndarray, mouth: Detection) -> Detection:
    return detection_with_margin(
        image,
        mouth,
        margin_top=LIP_MOTION_MARGIN_TOP,
        margin_bottom=LIP_MOTION_MARGIN_BOTTOM,
        margin_left=LIP_MOTION_MARGIN_LEFT,
        margin_right=LIP_MOTION_MARGIN_RIGHT,
    )


def draw_gaze_lines(image: np.ndarray, eyes: list[Detection], yaw_deg: float, pitch_deg: float) -> None:
    diag = math.sqrt(float(image.shape[0] * image.shape[1]))
    length = 0.4 * diag
    dx = length * math.sin(math.radians(yaw_deg))
    dy = length * math.sin(math.radians(-pitch_deg))
    for eye in eyes[:2]:
        start = (int(round(eye.center[0])), int(round(eye.center[1])))
        end = (int(round(eye.center[0] + dx)), int(round(eye.center[1] + dy)))
        cv2.line(image, start, end, (0, 0, 0), 7, cv2.LINE_AA)
        cv2.line(image, start, end, (0, 255, 0), 4, cv2.LINE_AA)
        cv2.circle(image, start, 5, (0, 0, 0), -1, cv2.LINE_AA)
        cv2.circle(image, start, 3, (0, 255, 0), -1, cv2.LINE_AA)


def detection_iou(a: Detection, b: Detection) -> float:
    ix1 = max(a.x1, b.x1)
    iy1 = max(a.y1, b.y1)
    ix2 = min(a.x2, b.x2)
    iy2 = min(a.y2, b.y2)
    intersection = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    union = a.width * a.height + b.width * b.height - intersection
    return intersection / union if union > 0.0 else 0.0


def nms_detections(detections: Iterable[Detection], iou_threshold: float) -> list[Detection]:
    remaining = sorted(detections, key=lambda det: det.score, reverse=True)
    selected: list[Detection] = []
    while remaining:
        current = remaining.pop(0)
        selected.append(current)
        remaining = [det for det in remaining if detection_iou(current, det) <= iou_threshold]
    return selected


def select_eye_pair(head: Detection, eyes: Iterable[Detection]) -> list[Detection]:
    margin_x = head.width * 0.20
    margin_y = head.height * 0.20
    candidates = []
    for eye in eyes:
        cx, cy = eye.center
        if head.x1 - margin_x <= cx <= head.x2 + margin_x and head.y1 - margin_y <= cy <= head.y2 + margin_y:
            candidates.append(eye)
    candidates.sort(key=lambda det: det.score, reverse=True)
    candidates = candidates[:6]
    if len(candidates) <= 2:
        return sorted(candidates, key=lambda det: det.center[0])
    best_pair = max(
        ((a, b) for idx, a in enumerate(candidates) for b in candidates[idx + 1 :]),
        key=lambda pair: abs(pair[0].center[0] - pair[1].center[0]) * (pair[0].score + pair[1].score),
    )
    return sorted(best_pair, key=lambda det: det.center[0])


def select_best_in_head(head: Detection, detections: Iterable[Detection]) -> Detection | None:
    margin_x = head.width * 0.20
    margin_y = head.height * 0.20
    candidates = []
    for detection in detections:
        cx, cy = detection.center
        if head.x1 - margin_x <= cx <= head.x2 + margin_x and head.y1 - margin_y <= cy <= head.y2 + margin_y:
            candidates.append(detection)
    if not candidates:
        return None
    return max(candidates, key=lambda det: det.score)


def parse_yolo_output(
    output: np.ndarray,
    score_threshold: float,
    image_w: int = CAMERA_WIDTH,
    image_h: int = CAMERA_HEIGHT,
    input_w: int = YOLO_INPUT_WIDTH,
    input_h: int = YOLO_INPUT_HEIGHT,
) -> DetectionResult:
    values = np.asarray(output, dtype=np.float32)
    if values.ndim == 3 and values.shape[0] == 1:
        values = values[0]
    if values.ndim != 2 or values.shape[0] != 4 + YOLO_CLASS_COUNT:
        raise ValueError(f"Unexpected YOLO output shape: {tuple(values.shape)}")

    scale_x = float(image_w) / float(input_w)
    scale_y = float(image_h) / float(input_h)
    heads: list[Detection] = []
    eyes: list[Detection] = []
    mouths: list[Detection] = []
    for index in range(values.shape[1]):
        cx = float(values[0, index])
        cy = float(values[1, index])
        box_w = float(values[2, index])
        box_h = float(values[3, index])
        if not all(math.isfinite(v) for v in (cx, cy, box_w, box_h)) or box_w <= 0.0 or box_h <= 0.0:
            continue
        x1 = max(0.0, min(float(image_w - 1), (cx - box_w * 0.5) * scale_x))
        y1 = max(0.0, min(float(image_h - 1), (cy - box_h * 0.5) * scale_y))
        x2 = max(0.0, min(float(image_w - 1), (cx + box_w * 0.5) * scale_x))
        y2 = max(0.0, min(float(image_h - 1), (cy + box_h * 0.5) * scale_y))
        if x2 <= x1 or y2 <= y1:
            continue
        head_score = float(values[4 + HEAD_CLASS_ID, index])
        if math.isfinite(head_score) and head_score >= score_threshold:
            heads.append(Detection(HEAD_CLASS_ID, head_score, x1, y1, x2, y2))
        eye_score = float(values[4 + EYE_CLASS_ID, index])
        if math.isfinite(eye_score) and eye_score >= YOLO_EYE_SCORE_THRESHOLD:
            eyes.append(Detection(EYE_CLASS_ID, eye_score, x1, y1, x2, y2))
        mouth_score = float(values[4 + MOUTH_CLASS_ID, index])
        if math.isfinite(mouth_score) and mouth_score >= score_threshold:
            mouths.append(Detection(MOUTH_CLASS_ID, mouth_score, x1, y1, x2, y2))

    heads = nms_detections(heads, YOLO_NMS_IOU_THRESHOLD)
    eyes = nms_detections(eyes, YOLO_NMS_IOU_THRESHOLD)
    mouths = nms_detections(mouths, YOLO_NMS_IOU_THRESHOLD)
    if not heads:
        return DetectionResult(None, [])
    head = heads[0]
    return DetectionResult(head, select_eye_pair(head, eyes), select_best_in_head(head, mouths))


def emit_preview(
    frame: np.ndarray,
    head: Detection | None,
    eyes: list[Detection],
    mouth: Detection | None = None,
    message: str | None = None,
    width_ratio: float | None = None,
    gaze_angles: tuple[float, float] | None = None,
    iris_contours: tuple[tuple[tuple[float, float], ...], ...] | None = None,
) -> None:
    preview = frame.copy()
    if head is not None:
        draw_box(preview, head, (20, 220, 90), "Head")
    for eye in eyes:
        draw_box(preview, eye, (0, 210, 255), "Eye")
        cx, cy = [int(round(v)) for v in eye.center]
        cv2.circle(preview, (cx, cy), 4, (0, 210, 255), -1)
    if iris_contours is not None:
        for contour in iris_contours:
            if len(contour) >= 3:
                points = np.asarray([[int(round(x)), int(round(y))] for x, y in contour], dtype=np.int32)
                cv2.polylines(preview, [points], True, (255, 140, 0), 1, cv2.LINE_AA)
                for px, py in points:
                    cv2.circle(preview, (px, py), 1, (255, 140, 0), -1)
    if mouth is not None:
        draw_box(preview, mouth_detection_with_margin(preview, mouth), (0, 120, 255), "Mouth")
    if gaze_angles is not None and len(eyes) >= 2:
        draw_gaze_lines(preview, eyes, gaze_angles[0], gaze_angles[1])
    if message:
        cv2.putText(preview, message, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.72, (0, 0, 0), 4, cv2.LINE_AA)
        cv2.putText(preview, message, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.72, (255, 255, 255), 2, cv2.LINE_AA)
    if width_ratio is not None:
        ratio_text = f"Head/Face {width_ratio:.3f}x"
        cv2.putText(preview, ratio_text, (12, preview.shape[0] - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.62, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(preview, ratio_text, (12, preview.shape[0] - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.62, (255, 255, 255), 1, cv2.LINE_AA)

    preview_width = 320
    preview_height = max(1, int(round(preview.shape[0] * preview_width / max(1, preview.shape[1]))))
    preview = cv2.resize(preview, (preview_width, preview_height), interpolation=cv2.INTER_AREA)
    ok, encoded = cv2.imencode(".jpg", preview, [int(cv2.IMWRITE_JPEG_QUALITY), 72])
    if not ok:
        return
    data = base64.b64encode(encoded).decode("ascii")
    emit(
        {
            "type": "preview",
            "image": f"data:image/jpeg;base64,{data}",
            "head_detected": head is not None,
            "eye_count": len(eyes),
            "width_ratio": width_ratio,
        }
    )


def angles_from_vec(vec: np.ndarray) -> tuple[float, float]:
    x, y, z = -vec[2], vec[1], -vec[0]
    theta = np.arctan2(y, x)
    phi = np.arctan2(np.sqrt(x**2 + y**2), z) - np.pi / 2
    return float(phi), float(theta)


def sphere_fit_center(eye: np.ndarray) -> np.ndarray | None:
    """Least-squares sphere fit over the eye mesh — a stable 3D ball centre.

    The first 32 mesh points' z collapses to ~0 under ordinary pose/lighting
    shifts, which pins extracted pitch near -85 deg; fitting all 481 points is
    robust on every frame.
    """
    pts = eye.astype(np.float64)
    A = np.column_stack([2.0 * pts, np.ones(len(pts))])
    b = (pts**2).sum(axis=1)
    try:
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
    except np.linalg.LinAlgError:
        return None
    if not np.all(np.isfinite(sol[:3])):
        return None
    return sol[:3]


# Learned |iris - ball centre| from frames with a healthy depth channel
# (~2.7x iris diameter for this mesh). On collapsed frames the forward depth
# is reconstructed as -sqrt(R^2 - |d2d|^2): the iris rides the ball surface,
# so direction is recoverable from the stable 2D displacement alone.
_LEARNED_BALL_VEC_NORM = 0.0


def reset_ball_vec_baseline() -> None:
    global _LEARNED_BALL_VEC_NORM
    _LEARNED_BALL_VEC_NORM = 0.0


def angles_and_vec_from_eye(eye: np.ndarray, iris_diameter_px: float = 0.0) -> tuple[float, float, np.ndarray, bool]:
    global _LEARNED_BALL_VEC_NORM
    ball = sphere_fit_center(eye)
    if ball is None:
        raise ValueError("Degenerate gaze mesh (sphere fit failed)")
    iris = eye[IRIS_IDX_481].mean(axis=0)
    vec = iris - ball
    norm = float(np.linalg.norm(vec))
    d2d = float(np.hypot(vec[0], vec[1]))
    # A healthy |iris-ball| runs ~2.7x the iris diameter for this mesh; the
    # depth-collapse regime drops it ~10x, and partial collapse still yields a
    # shrunken norm (~27 vs ~66 measured) that over-reads angles ~2.5x. Gate on
    # the learned radius once known; iris-diameter floor covers the seed phase.
    min_healthy_norm = max(1e-6, iris_diameter_px * 0.6)
    radius = _LEARNED_BALL_VEC_NORM if _LEARNED_BALL_VEC_NORM > 0.0 else max(1.0, iris_diameter_px * 2.7)
    healthy = norm >= max(min_healthy_norm, radius * 0.65) and norm > 1.0e-6
    if healthy:
        _LEARNED_BALL_VEC_NORM = norm if _LEARNED_BALL_VEC_NORM == 0.0 else _LEARNED_BALL_VEC_NORM + 0.05 * (norm - _LEARNED_BALL_VEC_NORM)
    else:
        dz_sq = radius * radius - d2d * d2d
        vec[2] = -math.sqrt(max(dz_sq, radius * 0.0025))
    used = float(np.linalg.norm(vec))
    if used <= 1.0e-6:
        raise ValueError("Invalid gaze vector norm")
    unit = vec / used
    theta_x, theta_y = angles_from_vec(unit)
    return theta_x, theta_y, unit, healthy


def eye_iris_metrics(eye: np.ndarray) -> tuple[float, float, tuple[tuple[float, float], ...]]:
    iris = eye[IRIS_IDX_481][:, :2]
    contour = tuple((float(p[1]), float(p[0])) for p in iris)
    diameter = float(np.mean([np.linalg.norm(iris[a] - iris[b]) for a, b in ((0, 4), (1, 5), (2, 6), (3, 7))]))
    centered = iris - iris.mean(axis=0)
    cov = centered.T @ centered / max(1, iris.shape[0] - 1)
    eigenvalues = np.linalg.eigvalsh(cov)
    major = float(eigenvalues[-1]) if eigenvalues.size else 0.0
    minor = float(eigenvalues[0]) if eigenvalues.size else 0.0
    open_ratio = math.sqrt(max(0.0, minor / major)) if major > 1.0e-12 else 0.0
    return diameter, clamp01(open_ratio), contour


def contour_center(contour: tuple[tuple[float, float], ...] | None) -> tuple[float, float] | None:
    if not contour:
        return None
    x = 0.0
    y = 0.0
    for px, py in contour:
        x += px
        y += py
    return x / len(contour), y / len(contour)


def translate_detection(detection: Detection, dx: float, dy: float) -> Detection:
    return Detection(
        detection.class_id,
        detection.score,
        detection.x1 + dx,
        detection.y1 + dy,
        detection.x2 + dx,
        detection.y2 + dy,
    )


# Re-anchors cached detector boxes to the gaze mesh's camera-space iris
# centers. Between full detector runs the head drifts; the iris centers are
# re-estimated every frame, so matching each eye box to its nearest iris
# center and translating the head box by the same delta keeps the crop aligned
# without paying for detection. Returns None when the implied shift is too
# large to trust — callers should force a fresh detection.
def reanchor_detection(
    head: Detection,
    eyes: list[Detection],
    left_iris_center: tuple[float, float] | None,
    right_iris_center: tuple[float, float] | None,
    frame_width: int,
    frame_height: int,
) -> ReanchoredDetection | None:
    if len(eyes) < 2 or left_iris_center is None or right_iris_center is None:
        return None
    iris_centers = (left_iris_center, right_iris_center)
    for iris in iris_centers:
        if (
            not all(math.isfinite(component) for component in iris)
            or iris[0] < 0.0
            or iris[0] > frame_width
            or iris[1] < 0.0
            or iris[1] > frame_height
        ):
            return None
    used: set[int] = set()
    centers: list[tuple[float, float]] = []
    for eye in eyes[:2]:
        cx, cy = eye.center
        best = -1
        best_distance = math.inf
        for index in range(2):
            if index in used:
                continue
            distance = math.hypot(iris_centers[index][0] - cx, iris_centers[index][1] - cy)
            if distance < best_distance:
                best_distance = distance
                best = index
        if best == -1 or best_distance > 80.0:
            return None
        used.add(best)
        centers.append(iris_centers[best])
    dx = (centers[0][0] + centers[1][0]) * 0.5 - (eyes[0].center[0] + eyes[1].center[0]) * 0.5
    dy = (centers[0][1] + centers[1][1]) * 0.5 - (eyes[0].center[1] + eyes[1].center[1]) * 0.5

    def shift_box(box: Detection, center_point: tuple[float, float]) -> Detection:
        cx, cy = box.center
        return translate_detection(box, center_point[0] - cx, center_point[1] - cy)

    return ReanchoredDetection(
        head=translate_detection(head, dx, dy),
        eyes=[shift_box(eyes[0], centers[0]), shift_box(eyes[1], centers[1])],
        dx=dx,
        dy=dy,
    )


def update_blink_state(closed: bool, eye_open: float) -> bool:
    if closed:
        return not math.isfinite(eye_open) or eye_open < BLINK_REOPEN_THRESHOLD
    return math.isfinite(eye_open) and eye_open < BLINK_CLOSE_THRESHOLD


def is_head_turned(eye_span_px: float, head_width_px: float) -> bool:
    return math.isfinite(eye_span_px) and eye_span_px < max(1.0, head_width_px) * MIN_EYE_SPAN_RATIO


def feature_distance_m(feature: GazeFeature, focal_px: float, use_iris: bool = True) -> float:
    if use_iris and math.isfinite(feature.iris_diameter_px) and feature.iris_diameter_px >= 2.0:
        distance = IRIS_DIAMETER_M * focal_px / feature.iris_diameter_px
        if DISTANCE_MIN_M <= distance <= DISTANCE_MAX_M:
            return distance
    head_width = max(1.0, feature.head_width_px)
    return min(DISTANCE_MAX_M, max(0.05, AVERAGE_HEAD_WIDTH_M * focal_px / head_width))


class OneEuroFilter:
    def __init__(self, mincutoff: float = 1.0, beta: float = 0.7, dcutoff: float = 1.0) -> None:
        self.mincutoff = max(0.0, mincutoff)
        self.beta = max(0.0, beta)
        self.dcutoff = max(0.0, dcutoff)
        self.x: float | None = None
        self.dx = 0.0
        self.t: float | None = None

    def _alpha(self, cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * max(1.0e-4, cutoff))
        return 1.0 / (1.0 + tau / max(1.0e-4, dt))

    def filter(self, value: float, at: float) -> float:
        if not math.isfinite(value):
            return self.x if self.x is not None else value
        if self.t is None or self.x is None:
            self.t, self.x = at, value
            return value
        dt = max(at - self.t, 1.0e-3)
        self.t = at
        derivative = (value - self.x) / dt
        self.dx += self._alpha(self.dcutoff, dt) * (derivative - self.dx)
        cutoff = self.mincutoff + self.beta * abs(self.dx)
        self.x += self._alpha(cutoff, dt) * (value - self.x)
        return self.x


# Saccade-aware gaze angle smoothing. Mesh estimation noise is ~±2° and roughly
# white, so a light EMA on the per-eye angles removes most of it; real saccades
# move both eyes by far more than noise in a single frame, so a large
# frame-to-frame jump snaps the filter instead of smearing the saccade.
# Mirrors GazeAngleSmoother in web/src/inference/core.ts; applied to the raw
# model angles before projection so downstream velocity estimates see
# smoothed angles.
class AngleSmoother:
    def __init__(self, alpha: float = 0.35, snap_deg: float = 12.0) -> None:
        self.alpha = alpha
        self.snap_deg = snap_deg
        self._smoothed: tuple[float, float, float, float] | None = None

    def update(self, estimate: GazeEstimate) -> GazeEstimate:
        raw = (
            estimate.left_yaw_deg,
            estimate.left_pitch_deg,
            estimate.right_yaw_deg,
            estimate.right_pitch_deg,
        )
        if self._smoothed is None:
            smoothed = raw
        else:
            max_delta = max(abs(raw[index] - self._smoothed[index]) for index in range(4))
            if max_delta > self.snap_deg:
                smoothed = raw
            else:
                smoothed = tuple(
                    self._smoothed[index] + self.alpha * (raw[index] - self._smoothed[index]) for index in range(4)
                )
        self._smoothed = smoothed
        left_yaw_deg, left_pitch_deg, right_yaw_deg, right_pitch_deg = smoothed
        return replace(
            estimate,
            yaw_deg=(left_yaw_deg + right_yaw_deg) * 0.5,
            pitch_deg=(left_pitch_deg + right_pitch_deg) * 0.5,
            left_yaw_deg=left_yaw_deg,
            left_pitch_deg=left_pitch_deg,
            right_yaw_deg=right_yaw_deg,
            right_pitch_deg=right_pitch_deg,
        )

    def reset(self) -> None:
        self._smoothed = None


# Velocity-threshold gaze filter inspired by Tobii's I-VT fixation
# classification: when angular gaze velocity is low the eye is fixating and the
# output should converge on the local mean (heavy smoothing removes sensor
# noise); above the saccade threshold the eye is genuinely moving and the
# output passes through with no lag. Fixation exit uses hysteresis and a
# minimum streak so a single noisy velocity spike cannot flap the state.
# Mirrors SaccadeAwareGazeFilter in web/src/inference/core.ts.
class SaccadeAwareFilter:
    def __init__(
        self,
        enter_deg_s: float = 45.0,
        exit_deg_s: float = 25.0,
        exit_samples: int = 2,
        fix_alpha: float = 0.2,
        deadzone: float = 0.004,
        vel_alpha: float = 0.5,
        max_fixation_step: float = 0.06,
    ) -> None:
        self.enter_deg_s = enter_deg_s
        self.exit_deg_s = exit_deg_s
        self.exit_samples = exit_samples
        self.fix_alpha = fix_alpha
        self.deadzone = deadzone
        self.vel_alpha = vel_alpha
        self.max_fixation_step = max_fixation_step
        self._out: tuple[float, float] | None = None
        self._last_angles: tuple[float, float] | None = None
        self._last_t = 0.0
        self._velocity = 0.0
        self._saccade = False
        self._below_exit_streak = 0

    def update(self, x: float, y: float, t_ms: float, yaw_deg: float, pitch_deg: float) -> tuple[float, float]:
        if self._out is None or self._last_angles is None or self._last_t == 0.0:
            self._out = (x, y)
            self._last_angles = (yaw_deg, pitch_deg)
            self._last_t = t_ms
            return self._out
        dt = max((t_ms - self._last_t) / 1000.0, 1.0e-3)
        instantaneous = math.hypot(yaw_deg - self._last_angles[0], pitch_deg - self._last_angles[1]) / dt
        self._velocity += self.vel_alpha * (instantaneous - self._velocity)
        self._last_angles = (yaw_deg, pitch_deg)
        self._last_t = t_ms
        if self._saccade:
            if self._velocity < self.exit_deg_s:
                self._below_exit_streak += 1
                if self._below_exit_streak >= self.exit_samples:
                    self._saccade = False
                    self._below_exit_streak = 0
            else:
                self._below_exit_streak = 0
            self._out = (x, y)
            return self._out
        if self._velocity > self.enter_deg_s:
            self._saccade = True
            self._out = (x, y)
            return self._out
        if math.hypot(x - self._out[0], y - self._out[1]) < self.deadzone:
            return self._out
        nx = self._out[0] + self.fix_alpha * (x - self._out[0])
        ny = self._out[1] + self.fix_alpha * (y - self._out[1])
        step = math.hypot(nx - self._out[0], ny - self._out[1])
        if step > self.max_fixation_step:
            scale = self.max_fixation_step / step
            self._out = (
                self._out[0] + (nx - self._out[0]) * scale,
                self._out[1] + (ny - self._out[1]) * scale,
            )
            return self._out
        self._out = (nx, ny)
        return self._out

    @property
    def velocity_deg_s(self) -> float:
        return self._velocity

    @property
    def in_saccade(self) -> bool:
        return self._saccade

    def reset(self) -> None:
        self._out = None
        self._last_angles = None
        self._last_t = 0.0
        self._velocity = 0.0
        self._saccade = False
        self._below_exit_streak = 0


@dataclass
class RbfCorrection:
    centers: np.ndarray
    weights: np.ndarray
    sigma: float

    def apply(self, point: np.ndarray) -> np.ndarray:
        radius = np.linalg.norm(self.centers - point, axis=1)
        kernel = np.exp(-((radius / self.sigma) ** 2))
        return kernel @ self.weights


def rbf_fit(raws: np.ndarray, residuals: np.ndarray, ridge: float = 1.0e-3) -> RbfCorrection | None:
    if len(raws) < 4:
        return None
    pairwise = np.linalg.norm(raws[:, None, :] - raws[None, :, :], axis=2)
    off_diagonal = pairwise + np.eye(len(raws)) * np.inf
    sigma = float(np.median(off_diagonal.min(axis=1)) * 0.5)
    if not math.isfinite(sigma) or sigma <= 0.0:
        return None
    sigma = max(0.05, min(0.5, sigma))
    kernel = np.exp(-((pairwise / sigma) ** 2)) + np.eye(len(raws)) * ridge
    try:
        weights = np.linalg.solve(kernel, residuals)
    except np.linalg.LinAlgError:
        return None
    if not np.isfinite(weights).all():
        return None
    return RbfCorrection(raws.copy(), weights, sigma)


def similarity_crop(image: np.ndarray, center: tuple[float, float], crop_size: float) -> tuple[np.ndarray, np.ndarray]:
    scale = GAZE_INPUT_SIZE / max(1.0, crop_size)
    matrix = np.asarray(
        [
            [scale, 0.0, GAZE_INPUT_SIZE * 0.5 - center[0] * scale],
            [0.0, scale, GAZE_INPUT_SIZE * 0.5 - center[1] * scale],
        ],
        dtype=np.float32,
    )
    crop = cv2.warpAffine(image, matrix, (GAZE_INPUT_SIZE, GAZE_INPUT_SIZE), borderValue=0.0)
    return crop, matrix


def transform_points3d(points: np.ndarray, matrix: np.ndarray) -> np.ndarray:
    transformed = np.zeros_like(points, dtype=np.float32)
    scale = math.sqrt(float(matrix[0, 0] * matrix[0, 0] + matrix[0, 1] * matrix[0, 1]))
    ones = np.ones((points.shape[0], 1), dtype=np.float32)
    xy1 = np.concatenate([points[:, :2].astype(np.float32), ones], axis=1)
    transformed[:, :2] = xy1 @ matrix.T
    transformed[:, 2] = points[:, 2] * scale
    return transformed


def crop_detection(
    image: np.ndarray,
    detection: Detection,
    width: int,
    height: int,
    margin_top: int = 0,
    margin_bottom: int = 0,
    margin_left: int = 0,
    margin_right: int = 0,
) -> np.ndarray:
    crop_area = detection_with_margin(image, detection, margin_top, margin_bottom, margin_left, margin_right)
    x1, y1, x2, y2 = [int(v) for v in (crop_area.x1, crop_area.y1, crop_area.x2, crop_area.y2)]
    crop = image[y1:y2, x1:x2]
    return cv2.resize(crop, (width, height), interpolation=cv2.INTER_LINEAR)


class YoloWholebodyDetector:
    def __init__(self, model_path: Path, backend: str, score_threshold: float) -> None:
        self.model_path = model_path
        self.score_threshold = score_threshold
        providers = build_providers(backend, model_path)
        self.session = ort.InferenceSession(str(model_path), sess_options=session_options(), providers=providers)
        self.input = self.session.get_inputs()[0]
        self.output = self.session.get_outputs()[0]
        self.providers = self.session.get_providers()
        self._validate_model()

    def _validate_model(self) -> None:
        if self.input.name != "images" or list(self.input.shape) != [1, 3, YOLO_INPUT_HEIGHT, YOLO_INPUT_WIDTH]:
            raise RuntimeError(f"Unexpected YOLO input: {self.input.name} {self.input.shape}")
        if self.output.name != "output0" or list(self.output.shape) != [1, 4 + YOLO_CLASS_COUNT, 6300]:
            raise RuntimeError(f"Unexpected YOLO output: {self.output.name} {self.output.shape}")

    def detect(self, frame: np.ndarray) -> DetectionResult:
        image_h, image_w = frame.shape[:2]
        resized = cv2.resize(frame, (YOLO_INPUT_WIDTH, YOLO_INPUT_HEIGHT), interpolation=cv2.INTER_LINEAR)
        rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        input_tensor = rgb.transpose(2, 0, 1)[None, ...].astype(np.float32)
        output = self.session.run([self.output.name], {self.input.name: input_tensor})[0]
        return parse_yolo_output(output, self.score_threshold, image_w, image_h)


class LipMotionEstimator:
    def __init__(self, model_path: Path, backend: str) -> None:
        self.model_path = model_path
        providers = build_providers(backend, model_path)
        self.session = ort.InferenceSession(str(model_path), sess_options=session_options(), providers=providers)
        self.input = self.session.get_inputs()[0]
        self.output = self.session.get_outputs()[0]
        self.providers = self.session.get_providers()
        self._validate_model()

    def _validate_model(self) -> None:
        if self.input.name != "images" or list(self.input.shape) != [1, 3, LIP_MOTION_INPUT_HEIGHT, LIP_MOTION_INPUT_WIDTH]:
            raise RuntimeError(f"Unexpected lip motion input: {self.input.name} {self.input.shape}")
        if self.output.name != "prob_open" or list(self.output.shape) != [1]:
            raise RuntimeError(f"Unexpected lip motion output: {self.output.name} {self.output.shape}")

    def estimate(self, frame: np.ndarray, mouth: Detection) -> float:
        crop = crop_detection(
            frame,
            mouth,
            LIP_MOTION_INPUT_WIDTH,
            LIP_MOTION_INPUT_HEIGHT,
            margin_top=LIP_MOTION_MARGIN_TOP,
            margin_bottom=LIP_MOTION_MARGIN_BOTTOM,
            margin_left=LIP_MOTION_MARGIN_LEFT,
            margin_right=LIP_MOTION_MARGIN_RIGHT,
        )
        rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        input_tensor = rgb.transpose(2, 0, 1)[None, ...].astype(np.float32)
        output = self.session.run([self.output.name], {self.input.name: input_tensor})[0]
        return float(np.asarray(output, dtype=np.float32).reshape(-1)[0])


class RetinaFaceEyeDetector:
    def __init__(self, model_path: Path, backend: str, score_threshold: float) -> None:
        self.model_path = model_path
        self.score_threshold = score_threshold
        providers = build_providers(backend, model_path)
        self.session = ort.InferenceSession(str(model_path), sess_options=session_options(), providers=providers)
        self.input = self.session.get_inputs()[0]
        self.output = self.session.get_outputs()[0]
        self.providers = self.session.get_providers()
        self.mean = np.asarray([104.0, 117.0, 123.0], dtype=np.float32)
        self._validate_model()

    def _validate_model(self) -> None:
        if self.input.name != "input" or list(self.input.shape) != [1, 3, 480, 640]:
            raise RuntimeError(f"Unexpected RetinaFace input: {self.input.name} {self.input.shape}")
        if self.output.name != "batchno_classid_score_x1y1x2y2_landms":
            raise RuntimeError(f"Unexpected RetinaFace output: {self.output.name} {self.output.shape}")

    def detect(self, frame: np.ndarray) -> DetectionResult:
        image_h, image_w = frame.shape[:2]
        resized = cv2.resize(frame, (640, 480), interpolation=cv2.INTER_LINEAR)
        input_tensor = resized[..., ::-1].astype(np.float32)
        input_tensor = (input_tensor - self.mean).transpose(2, 0, 1)[None, ...].astype(np.float32)
        output = self.session.run([self.output.name], {self.input.name: input_tensor})[0]
        if len(output) == 0:
            return DetectionResult(None, [])

        faces = [row for row in output if float(row[2]) >= self.score_threshold]
        if not faces:
            return DetectionResult(None, [])
        face = max(faces, key=lambda row: float(row[2]))
        score = float(face[2])
        x1 = max(0.0, min(float(image_w - 1), float(face[3]) * image_w / 640.0))
        y1 = max(0.0, min(float(image_h - 1), float(face[4]) * image_h / 480.0))
        x2 = max(0.0, min(float(image_w - 1), float(face[5]) * image_w / 640.0))
        y2 = max(0.0, min(float(image_h - 1), float(face[6]) * image_h / 480.0))
        if x2 <= x1 or y2 <= y1:
            return DetectionResult(None, [])

        head = Detection(HEAD_CLASS_ID, score, x1, y1, x2, y2)
        right_eye = (float(face[7]) * image_w / 640.0, float(face[8]) * image_h / 480.0)
        left_eye = (float(face[9]) * image_w / 640.0, float(face[10]) * image_h / 480.0)
        eye_box_size = max(10.0, head.width * 0.08)
        eyes = [
            self._eye_detection(left_eye, eye_box_size, score),
            self._eye_detection(right_eye, eye_box_size, score),
        ]
        return DetectionResult(head, sorted(eyes, key=lambda det: det.center[0]))

    @staticmethod
    def _eye_detection(center: tuple[float, float], size: float, score: float) -> Detection:
        cx, cy = center
        half = size * 0.5
        return Detection(EYE_CLASS_ID, score, cx - half, cy - half, cx + half, cy + half)


class GazeEstimator:
    def __init__(self, model_path: Path, backend: str) -> None:
        self.model_path = model_path
        providers = build_providers(backend, model_path)
        self.session = ort.InferenceSession(str(model_path), sess_options=session_options(), providers=providers)
        self.input = self.session.get_inputs()[0]
        self.output = self.session.get_outputs()[0]
        self.providers = self.session.get_providers()
        self._validate_model()

    def _validate_model(self) -> None:
        if self.input.name != "input" or list(self.input.shape[1:]) != [3, 160, 160]:
            raise RuntimeError(f"Unexpected gaze model input: {self.input.name} {self.input.shape}")
        if self.output.name != "output" or list(self.output.shape[1:]) != [962, 3]:
            raise RuntimeError(f"Unexpected gaze model output: {self.output.name} {self.output.shape}")

    def warmup(self) -> None:
        # First session.run compiles provider pipelines; run it before the live loop.
        batch = self.input.shape[0] if isinstance(self.input.shape[0], int) and self.input.shape[0] > 0 else 1
        try:
            self.session.run(
                [self.output.name],
                {self.input.name: np.zeros((batch, 3, GAZE_INPUT_SIZE, GAZE_INPUT_SIZE), dtype=np.float32)},
            )
        except Exception:
            pass

    def estimate(self, frame: np.ndarray, head: Detection, eyes: list[Detection]) -> GazeEstimate:
        if len(eyes) < 2:
            raise ValueError("Two eye detections are required")
        left_eye, right_eye = eyes[0], eyes[1]
        left_center = np.asarray(left_eye.center, dtype=np.float32)
        right_center = np.asarray(right_eye.center, dtype=np.float32)
        eye_center = tuple(((left_center + right_center) * 0.5).tolist())
        eye_distance = float(np.linalg.norm(right_center - left_center))
        crop_size = max(head.width / 1.5, eye_distance) * 1.5
        crop, matrix = similarity_crop(frame, eye_center, crop_size)
        rgb = cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)
        input_tensor = rgb.astype(np.float32).transpose(2, 0, 1)[None, ...]
        input_tensor = (input_tensor / 255.0 - 0.5) / 0.5
        prediction = self.session.run([self.output.name], {self.input.name: input_tensor})[0][0]
        inverse_matrix = cv2.invertAffineTransform(matrix).astype(np.float32)
        points = transform_points3d(prediction.astype(np.float32), inverse_matrix)
        eye_l = points[:481, :].copy()
        eye_r = points[481:, :].copy()
        for eye in (eye_l, eye_r):
            eye[:, [0, 1]] = eye[:, [1, 0]]
        diameter_l, open_l, contour_l = eye_iris_metrics(eye_l)
        diameter_r, open_r, contour_r = eye_iris_metrics(eye_r)
        theta_x_l, theta_y_l, _, healthy_l = angles_and_vec_from_eye(eye_l, diameter_l)
        theta_x_r, theta_y_r, _, healthy_r = angles_and_vec_from_eye(eye_r, diameter_r)
        left_yaw_deg = theta_y_l * 180.0 / math.pi
        left_pitch_deg = -theta_x_l * 180.0 / math.pi
        right_yaw_deg = theta_y_r * 180.0 / math.pi
        right_pitch_deg = -theta_x_r * 180.0 / math.pi
        yaw_deg = (left_yaw_deg + right_yaw_deg) * 0.5
        pitch_deg = (left_pitch_deg + right_pitch_deg) * 0.5
        iris_diameters = [d for d in (diameter_l, diameter_r) if math.isfinite(d)]
        iris_diameter_px = float(sum(iris_diameters) / len(iris_diameters)) if iris_diameters else 0.0
        eye_open = clamp01(min(open_l, open_r))
        disagreement = max(abs(left_yaw_deg - right_yaw_deg), abs(left_pitch_deg - right_pitch_deg))
        agreement = clamp01(1.0 - disagreement / 30.0)
        return GazeEstimate(
            yaw_deg=float(yaw_deg),
            pitch_deg=float(pitch_deg),
            left_yaw_deg=float(left_yaw_deg),
            left_pitch_deg=float(left_pitch_deg),
            right_yaw_deg=float(right_yaw_deg),
            right_pitch_deg=float(right_pitch_deg),
            iris_diameter_px=iris_diameter_px,
            eye_open=eye_open,
            agreement=agreement,
            left_iris_px=contour_l,
            right_iris_px=contour_r,
            left_iris_center_px=contour_center(contour_l),
            right_iris_center_px=contour_center(contour_r),
            depth_healthy=bool(healthy_l and healthy_r),
        )


class Calibration:
    def __init__(
        self,
        path: Path,
        reprojector: Any | None = None,
        fit_count: int = CALIBRATION_SAMPLE_TARGET,
    ) -> None:
        self.path = path
        self.matrix: np.ndarray | None = None
        self.rbf: RbfCorrection | None = None
        self.geometry: dict[str, float] | None = None
        self.source_min: np.ndarray | None = None
        self.source_max: np.ndarray | None = None
        self.source_margin = 0.08
        self.samples: list[tuple[GazeFeature, tuple[float, float]]] = []
        self.validation: list[dict[str, Any]] = []
        self.pending: dict[str, Any] | None = None
        self.reprojector = reprojector
        self.fit_count = fit_count
        self.validation_retries = 0
        self.max_validation_retries = 3
        self.load()

    @property
    def pending_matrix(self) -> np.ndarray | None:
        return self.pending["matrix"] if self.pending is not None else None

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            version = payload.get("raw_projection")
            if version not in ("unclipped-v1", "unclipped-v2"):
                emit({"type": "status", "level": "warning", "message": "Old calibration uses clipped raw gaze; recalibrate before using it"})
                return
            matrix = np.asarray(payload.get("affine"), dtype=np.float64)
            if matrix.shape == (3, 2):
                self.matrix = matrix
                rbf = payload.get("rbf")
                if isinstance(rbf, dict):
                    centers = np.asarray(rbf.get("centers"), dtype=np.float64)
                    weights = np.asarray(rbf.get("weights"), dtype=np.float64)
                    sigma = float(rbf.get("sigma", 0.0))
                    if centers.ndim == 2 and centers.shape[1] == 2 and weights.shape == centers.shape and sigma > 0.0:
                        self.rbf = RbfCorrection(centers, weights, sigma)
                geometry = payload.get("geometry")
                if isinstance(geometry, dict):
                    weight_x = float(geometry.get("eye_position_weight_x", 1.0))
                    weight_y = float(geometry.get("eye_position_weight_y", 0.25))
                    if math.isfinite(weight_x) and math.isfinite(weight_y):
                        self.geometry = {
                            "eye_position_weight_x": weight_x,
                            "eye_position_weight_y": weight_y,
                        }
                source_bounds = payload.get("source_bounds")
                if isinstance(source_bounds, dict):
                    source_min = np.asarray(source_bounds.get("min"), dtype=np.float64)
                    source_max = np.asarray(source_bounds.get("max"), dtype=np.float64)
                    if source_min.shape == (2,) and source_max.shape == (2,):
                        self.source_min = source_min
                        self.source_max = source_max
                emit({"type": "status", "level": "info", "message": f"Loaded calibration: {self.path}"})
                if self.geometry is not None:
                    emit({"type": "calibration", "status": "geometry", "geometry": self.geometry})
        except Exception as exc:
            emit({"type": "status", "level": "warning", "message": f"Failed to load calibration: {exc}"})

    def _map(
        self,
        raw: tuple[float, float],
        matrix: np.ndarray,
        rbf: RbfCorrection | None,
        source_min: np.ndarray | None,
        source_max: np.ndarray | None,
    ) -> tuple[float, float]:
        x, y = raw
        if source_min is not None and source_max is not None:
            source = np.asarray([x, y], dtype=np.float64)
            span = np.maximum(source_max - source_min, 0.05)
            lower = source_min - span * self.source_margin
            upper = source_max + span * self.source_margin
            x, y = np.clip(source, lower, upper).tolist()
        out = np.asarray([x, y, 1.0], dtype=np.float64) @ matrix
        if rbf is not None:
            out = out + rbf.apply(np.asarray([x, y], dtype=np.float64))
        return clamp01(float(out[0])), clamp01(float(out[1]))

    def apply(self, raw: tuple[float, float]) -> tuple[float, float]:
        if self.matrix is None:
            return raw
        return self._map(raw, self.matrix, self.rbf, self.source_min, self.source_max)

    def _fit(self) -> None:
        features = [feature for feature, _ in self.samples]
        targets = np.asarray([point for _, point in self.samples], dtype=np.float64)
        live_raws = np.asarray([feature.point for feature in features], dtype=np.float64)
        spans = np.ptp(live_raws, axis=0)
        if np.any(spans < 0.08):
            self.reject_fit("Raw gaze does not separate calibration targets")
            return
        best: dict[str, Any] | None = None
        if self.reprojector is not None:
            for weight_x in WEIGHT_X_CANDIDATES:
                for weight_y in WEIGHT_Y_CANDIDATES:
                    raws = np.asarray(
                        [self.reprojector(feature, weight_x, weight_y) for feature in features],
                        dtype=np.float64,
                    )
                    if not np.isfinite(raws).all() or np.linalg.matrix_rank(np.column_stack([raws, np.ones(len(raws))])) < 3:
                        continue
                    augmented = np.column_stack([raws, np.ones(len(raws))])
                    matrix, *_ = np.linalg.lstsq(augmented, targets, rcond=None)
                    max_error = float(np.max(np.linalg.norm(augmented @ matrix - targets, axis=1)))
                    if best is None or max_error < best["error"]:
                        best = {
                            "error": max_error,
                            "matrix": matrix,
                            "raws": raws,
                            "geometry": {
                                "eye_position_weight_x": weight_x,
                                "eye_position_weight_y": weight_y,
                            },
                        }
        else:
            source = np.column_stack([live_raws, np.ones(len(live_raws))])
            if np.linalg.matrix_rank(source) < 3:
                self.reject_fit("Raw gaze does not separate calibration targets")
                return
            matrix, *_ = np.linalg.lstsq(source, targets, rcond=None)
            best = {
                "error": float(np.max(np.linalg.norm(source @ matrix - targets, axis=1))),
                "matrix": matrix,
                "raws": live_raws,
                "geometry": None,
            }
        if best is None:
            self.reject_fit("Calibration geometry fit produced no valid candidate")
            return
        if not math.isfinite(best["error"]) or best["error"] > CALIBRATION_FIT_MAX_ERROR:
            self.reject_fit(f"Calibration fit error {best['error']:.3f} exceeds {CALIBRATION_FIT_MAX_ERROR:.2f}")
            return
        residuals = targets - np.column_stack([best["raws"], np.ones(len(best["raws"]))]) @ best["matrix"]
        rbf = rbf_fit(best["raws"], residuals)
        self.pending = {
            "matrix": best["matrix"],
            "rbf": rbf,
            "geometry": best["geometry"],
            "source_min": best["raws"].min(axis=0),
            "source_max": best["raws"].max(axis=0),
            "raws": best["raws"],
            "error": best["error"],
        }

    def capture(self, feature: GazeFeature | None, target: tuple[float, float]) -> None:
        if feature is None:
            emit({"type": "calibration", "status": "no_sample", "message": "No gaze sample is available yet"})
            return
        self.samples.append((feature, target))
        emit({"type": "calibration", "status": "sampled", "count": len(self.samples)})
        if len(self.samples) < self.fit_count:
            return
        self._fit()

    def validate(self, feature: GazeFeature | None, target: tuple[float, float]) -> None:
        if feature is None or self.pending is None:
            emit({"type": "calibration", "status": "no_sample", "message": "No fresh validation sample is available"})
            return
        geometry = self.pending["geometry"]
        if geometry is not None and self.reprojector is not None:
            raw = self.reprojector(feature, geometry["eye_position_weight_x"], geometry["eye_position_weight_y"])
        else:
            raw = feature.point
        estimate = self._map(raw, self.pending["matrix"], self.pending["rbf"], self.pending["source_min"], self.pending["source_max"])
        error = float(math.dist(estimate, target))
        if not math.isfinite(error) or error > 0.18:
            self.validation_retries += 1
            if self.validation_retries <= self.max_validation_retries:
                self.validation.clear()
                emit(
                    {
                        "type": "calibration",
                        "status": "validation_retry",
                        "message": (
                            f"Validation error {error:.3f} — hold still at the two check points again "
                            f"({self.validation_retries}/{self.max_validation_retries})"
                        ),
                    }
                )
                return
            self.reject_fit(f"Validation error {error:.3f} exceeds 0.18 after {self.max_validation_retries} retries")
            return
        self.validation.append({"raw": list(raw), "target": list(target), "error": error})
        if len(self.validation) < 2:
            emit({"type": "calibration", "status": "sampled", "count": self.fit_count + len(self.validation)})
            return
        rbf = self.pending["rbf"]
        payload = {
            "raw_projection": "unclipped-v2",
            "affine": self.pending["matrix"].tolist(),
            "rbf": (
                {"sigma": rbf.sigma, "centers": rbf.centers.tolist(), "weights": rbf.weights.tolist()}
                if rbf is not None
                else None
            ),
            "geometry": self.pending["geometry"],
            "source_bounds": {
                "min": self.pending["source_min"].tolist(),
                "max": self.pending["source_max"].tolist(),
                "margin": self.source_margin,
            },
            "samples": [
                {"raw": [float(x), float(y)], "target": list(point)}
                for (x, y), (_, point) in zip(self.pending["raws"], self.samples)
            ],
            "validation": self.validation[:],
        }
        try:
            self.path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError as exc:
            self.validation.pop()
            emit({"type": "calibration", "status": "save_failed", "message": f"Failed to save calibration: {exc}"})
            return
        self.matrix = self.pending["matrix"]
        self.rbf = rbf
        self.geometry = self.pending["geometry"]
        self.source_min = self.pending["source_min"]
        self.source_max = self.pending["source_max"]
        self.pending = None
        self.validation_retries = 0
        emit({"type": "calibration", "status": "saved", "path": str(self.path), "geometry": self.geometry})

    def reject_fit(self, message: str) -> None:
        self.samples.clear()
        self.validation.clear()
        self.pending = None
        self.validation_retries = 0
        emit({"type": "calibration", "status": "rejected_fit", "message": message})


def stable_feature_sample(samples: list[tuple[float, GazeFeature]], now: float) -> tuple[GazeFeature | None, str | None]:
    recent = [feature for at, feature in samples if 0 <= now - at <= 0.9 and all(map(math.isfinite, feature.point))]
    if len(recent) < 3:
        return None, "Need at least three fresh gaze frames"
    point = (
        statistics.median(feature.point[0] for feature in recent),
        statistics.median(feature.point[1] for feature in recent),
    )
    if statistics.median(math.dist(feature.point, point) for feature in recent) > 0.06:
        return None, "Gaze is moving; hold still and retry"
    if statistics.median(feature.eye_open for feature in recent) < BLINK_OPEN_THRESHOLD:
        return None, "Eyes appear closed; keep them open"

    def med(field: str) -> float:
        return float(statistics.median(getattr(feature, field) for feature in recent))

    def med2(field: str) -> tuple[float, float]:
        return (
            float(statistics.median(getattr(feature, field)[0] for feature in recent)),
            float(statistics.median(getattr(feature, field)[1] for feature in recent)),
        )

    return GazeFeature(
        point=point,
        eye_center_px=med2("eye_center_px"),
        left_eye_px=med2("left_eye_px"),
        right_eye_px=med2("right_eye_px"),
        left_yaw_deg=med("left_yaw_deg"),
        left_pitch_deg=med("left_pitch_deg"),
        right_yaw_deg=med("right_yaw_deg"),
        right_pitch_deg=med("right_pitch_deg"),
        head_width_px=med("head_width_px"),
        iris_diameter_px=med("iris_diameter_px"),
        eye_open=med("eye_open"),
        distance_m=med("distance_m"),
    ), None


class GazeJumpGate:
    def __init__(self) -> None:
        self.accepted: tuple[float, tuple[float, float]] | None = None
        self.candidate: tuple[float, tuple[float, float]] | None = None

    def accept(self, point: tuple[float, float], at: float) -> tuple[float, float] | None:
        if not all(map(math.isfinite, point)):
            return None
        previous = self.accepted
        confirmed = self.candidate is not None and at - self.candidate[0] <= 0.5 and math.dist(point, self.candidate[1]) <= 0.12
        if previous is None or at - previous[0] > 1.0 or math.dist(point, previous[1]) <= 0.35 or confirmed:
            self.accepted = (at, point)
            self.candidate = None
            return point
        self.candidate = (at, point)
        return None


class CommandReader(threading.Thread):
    def __init__(self, commands: queue.Queue[dict[str, Any]]) -> None:
        super().__init__(daemon=True)
        self.commands = commands

    def run(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.commands.put(json.loads(line))
            except json.JSONDecodeError as exc:
                emit({"type": "status", "level": "warning", "message": f"Invalid command JSON: {exc}"})


class ScreenProjector:
    def __init__(
        self,
        display: DisplayGeometry,
        flip_x: bool = True,
        flip_y: bool = True,
        camera_screen_x: float = 0.5,
        camera_screen_y: float = 0.0,
        eye_position_weight_x: float = 1.0,
        eye_position_weight_y: float = 0.25,
        camera_fov_deg: float = CAMERA_HORIZONTAL_FOV_DEG,
        camera_width: int = CAMERA_WIDTH,
        camera_height: int = CAMERA_HEIGHT,
    ) -> None:
        self.display = display
        self.flip_x = flip_x
        self.flip_y = flip_y
        self.camera_width = max(1, int(camera_width))
        self.camera_height = max(1, int(camera_height))
        self.camera_screen_x = clamp01(camera_screen_x)
        self.camera_screen_y = clamp01(camera_screen_y)
        self.eye_position_weight_x = max(0.0, min(1.0, eye_position_weight_x))
        self.eye_position_weight_y = max(0.0, min(1.0, eye_position_weight_y))
        self.camera_fov_deg = valid_camera_fov_deg(camera_fov_deg)
        self.focal_px = self.camera_width / (2.0 * math.tan(math.radians(self.camera_fov_deg) * 0.5))
        self.focal_scale = 1.0

    @property
    def effective_focal_px(self) -> float:
        return self.focal_px * self.focal_scale

    def effective_fov_deg(self) -> float:
        return math.degrees(2.0 * math.atan(self.camera_width / (2.0 * self.effective_focal_px)))

    def retune(self, focal_scale: float | None, weight_x: float | None, weight_y: float | None) -> None:
        if focal_scale is not None and math.isfinite(focal_scale) and focal_scale > 0.0:
            self.focal_scale = float(focal_scale)
        if weight_x is not None and math.isfinite(weight_x):
            self.eye_position_weight_x = max(0.0, min(1.0, weight_x))
        if weight_y is not None and math.isfinite(weight_y):
            self.eye_position_weight_y = max(0.0, min(1.0, weight_y))

    def distance_from_head(self, head: Detection, width_ratio: float = 1.0) -> float:
        corrected_width_px = max(1.0, head.width * width_ratio)
        return (AVERAGE_HEAD_WIDTH_M * self.effective_focal_px) / corrected_width_px

    def distance_from_iris(self, iris_diameter_px: float) -> float:
        return IRIS_DIAMETER_M * self.effective_focal_px / max(1.0, iris_diameter_px)

    def project(
        self,
        eye_center_px: tuple[float, float],
        yaw_deg: float,
        pitch_deg: float,
        distance_m: float,
    ) -> tuple[float, float]:
        return self._normalize_hit_m(self._screen_hit_m(eye_center_px, yaw_deg, pitch_deg, distance_m))

    def project_estimate(
        self,
        mode: str,
        eyes: list[Detection],
        estimate: GazeEstimate,
        distance_m: float,
    ) -> ProjectionResult:
        eye_center = (
            (eyes[0].center[0] + eyes[1].center[0]) * 0.5,
            (eyes[0].center[1] + eyes[1].center[1]) * 0.5,
        )
        legacy = self.project(eye_center, estimate.yaw_deg, estimate.pitch_deg, distance_m)
        if mode == "legacy":
            return ProjectionResult(legacy)
        if mode == "binocular-screen":
            left_hit = self._screen_hit_m(eyes[0].center, estimate.left_yaw_deg, estimate.left_pitch_deg, distance_m)
            right_hit = self._screen_hit_m(eyes[1].center, estimate.right_yaw_deg, estimate.right_pitch_deg, distance_m)
            hit = ((left_hit[0] + right_hit[0]) * 0.5, (left_hit[1] + right_hit[1]) * 0.5)
            if math.isfinite(hit[0]) and math.isfinite(hit[1]):
                return ProjectionResult(self._normalize_hit_m(hit))
            return ProjectionResult(legacy, "binocular-screen produced a non-finite hit point")
        if mode == "binocular-convergence":
            convergence = self._convergence_hit_m(
                eyes[0].center,
                estimate.left_yaw_deg,
                estimate.left_pitch_deg,
                eyes[1].center,
                estimate.right_yaw_deg,
                estimate.right_pitch_deg,
                distance_m,
            )
            if isinstance(convergence, str):
                return ProjectionResult(legacy, convergence)
            return ProjectionResult(self._normalize_hit_m(convergence))
        return ProjectionResult(legacy, f"Unsupported gaze projection mode: {mode}")

    def _eye_origin_m(self, eye_center_px: tuple[float, float], distance_m: float) -> tuple[float, float]:
        display_w_m, display_h_m = self.display.size_m
        eye_x_m = (eye_center_px[0] - self.camera_width * 0.5) * distance_m / self.effective_focal_px * self.eye_position_weight_x
        eye_y_m = (eye_center_px[1] - self.camera_height * 0.5) * distance_m / self.effective_focal_px * self.eye_position_weight_y
        return display_w_m * self.camera_screen_x + eye_x_m, display_h_m * self.camera_screen_y + eye_y_m

    def project_features(
        self,
        feature: GazeFeature,
        mode: str = "binocular-screen",
        focal_scale: float = 1.0,
        weight_x: float | None = None,
        weight_y: float | None = None,
        use_iris: bool = True,
    ) -> tuple[float, float]:
        focal_px = self.focal_px * max(1.0e-6, focal_scale)
        distance_m = feature_distance_m(feature, focal_px, use_iris)
        wx = self.eye_position_weight_x if weight_x is None else max(0.0, min(1.0, weight_x))
        wy = self.eye_position_weight_y if weight_y is None else max(0.0, min(1.0, weight_y))
        display_w_m, display_h_m = self.display.size_m

        def origin(eye_px: tuple[float, float]) -> tuple[float, float]:
            return (
                display_w_m * self.camera_screen_x
                + (eye_px[0] - self.camera_width * 0.5) * distance_m / focal_px * wx,
                display_h_m * self.camera_screen_y
                + (eye_px[1] - self.camera_height * 0.5) * distance_m / focal_px * wy,
            )

        def hit(eye_px: tuple[float, float], yaw_deg: float, pitch_deg: float) -> tuple[float, float]:
            origin_x, origin_y = origin(eye_px)
            pitch_y_m = math.tan(math.radians(pitch_deg)) * distance_m
            if self.flip_y:
                pitch_y_m = -pitch_y_m
            return origin_x + math.tan(math.radians(yaw_deg)) * distance_m, origin_y + pitch_y_m

        if mode == "legacy":
            hit_m = hit(
                feature.eye_center_px,
                (feature.left_yaw_deg + feature.right_yaw_deg) * 0.5,
                (feature.left_pitch_deg + feature.right_pitch_deg) * 0.5,
            )
        else:
            left_hit = hit(feature.left_eye_px, feature.left_yaw_deg, feature.left_pitch_deg)
            right_hit = hit(feature.right_eye_px, feature.right_yaw_deg, feature.right_pitch_deg)
            hit_m = ((left_hit[0] + right_hit[0]) * 0.5, (left_hit[1] + right_hit[1]) * 0.5)
        return self._normalize_hit_m(hit_m)

    def _screen_hit_m(
        self,
        eye_center_px: tuple[float, float],
        yaw_deg: float,
        pitch_deg: float,
        distance_m: float,
    ) -> tuple[float, float]:
        eye_x_m, eye_y_m = self._eye_origin_m(eye_center_px, distance_m)
        hit_x_m = eye_x_m + math.tan(math.radians(yaw_deg)) * distance_m
        pitch_y_m = math.tan(math.radians(pitch_deg)) * distance_m
        if self.flip_y:
            pitch_y_m = -pitch_y_m
        hit_y_m = eye_y_m + pitch_y_m
        return hit_x_m, hit_y_m

    def _normalize_hit_m(self, hit_m: tuple[float, float]) -> tuple[float, float]:
        display_w_m, display_h_m = self.display.size_m
        hit_x_m, hit_y_m = hit_m
        x_norm = hit_x_m / display_w_m
        if self.flip_x:
            x_norm = 1.0 - x_norm
        return x_norm, hit_y_m / display_h_m

    def _gaze_direction(self, yaw_deg: float, pitch_deg: float) -> np.ndarray:
        pitch_tan = math.tan(math.radians(pitch_deg))
        if self.flip_y:
            pitch_tan = -pitch_tan
        direction = np.asarray([math.tan(math.radians(yaw_deg)), pitch_tan, 1.0], dtype=np.float64)
        norm = np.linalg.norm(direction)
        if not math.isfinite(float(norm)) or norm <= 1.0e-9:
            raise ValueError("Invalid gaze direction")
        return direction / norm

    def _convergence_hit_m(
        self,
        left_center_px: tuple[float, float],
        left_yaw_deg: float,
        left_pitch_deg: float,
        right_center_px: tuple[float, float],
        right_yaw_deg: float,
        right_pitch_deg: float,
        distance_m: float,
    ) -> tuple[float, float] | str:
        try:
            left_origin_xy = self._eye_origin_m(left_center_px, distance_m)
            right_origin_xy = self._eye_origin_m(right_center_px, distance_m)
            p1 = np.asarray([left_origin_xy[0], left_origin_xy[1], 0.0], dtype=np.float64)
            p2 = np.asarray([right_origin_xy[0], right_origin_xy[1], 0.0], dtype=np.float64)
            d1 = self._gaze_direction(left_yaw_deg, left_pitch_deg)
            d2 = self._gaze_direction(right_yaw_deg, right_pitch_deg)
        except ValueError as exc:
            return str(exc)

        b = float(np.dot(d1, d2))
        denom = 1.0 - b * b
        if denom <= 1.0e-6:
            return "binocular-convergence rays are nearly parallel"

        w0 = p1 - p2
        d = float(np.dot(d1, w0))
        e = float(np.dot(d2, w0))
        t = (b * e - d) / denom
        u = (e - b * d) / denom
        if t <= 0.0 or u <= 0.0:
            return "binocular-convergence intersection is behind the eye plane"

        closest_left = p1 + t * d1
        closest_right = p2 + u * d2
        closest_distance = float(np.linalg.norm(closest_left - closest_right))
        max_closest_distance = 0.20
        if closest_distance > max_closest_distance:
            return "binocular-convergence rays do not meet closely"

        midpoint = (closest_left + closest_right) * 0.5
        if not np.all(np.isfinite(midpoint)):
            return "binocular-convergence produced a non-finite point"
        if midpoint[2] <= 0.0 or midpoint[2] > distance_m * 3.0:
            return "binocular-convergence depth is outside the expected range"
        return float(midpoint[0]), float(midpoint[1])


def display_size_arg(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0.0:
        raise argparse.ArgumentTypeError("display size must be a positive finite inch value")
    return parsed


def camera_fov_arg(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0.0 or parsed >= 180.0:
        raise argparse.ArgumentTypeError("camera FOV must be greater than 0 and less than 180 degrees")
    return parsed


def normalize_camera_resolution_name(value: str) -> str:
    return "".join(ch.lower() for ch in value if ch.isalnum())


def camera_resolution_arg(value: str) -> CameraResolution:
    raw = value.strip()
    size_match = re.fullmatch(r"(\d+)\s*[xX×]\s*(\d+)", raw)
    if size_match is not None:
        width = int(size_match.group(1))
        height = int(size_match.group(2))
        if width <= 0 or height <= 0:
            raise argparse.ArgumentTypeError("camera resolution width and height must be positive integers")
        return CameraResolution(None, width, height)

    normalized = normalize_camera_resolution_name(raw)
    if normalized in REJECTED_CAMERA_RESOLUTION_NAMES:
        raise argparse.ArgumentTypeError(f"camera resolution alias is not accepted; use WIDTHxHEIGHT instead: {value}")
    preset = CAMERA_RESOLUTION_PRESETS.get(normalized)
    if preset is None:
        raise argparse.ArgumentTypeError(f"unknown camera resolution: {value}")
    return preset


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--detector", choices=["retinaface", "yolo"], default="retinaface")
    parser.add_argument("--backend", choices=["tensorrt", "cuda", "cpu"], default="tensorrt")
    parser.add_argument("--camera", default="0")
    parser.add_argument("--camera-resolution", type=camera_resolution_arg, default=DEFAULT_CAMERA_RESOLUTION)
    parser.add_argument("--camera-fov", type=camera_fov_arg, default=CAMERA_HORIZONTAL_FOV_DEG)
    parser.add_argument("--score-threshold", type=float, default=0.50)
    parser.add_argument("--display-size-inch", type=display_size_arg, default=31.5)
    parser.add_argument("--display-width", type=int, default=1920)
    parser.add_argument("--display-height", type=int, default=1080)
    parser.add_argument("--calibration-file", type=Path, default=DEFAULT_CALIBRATION_FILE)
    parser.add_argument("--detector-model", type=Path, default=None)
    parser.add_argument("--retinaface-model", type=Path, default=DEFAULT_RETINAFACE_MODEL)
    parser.add_argument("--yolo-model", type=Path, default=DEFAULT_YOLO_MODEL)
    parser.add_argument("--gaze-model", type=Path, default=DEFAULT_GAZE_MODEL)
    parser.add_argument("--lip-motion-model", type=Path, default=DEFAULT_LIP_MOTION_MODEL)
    parser.add_argument("--enable-lip-motion", action="store_true")
    parser.add_argument("--smoothing-alpha", type=float, default=0.65)
    parser.add_argument("--smoothing-alpha-y", type=float, default=0.45)
    parser.add_argument("--preview-fps", type=float, default=8.0)
    parser.add_argument("--hide-preview", action="store_true")
    parser.add_argument("--no-flip-x", action="store_true")
    parser.add_argument("--no-flip-y", action="store_true")
    parser.add_argument("--camera-screen-x", type=float, default=0.5)
    parser.add_argument("--camera-screen-y", type=float, default=0.0)
    parser.add_argument("--eye-position-weight-x", type=float, default=1.0)
    parser.add_argument("--eye-position-weight-y", type=float, default=0.25)
    parser.add_argument("--retinaface-head-face-ratio", type=float, default=RETINAFACE_HEAD_FACE_WIDTH_RATIO)
    parser.add_argument(
        "--gaze-projection-mode",
        choices=["legacy", "binocular-screen", "binocular-convergence"],
        default="legacy",
    )
    parser.add_argument("--gaze-filter", choices=["saccade", "oneeuro", "ema"], default="saccade")
    parser.add_argument("--gaze-max-fps", type=float, default=20.0)
    parser.add_argument("--filter-mincutoff", type=float, default=1.0)
    parser.add_argument("--filter-beta", type=float, default=0.7)
    parser.add_argument("--filter-dcutoff", type=float, default=1.0)
    parser.add_argument("--no-iris-distance", action="store_true")
    return parser.parse_args()


def camera_arg(value: str) -> int | str:
    try:
        return int(value)
    except ValueError:
        return value


def handle_commands(
    commands: queue.Queue[dict[str, Any]],
    calibration: Calibration,
    recent_features: list[tuple[float, GazeFeature]],
) -> None:
    while True:
        try:
            command = commands.get_nowait()
        except queue.Empty:
            return
        if command.get("type") == "calibration_capture":
            target = command.get("target")
            if not isinstance(target, list) or len(target) != 2:
                emit({"type": "calibration", "status": "invalid_target"})
                continue
            feature, reason = stable_feature_sample(recent_features, time.monotonic())
            if feature is None:
                emit({"type": "calibration", "status": "unstable", "message": reason})
                continue
            target_point = (clamp01(float(target[0])), clamp01(float(target[1])))
            if command.get("validation"):
                calibration.validate(feature, target_point)
            else:
                calibration.capture(feature, target_point)


def apply_calibration_geometry(projector: ScreenProjector, calibration: Calibration) -> None:
    geometry = calibration.geometry
    if not geometry:
        return
    key = (
        float(geometry.get("eye_position_weight_x", projector.eye_position_weight_x)),
        float(geometry.get("eye_position_weight_y", projector.eye_position_weight_y)),
    )
    if getattr(projector, "_applied_geometry", None) == key:
        return
    projector.retune(None, key[0], key[1])
    projector._applied_geometry = key
    emit(
        {
            "type": "status",
            "level": "info",
            "message": f"Applied calibrated camera geometry: eye weights=({key[0]:.2f},{key[1]:.2f})",
            "eye_position_weight_x": projector.eye_position_weight_x,
            "eye_position_weight_y": projector.eye_position_weight_y,
        }
    )


def idle_command_loop(commands: queue.Queue[dict[str, Any]], calibration: Calibration) -> None:
    while True:
        handle_commands(commands, calibration, [])
        time.sleep(0.25)


def main() -> None:
    args = parse_args()
    camera_resolution: CameraResolution = args.camera_resolution
    display = DisplayGeometry(args.display_width, args.display_height, args.display_size_inch)
    calibration = Calibration(args.calibration_file)
    commands: queue.Queue[dict[str, Any]] = queue.Queue()
    CommandReader(commands).start()

    detector_model = args.detector_model
    if detector_model is None:
        detector_model = args.retinaface_model if args.detector == "retinaface" else args.yolo_model
    if args.detector == "retinaface":
        detector = RetinaFaceEyeDetector(detector_model, args.backend, args.score_threshold)
    else:
        detector = YoloWholebodyDetector(detector_model, args.backend, args.score_threshold)
    head_face_width_ratio = args.retinaface_head_face_ratio if args.detector == "retinaface" else 1.0
    lip_motion_enabled = args.enable_lip_motion and args.detector == "yolo"
    if args.enable_lip_motion and args.detector != "yolo":
        emit(
            {
                "type": "status",
                "level": "warning",
                "message": "--enable-lip-motion requires --detector yolo; disabling lip motion",
                "detector": args.detector,
            }
        )
    lip_motion = LipMotionEstimator(args.lip_motion_model, args.backend) if lip_motion_enabled else None
    gaze = GazeEstimator(args.gaze_model, args.backend)
    projector = ScreenProjector(
        display,
        flip_x=not args.no_flip_x,
        flip_y=not args.no_flip_y,
        camera_screen_x=args.camera_screen_x,
        camera_screen_y=args.camera_screen_y,
        eye_position_weight_x=args.eye_position_weight_x,
        eye_position_weight_y=args.eye_position_weight_y,
        camera_fov_deg=args.camera_fov,
        camera_width=camera_resolution.width,
        camera_height=camera_resolution.height,
    )
    calibration.reprojector = lambda feature, weight_x, weight_y: projector.project_features(
        feature,
        mode=args.gaze_projection_mode,
        weight_x=weight_x,
        weight_y=weight_y,
        use_iris=not args.no_iris_distance,
    )
    apply_calibration_geometry(projector, calibration)
    emit(
        {
            "type": "status",
            "level": "info",
            "message": "Models loaded",
            "detector": args.detector,
            "detector_model": str(detector_model),
            "detector_providers": detector.providers,
            "head_face_width_ratio": head_face_width_ratio,
            "camera_fov_deg": projector.camera_fov_deg,
            "camera_resolution_name": camera_resolution.name,
            "camera_width": camera_resolution.width,
            "camera_height": camera_resolution.height,
            "camera_screen_x": projector.camera_screen_x,
            "camera_screen_y": projector.camera_screen_y,
            "eye_position_weight_x": projector.eye_position_weight_x,
            "eye_position_weight_y": projector.eye_position_weight_y,
            "gaze_projection_mode": args.gaze_projection_mode,
            "gaze_filter": args.gaze_filter,
            "iris_distance_enabled": not args.no_iris_distance,
            "gaze_providers": gaze.providers,
            "lip_motion_enabled": lip_motion_enabled,
            "lip_motion_model": str(args.lip_motion_model) if lip_motion_enabled else None,
            "lip_motion_providers": lip_motion.providers if lip_motion is not None else None,
        }
    )
    gaze.warmup()

    cap = cv2.VideoCapture(camera_arg(args.camera))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, camera_resolution.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, camera_resolution.height)
    if not cap.isOpened():
        emit({"type": "status", "level": "error", "message": f"Camera could not be opened: {args.camera}"})
        idle_command_loop(commands, calibration)
    ok, first_frame = cap.read()
    if not ok:
        emit({"type": "status", "level": "error", "message": "Camera frame is not available"})
        idle_command_loop(commands, calibration)
    actual_height, actual_width = first_frame.shape[:2]
    if actual_width != camera_resolution.width or actual_height != camera_resolution.height:
        emit(
            {
                "type": "status",
                "level": "error",
                "message": (
                    f"Camera returned {actual_width}x{actual_height}, "
                    f"expected {camera_resolution.width}x{camera_resolution.height}"
                ),
                "camera_resolution_name": camera_resolution.name,
                "camera_width": camera_resolution.width,
                "camera_height": camera_resolution.height,
            }
        )
        idle_command_loop(commands, calibration)

    smoothed: tuple[float, float] | None = None
    smoothed_distance: float | None = None
    blinking = False
    recent_features: list[tuple[float, GazeFeature]] = []
    jump_gate = GazeJumpGate()
    filter_x = OneEuroFilter(args.filter_mincutoff, args.filter_beta, args.filter_dcutoff)
    filter_y = OneEuroFilter(args.filter_mincutoff, args.filter_beta, args.filter_dcutoff)
    last_status = 0.0
    last_preview = 0.0
    last_projection_warning = 0.0
    preview_interval = 1.0 / max(0.5, args.preview_fps)
    pending_frame: np.ndarray | None = first_frame

    try:
        while True:
            handle_commands(commands, calibration, recent_features)
            apply_calibration_geometry(projector, calibration)
            if pending_frame is None:
                ok, frame = cap.read()
            else:
                ok, frame = True, pending_frame
                pending_frame = None
            if not ok:
                now = time.monotonic()
                if now - last_status > 1.0:
                    emit({"type": "status", "level": "warning", "message": "Camera frame is not available"})
                    last_status = now
                time.sleep(0.05)
                continue
            try:
                detect_start = time.perf_counter()
                detection = detector.detect(frame)
                head, eyes, mouth = detection.head, detection.eyes, detection.mouth
                detect_inference_ms = (time.perf_counter() - detect_start) * 1000.0
                now = time.monotonic()
                should_emit_preview = not args.hide_preview and now - last_preview >= preview_interval
                if should_emit_preview and (head is None or len(eyes) < 2):
                    preview_message = None
                    if head is None:
                        preview_message = "Head not detected"
                    else:
                        preview_message = f"Eyes detected: {len(eyes)}"
                    emit_preview(
                        frame,
                        head,
                        eyes,
                        mouth,
                        preview_message,
                        head_face_width_ratio if args.detector == "retinaface" else None,
                    )
                    last_preview = now
                if head is None:
                    raise ValueError("Head was not detected")
                if len(eyes) < 2:
                    raise ValueError("Two eyes were not detected")
                gaze_start = time.perf_counter()
                gaze_estimate = gaze.estimate(frame, head, eyes)
                gaze_inference_ms = (time.perf_counter() - gaze_start) * 1000.0
                mouth_open_probability: float | None = None
                mouth_open: bool | None = None
                lip_motion_inference_ms: float | None = None
                if lip_motion is not None:
                    if mouth is not None:
                        lip_motion_start = time.perf_counter()
                        mouth_open_probability = lip_motion.estimate(frame, mouth)
                        lip_motion_inference_ms = (time.perf_counter() - lip_motion_start) * 1000.0
                        mouth_open = bool(mouth_open_probability >= LIP_MOTION_OPEN_THRESHOLD)
                    else:
                        mouth_open = False
                eye_open = gaze_estimate.eye_open
                blinking = update_blink_state(blinking, eye_open)
                head_width_px = head.width * head_face_width_ratio
                left_eye_cx, left_eye_cy = eyes[0].center
                right_eye_cx, right_eye_cy = eyes[1].center
                eye_span_px = math.hypot(right_eye_cx - left_eye_cx, right_eye_cy - left_eye_cy)
                head_turned = is_head_turned(eye_span_px, head_width_px)
                frozen = blinking or head_turned
                if should_emit_preview:
                    emit_preview(
                        frame,
                        head,
                        eyes,
                        mouth,
                        "Blink" if blinking else "Head turned" if head_turned else None,
                        head_face_width_ratio if args.detector == "retinaface" else None,
                        (gaze_estimate.yaw_deg, gaze_estimate.pitch_deg),
                        (gaze_estimate.left_iris_px, gaze_estimate.right_iris_px),
                    )
                    last_preview = now
                head_distance_m = projector.distance_from_head(head, width_ratio=head_face_width_ratio)
                iris_distance_m: float | None = None
                if not args.no_iris_distance and math.isfinite(gaze_estimate.iris_diameter_px) and gaze_estimate.iris_diameter_px >= 2.0:
                    candidate = projector.distance_from_iris(gaze_estimate.iris_diameter_px)
                    if DISTANCE_MIN_M <= candidate <= DISTANCE_MAX_M:
                        iris_distance_m = candidate
                raw_distance_m = iris_distance_m if iris_distance_m is not None else head_distance_m
                distance_source = "iris" if iris_distance_m is not None else "head"
                if smoothed_distance is None:
                    smoothed_distance = raw_distance_m
                else:
                    smoothed_distance += DISTANCE_SMOOTHING_ALPHA * (raw_distance_m - smoothed_distance)
                distance_m = smoothed_distance
                if frozen:
                    if smoothed is not None:
                        emit(
                            {
                                "type": "gaze",
                                "x_norm": clamp01(smoothed[0]),
                                "y_norm": clamp01(smoothed[1]),
                                "confidence": 0.0,
                                "distance_m": distance_m,
                                "iris_distance_m": iris_distance_m,
                                "distance_source": distance_source,
                                "eye_open": eye_open,
                                "blink": blinking,
                                "head_turned": head_turned,
                                "yaw_deg": gaze_estimate.yaw_deg,
                                "pitch_deg": gaze_estimate.pitch_deg,
                            }
                        )
                    continue
                projection = projector.project_estimate(args.gaze_projection_mode, eyes, gaze_estimate, distance_m)
                if projection.fallback_reason is not None and now - last_projection_warning > 2.0:
                    emit(
                        {
                            "type": "status",
                            "level": "warning",
                            "message": f"{projection.fallback_reason}; falling back to legacy projection",
                            "gaze_projection_mode": args.gaze_projection_mode,
                        }
                    )
                    last_projection_warning = now
                raw = jump_gate.accept(projection.point, time.monotonic())
                if raw is None:
                    continue
                sample_at = time.monotonic()
                feature = GazeFeature(
                    point=raw,
                    eye_center_px=(
                        (left_eye_cx + right_eye_cx) * 0.5,
                        (left_eye_cy + right_eye_cy) * 0.5,
                    ),
                    left_eye_px=eyes[0].center,
                    right_eye_px=eyes[1].center,
                    left_yaw_deg=gaze_estimate.left_yaw_deg,
                    left_pitch_deg=gaze_estimate.left_pitch_deg,
                    right_yaw_deg=gaze_estimate.right_yaw_deg,
                    right_pitch_deg=gaze_estimate.right_pitch_deg,
                    head_width_px=head_width_px,
                    iris_diameter_px=gaze_estimate.iris_diameter_px,
                    eye_open=eye_open,
                    distance_m=distance_m,
                )
                recent_features.append((sample_at, feature))
                recent_features[:] = [(at, item) for at, item in recent_features if sample_at - at <= 0.9]
                corrected = calibration.apply(raw)
                if args.gaze_filter == "oneeuro":
                    smoothed = (filter_x.filter(corrected[0], sample_at), filter_y.filter(corrected[1], sample_at))
                elif smoothed is None:
                    smoothed = corrected
                else:
                    alpha_x = max(0.0, min(0.95, args.smoothing_alpha))
                    alpha_y = max(0.0, min(0.95, args.smoothing_alpha_y))
                    smoothed = (
                        alpha_x * smoothed[0] + (1.0 - alpha_x) * corrected[0],
                        alpha_y * smoothed[1] + (1.0 - alpha_y) * corrected[1],
                    )
                confidence = min(head.score, (eyes[0].score + eyes[1].score) * 0.5)
                confidence *= clamp01(eye_open)
                confidence *= max(0.2, gaze_estimate.agreement)
                payload = {
                    "type": "gaze",
                    "x_norm": clamp01(smoothed[0]),
                    "y_norm": clamp01(smoothed[1]),
                    "raw_x_norm": raw[0],
                    "raw_y_norm": raw[1],
                    "confidence": confidence,
                    "distance_m": distance_m,
                    "iris_distance_m": iris_distance_m,
                    "distance_source": distance_source,
                    "eye_open": eye_open,
                    "blink": False,
                    "gaze_filter": args.gaze_filter,
                    "head_face_width_ratio": head_face_width_ratio,
                    "eye_position_weight_x": projector.eye_position_weight_x,
                    "eye_position_weight_y": projector.eye_position_weight_y,
                    "gaze_projection_mode": args.gaze_projection_mode,
                    "detect_inference_ms": detect_inference_ms,
                    "gaze_inference_ms": gaze_inference_ms,
                    "inference_ms": detect_inference_ms + gaze_inference_ms + (lip_motion_inference_ms or 0.0),
                    "yaw_deg": gaze_estimate.yaw_deg,
                    "pitch_deg": gaze_estimate.pitch_deg,
                }
                if lip_motion_enabled:
                    payload.update(
                        {
                            "mouth_detected": mouth is not None,
                            "mouth_open": mouth_open,
                            "mouth_open_probability": mouth_open_probability,
                            "lip_motion_inference_ms": lip_motion_inference_ms,
                        }
                    )
                emit(payload)
            except Exception as exc:
                now = time.monotonic()
                if now - last_status > 1.0:
                    emit({"type": "status", "level": "warning", "message": str(exc)})
                    last_status = now
            time.sleep(0.001)
    finally:
        cap.release()


if __name__ == "__main__":
    main()
