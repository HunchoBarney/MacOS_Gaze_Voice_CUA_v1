import type { BackendMessage, WebAccelerator, WebInferenceConfig } from "../global";
import { logStatus } from "../logger";
import {
  Calibration,
  DisplayGeometry,
  DISTANCE_MAX_M,
  DISTANCE_MIN_M,
  DISTANCE_SMOOTHING_ALPHA,
  GazeAngleSmoother,
  GazeJumpGate,
  LIP_MOTION_OPEN_THRESHOLD,
  OneEuroFilter,
  PREVIEW_WIDTH,
  previewHeightFor,
  renderPreviewAnnotations,
  SaccadeAwareGazeFilter,
  ScreenProjector,
  center,
  clamp01,
  isHeadTurned,
  reanchorDetection,
  stableFeatureSample,
  updateBlinkState,
  type GazeEstimate,
  type GazeFeature,
  type TimedFeature,
  height,
  type Detection,
  width
} from "./core";
import { createRuntimeModels, warmupRuntimeModels, type RuntimeModels } from "./runtimes";

type MainToWorkerMessage =
  | { type: "init"; config: WebInferenceConfig }
  | {
      type: "frame";
      data?: Uint8ClampedArray<ArrayBuffer>;
      bitmap?: ImageBitmap;
      width: number;
      height: number;
      captureMs: number;
      frameIntervalMs?: number;
      droppedFrames: number;
      mainThreadLongTasks: number;
    }
  | { type: "capture_calibration"; target: [number, number]; validation: boolean }
  | { type: "stop" }
  | {
      type: "calibration_read_result";
      id: number;
      response: { ok: true; text: string | null } | { ok: false; error: string };
    }
  | {
      type: "calibration_write_result";
      id: number;
      response: { ok: true; path: string } | { ok: false; error: string };
    };

type WorkerToMainMessage =
  | { type: "ready" }
  | { type: "frame_done" }
  | { type: "backend"; payload: BackendMessage }
  | { type: "calibration_read"; id: number; path: string }
  | { type: "calibration_write"; id: number; path: string; payload: unknown };

let config: WebInferenceConfig | null = null;
let models: RuntimeModels | null = null;
let calibration: Calibration | null = null;
let projector: ScreenProjector | null = null;
let latestRaw: [number, number] | null = null;
const recentFeatures: TimedFeature[] = [];
let jumpGate = new GazeJumpGate();
let smoothed: [number, number] | null = null;
let smoothedDistance: number | null = null;
let blinking = false;
let filterX = new OneEuroFilter();
let filterY = new OneEuroFilter();
let saccadeFilter = new SaccadeAwareGazeFilter();
let angleSmoother = new GazeAngleSmoother();
let lastDetection: { head: Detection; eyes: Detection[]; mouth: Detection | null } | null = null;
let lastDetectMs = 0;
let forceRedetect = false;
let frameCanvas: OffscreenCanvas | null = null;
let frameCtx: OffscreenCanvasRenderingContext2D | null = null;
let appliedGeometryKey: string | null = null;
let lastStatus = 0;
let lastPreview = 0;
let lastProjectionWarning = 0;
// A/B isolation: keep detector boxes verbatim (no iris re-anchor) to test
// whether crop feedback drives the mesh's depth-channel collapse.
const DISABLE_REANCHOR_ABTEST = false;
let lastProcessed = 0;
let fallbackInProgress = false;
let lastEmitCore: { x: number; y: number; distance: number; yaw: number; pitch: number } | null = null;
let dropStreakStart = 0;

// On a dropped frame the marker should hold at the last stable pose rather
// than freeze-and-expire; hold emits carry the reason for diagnostics. After
// ~2s of continuous drops the marker is allowed to expire (real absence).
function emitHold(reason: string, rejectedRaw?: [number, number]): void {
  if (lastEmitCore === null) {
    return;
  }
  const now = performance.now();
  if (dropStreakStart === 0) {
    dropStreakStart = now;
  }
  if (now - dropStreakStart > 8000) {
    return;
  }
  emit({
    type: "gaze",
    x_norm: lastEmitCore.x,
    y_norm: lastEmitCore.y,
    raw_x_norm: rejectedRaw?.[0],
    raw_y_norm: rejectedRaw?.[1],
    confidence: 0.2,
    distance_m: lastEmitCore.distance,
    yaw_deg: lastEmitCore.yaw,
    pitch_deg: lastEmitCore.pitch,
    held_reason: reason
  });
}
let initializing = false;
let stopped = false;
let requestId = 0;
const pendingReads = new Map<number, (value: { ok: true; text: string | null } | { ok: false; error: string }) => void>();
const pendingWrites = new Map<number, (value: { ok: true; path: string } | { ok: false; error: string }) => void>();

const post = (message: WorkerToMainMessage) => {
  self.postMessage(message);
};

const DETECT_INTERVAL_MS = 1000;

function decodeFrame(message: Extract<MainToWorkerMessage, { type: "frame" }>): ImageData {
  if (frameCanvas === null || frameCanvas.width !== message.width || frameCanvas.height !== message.height) {
    frameCanvas = new OffscreenCanvas(message.width, message.height);
    frameCtx = frameCanvas.getContext("2d", { willReadFrequently: true });
  }
  if (frameCtx === null) {
    throw new Error("2D canvas context is not available in inference worker");
  }
  if (message.bitmap) {
    frameCtx.drawImage(message.bitmap, 0, 0);
    message.bitmap.close();
  } else if (message.data) {
    frameCtx.putImageData(new ImageData(message.data, message.width, message.height), 0, 0);
  } else {
    throw new Error("Frame message contained neither bitmap nor pixel data");
  }
  return frameCtx.getImageData(0, 0, message.width, message.height);
}

const emit = (payload: BackendMessage) => {
  post({ type: "backend", payload });
  if (
    payload.type === "calibration" &&
    (payload.status === "saved" || (payload.status === "geometry" && !config?.calibrate))
  ) {
    syncProjectorGeometry();
  }
};

function syncProjectorGeometry(): void {
  if (!projector || !calibration?.geometry) {
    return;
  }
  const key = `${calibration.geometry.eye_position_weight_x},${calibration.geometry.eye_position_weight_y}`;
  if (appliedGeometryKey === key) {
    return;
  }
  projector.retune(null, calibration.geometry.eye_position_weight_x, calibration.geometry.eye_position_weight_y);
  appliedGeometryKey = key;
  emit({
    type: "status",
    level: "info",
    message: `Applied calibrated camera geometry: eye weights=(${projector.eyePositionWeightX.toFixed(2)},${projector.eyePositionWeightY.toFixed(2)})`,
    eye_position_weight_x: projector.eyePositionWeightX,
    eye_position_weight_y: projector.eyePositionWeightY
  });
}

self.onmessage = (event: MessageEvent<MainToWorkerMessage>) => {
  void handleMessage(event.data);
};

async function handleMessage(message: MainToWorkerMessage): Promise<void> {
  if (message.type === "init") {
    await initialize(message.config);
  } else if (message.type === "frame") {
    await processFrameMessage(message);
  } else if (message.type === "capture_calibration") {
    await captureCalibration(message.target, message.validation);
  } else if (message.type === "stop") {
    stopped = true;
    models?.dispose();
    models = null;
  } else if (message.type === "calibration_read_result") {
    pendingReads.get(message.id)?.(message.response);
    pendingReads.delete(message.id);
  } else if (message.type === "calibration_write_result") {
    pendingWrites.get(message.id)?.(message.response);
    pendingWrites.delete(message.id);
  }
}

async function initialize(nextConfig: WebInferenceConfig): Promise<void> {
  config = nextConfig;
  initializing = true;
  stopped = false;
  latestRaw = null;
  recentFeatures.length = 0;
  jumpGate = new GazeJumpGate();
  smoothed = null;
  smoothedDistance = null;
  blinking = false;
  filterX = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  filterY = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  saccadeFilter = new SaccadeAwareGazeFilter();
  angleSmoother = new GazeAngleSmoother();
  lastDetection = null;
  lastDetectMs = 0;
  forceRedetect = false;
  appliedGeometryKey = null;
  lastStatus = 0;
  lastPreview = 0;
  lastProjectionWarning = 0;
  lastProcessed = 0;
  const headFaceWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1;
  projector = new ScreenProjector(
    new DisplayGeometry(config.displayWidth, config.displayHeight, config.displaySizeInch),
    config.flipX,
    config.flipY,
    config.cameraScreenX,
    config.cameraScreenY,
    config.eyePositionWeightX,
    config.eyePositionWeightY,
    config.cameraFov,
    config.cameraWidth,
    config.cameraHeight
  );
  calibration = new Calibration(
    config.calibrationFile,
    emit,
    {
      read: (path) => requestCalibrationRead(path),
      write: (path, payload) => requestCalibrationWrite(path, payload)
    },
    (feature, weightX, weightY) =>
      projector!.projectFeatures(feature, nextConfig.gazeProjectionMode, weightX, weightY, !nextConfig.disableIrisDistance)
  );
  await calibration.load();
  if (config.calibrate) {
    projector.retune(null, 1, 0.25);
    appliedGeometryKey = null;
  } else {
    syncProjectorGeometry();
  }
  try {
    emitLiteRtWorkerEnvironmentStatus();
    const preferredAccelerator: WebAccelerator = config.webAccelerator === "wasm" ? "wasm" : "webgpu";
    try {
      models = await createRuntimeModels(config, preferredAccelerator);
    } catch (error) {
      if (preferredAccelerator === "wasm") {
        throw error;
      }
      const payload: BackendMessage = {
        type: "status",
        level: "warning",
        message: `WebGPU model load failed in inference worker: ${error}; falling back to wasm`,
        runtime: config.runtime,
        accelerator: "webgpu",
        logged: true
      };
      logStatus(payload, error);
      emit(payload);
      models = await createRuntimeModels(config, "wasm");
    }
    emitLiteRtRuntimeLoadedStatus();
    emitModelsLoaded(headFaceWidthRatio);
    await warmupRuntimeModels(models);
    initializing = false;
    post({ type: "ready" });
  } catch (error) {
    initializing = false;
    emit({
      type: "status",
      level: "error",
      message: error instanceof Error ? error.message : String(error),
      runtime: config.runtime,
      logged: true
    });
  }
}

function emitLiteRtWorkerEnvironmentStatus(): void {
  if (!config || config.runtime !== "litert") {
    return;
  }
  emit({
    type: "status",
    level: "info",
    message: `LiteRT inference worker starting; WebGPU ${hasWorkerWebGpu() ? "available" : "unavailable"}; wasm assets ${config.liteRtWasmBaseUrl}`,
    runtime: config.runtime,
    accelerator: "webgpu",
    logged: true
  });
}

function emitLiteRtRuntimeLoadedStatus(): void {
  if (!config || !models || config.runtime !== "litert") {
    return;
  }
  emit({
    type: "status",
    level: "info",
    message: `LiteRT inference worker loaded; detector ${models.detectorProviders[0] ?? "unknown"} / gaze ${
      models.gazeProviders[0] ?? "unknown"
    }${models.lipMotionProviders.length > 0 ? ` / lip ${models.lipMotionProviders[0]}` : ""}`,
    runtime: config.runtime,
    accelerator: models.accelerator,
    detector_providers: models.detectorProviders,
    gaze_providers: models.gazeProviders,
    lip_motion_providers: models.lipMotionProviders,
    logged: true
  });
}

function hasWorkerWebGpu(): boolean {
  return typeof globalThis.navigator !== "undefined" && "gpu" in globalThis.navigator;
}

function emitModelsLoaded(headFaceWidthRatio: number): void {
  if (!config || !models) {
    return;
  }
  emit({
    type: "status",
    level: "info",
    message: "Models loaded in inference worker",
    runtime: config.runtime,
    accelerator: models.accelerator,
    detector: config.detector,
    detector_model: config.detectorModel,
    detector_providers: models.detectorProviders,
    head_face_width_ratio: headFaceWidthRatio,
    camera_fov_deg: config.cameraFov,
    camera_resolution_name: config.cameraResolutionName,
    camera_width: config.cameraWidth,
    camera_height: config.cameraHeight,
    camera_screen_x: config.cameraScreenX,
    camera_screen_y: config.cameraScreenY,
    eye_position_weight_x: config.eyePositionWeightX,
    eye_position_weight_y: config.eyePositionWeightY,
    gaze_projection_mode: config.gazeProjectionMode,
    gaze_providers: models.gazeProviders,
    lip_motion_enabled: config.enableLipMotion && config.detector === "yolo",
    lip_motion_model: config.enableLipMotion && config.detector === "yolo" ? config.lipMotionModel : undefined,
    lip_motion_providers: models.lipMotionProviders
  });
}

async function processFrameMessage(message: Extract<MainToWorkerMessage, { type: "frame" }>): Promise<void> {
  try {
    if (
      stopped ||
      initializing ||
      fallbackInProgress ||
      config === null ||
      models === null ||
      calibration === null ||
      projector === null
    ) {
      return;
    }
    const frame = decodeFrame(message);
    const headFaceWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1;
    const previewWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : null;
    const previewInterval = 1000 / Math.max(0.5, config.previewFps);
    const detectStart = performance.now();
    const detectDue = lastDetection === null || forceRedetect || detectStart - lastDetectMs > DETECT_INTERVAL_MS;
    let head: Detection | null;
    let eyes: Detection[];
    let mouth: Detection | null;
    let detectInferenceMs = 0;
    let trackingSource: "detector" | "iris";
    if (detectDue) {
      const detected = await models.detect(frame);
      detectInferenceMs = performance.now() - detectStart;
      lastDetectMs = detectStart;
      forceRedetect = false;
      head = detected.head;
      eyes = detected.eyes;
      mouth = detected.mouth;
      trackingSource = "detector";
    } else {
      head = lastDetection!.head;
      eyes = lastDetection!.eyes;
      mouth = lastDetection!.mouth;
      trackingSource = "iris";
    }
    const now = performance.now();
    const processedIntervalMs = lastProcessed > 0 ? now - lastProcessed : message.frameIntervalMs;
    lastProcessed = now;
    const shouldEmitPreview = !config.hidePreview && now - lastPreview >= previewInterval;
    let previewMs = 0;
    if (head === null || eyes.length < 2) {
      lastDetection = null;
      forceRedetect = true;
      if (shouldEmitPreview) {
        const previewMessage = head === null ? "Head not detected" : `Eyes detected: ${eyes.length}`;
        previewMs = await emitWorkerPreview(frame, head, eyes, mouth, previewMessage, null, previewWidthRatio);
        lastPreview = now;
      }
      emitHold("no_face");
      throw new Error(head === null ? "Head was not detected" : "Two eyes were not detected");
    }
    lastDetection = { head, eyes, mouth };

    const gazeStart = performance.now();
    let gazeEstimate: GazeEstimate;
    try {
      gazeEstimate = await models.estimate(frame, head, eyes);
    } catch (error) {
      if (now - lastProjectionWarning > 1000) {
        const message = error instanceof Error ? error.message : String(error);
        const cropW = Math.max(width(head) / 1.5, Math.hypot(center(eyes[1])[0] - center(eyes[0])[0], center(eyes[1])[1] - center(eyes[0])[1])) * 1.5;
        console.info(
          `[gaze-diag] estimate_failed: ${message} | head=(${head.x1.toFixed(0)},${head.y1.toFixed(0)},${head.x2.toFixed(0)},${head.y2.toFixed(0)}) ` +
            `eyes=(${center(eyes[0])[0].toFixed(0)},${center(eyes[0])[1].toFixed(0)}) (${center(eyes[1])[0].toFixed(0)},${center(eyes[1])[1].toFixed(0)}) crop=${cropW.toFixed(0)}px`
        );
        lastProjectionWarning = now;
      }
      emitHold("estimate_failed");
      return;
    }
    const gaze = angleSmoother.update(gazeEstimate);
    const gazeEnd = performance.now();
    const gazeInferenceMs = gazeEnd - gazeStart;
    const reanchored = DISABLE_REANCHOR_ABTEST
      ? null
      : reanchorDetection(
          head,
          eyes,
          gaze.leftIrisCenterPx,
          gaze.rightIrisCenterPx,
          frame.width,
          frame.height
        );
    if (reanchored !== null) {
      lastDetection = {
        head: reanchored.head,
        eyes: reanchored.eyes,
        mouth:
          mouth === null
            ? null
            : { ...mouth, x1: mouth.x1 + reanchored.dx, y1: mouth.y1 + reanchored.dy, x2: mouth.x2 + reanchored.dx, y2: mouth.y2 + reanchored.dy }
      };
      if (Math.hypot(reanchored.dx, reanchored.dy) > 30) {
        forceRedetect = true;
      }
    } else {
      forceRedetect = true;
    }
    let lipMotionInferenceMs: number | undefined;
    let mouthOpenProbability: number | null | undefined;
    let mouthOpen: boolean | undefined;
    if (config.enableLipMotion && config.detector === "yolo") {
      if (mouth !== null) {
        const lipStart = performance.now();
        mouthOpenProbability = await models.estimateLipMotion(frame, mouth);
        lipMotionInferenceMs = performance.now() - lipStart;
        mouthOpen = typeof mouthOpenProbability === "number" && Number.isFinite(mouthOpenProbability) && mouthOpenProbability >= LIP_MOTION_OPEN_THRESHOLD;
      } else {
        mouthOpenProbability = null;
        mouthOpen = false;
      }
    }
    const eyeOpen = gaze.eyeOpen;
    blinking = updateBlinkState(blinking, eyeOpen);
    const headWidthPx = width(head) * headFaceWidthRatio;
    const [leftEyeCx, leftEyeCy] = center(eyes[0]);
    const [rightEyeCx, rightEyeCy] = center(eyes[1]);
    const eyeSpanPx = Math.hypot(rightEyeCx - leftEyeCx, rightEyeCy - leftEyeCy);
    const headTurned = isHeadTurned(eyeSpanPx, headWidthPx);
    const frozen = blinking || headTurned;
    if (shouldEmitPreview) {
      previewMs = await emitWorkerPreview(
        frame,
        head,
        eyes,
        mouth,
        blinking ? "Blink" : headTurned ? "Head turned" : null,
        [gaze.yawDeg, gaze.pitchDeg],
        previewWidthRatio,
        [gaze.leftIrisPx ?? [], gaze.rightIrisPx ?? []]
      );
      lastPreview = now;
    }
    const headDistanceM = projector.distanceFromHead(head, headFaceWidthRatio);
    let irisDistanceM: number | undefined;
    if (!config.disableIrisDistance && Number.isFinite(gaze.irisDiameterPx) && gaze.irisDiameterPx >= 2) {
      const candidate = projector.distanceFromIris(gaze.irisDiameterPx);
      if (candidate >= DISTANCE_MIN_M && candidate <= DISTANCE_MAX_M) {
        irisDistanceM = candidate;
      }
    }
    const rawDistanceM = irisDistanceM ?? headDistanceM;
    const distanceSource = irisDistanceM !== undefined ? "iris" : "head";
    smoothedDistance =
      smoothedDistance === null ? rawDistanceM : smoothedDistance + DISTANCE_SMOOTHING_ALPHA * (rawDistanceM - smoothedDistance);
    const distanceM = smoothedDistance;
    if (frozen) {
      if (smoothed !== null) {
        emit({
          type: "gaze",
          x_norm: clamp01(smoothed[0]),
          y_norm: clamp01(smoothed[1]),
          confidence: 0,
          distance_m: distanceM,
          iris_distance_m: irisDistanceM,
          distance_source: distanceSource,
          eye_open: eyeOpen,
          blink: blinking,
          head_turned: headTurned,
          yaw_deg: gaze.yawDeg,
          pitch_deg: gaze.pitchDeg
        });
      }
      return;
    }
    const projection = projector.projectEstimate(config.gazeProjectionMode, eyes, gaze, distanceM);
    if (projection.fallbackReason && now - lastProjectionWarning > 2000) {
      emit({
        type: "status",
        level: "warning",
        message: `${projection.fallbackReason}; falling back to legacy projection`,
        runtime: config.runtime,
        accelerator: models.accelerator,
        gaze_projection_mode: config.gazeProjectionMode,
        logged: true
      });
      lastProjectionWarning = now;
    }
    // Physical plausibility: a real screen hit can only land near the display —
    // a projected point beyond a full screen away is a broken estimate, and a
    // single bad frame must never teleport the marker.
    if (
      !Number.isFinite(projection.point[0]) ||
      !Number.isFinite(projection.point[1]) ||
      Math.abs(projection.point[0] - 0.5) > 1 ||
      Math.abs(projection.point[1] - 0.5) > 1
    ) {
      if (now - lastProjectionWarning > 1000) {
        console.info(
          `[gaze-diag] implausible raw=(${projection.point[0]?.toFixed(3)},${projection.point[1]?.toFixed(3)}) ` +
            `yaw=${gaze.yawDeg?.toFixed(1)} pitch=${gaze.pitchDeg?.toFixed(1)} ` +
            `L=(${gaze.leftYawDeg?.toFixed(1)},${gaze.leftPitchDeg?.toFixed(1)}) R=(${gaze.rightYawDeg?.toFixed(1)},${gaze.rightPitchDeg?.toFixed(1)}) ` +
            `d=${distanceM?.toFixed(2)} eyeL=(${leftEyeCx?.toFixed(0)},${leftEyeCy?.toFixed(0)}) eyeR=(${rightEyeCx?.toFixed(0)},${rightEyeCy?.toFixed(0)}) ` +
            `mode=${config.gazeProjectionMode} fov_eff=${projector.effectiveFovDeg().toFixed(0)}`
        );
        lastProjectionWarning = now;
      }
      emitHold("implausible_raw", projection.point);
      return;
    }
    const acceptedRaw = jumpGate.accept(projection.point, performance.now());
    if (acceptedRaw === null) {
      emitHold("jump_gate");
      return;
    }
    latestRaw = acceptedRaw;
    const sampleAt = performance.now();
    const feature: GazeFeature = {
      point: latestRaw,
      eyeCenterPx: [(leftEyeCx + rightEyeCx) * 0.5, (leftEyeCy + rightEyeCy) * 0.5],
      leftEyePx: [leftEyeCx, leftEyeCy],
      rightEyePx: [rightEyeCx, rightEyeCy],
      leftYawDeg: gaze.leftYawDeg,
      leftPitchDeg: gaze.leftPitchDeg,
      rightYawDeg: gaze.rightYawDeg,
      rightPitchDeg: gaze.rightPitchDeg,
      headWidthPx,
      irisDiameterPx: gaze.irisDiameterPx,
      eyeOpen,
      distanceM
    };
    recentFeatures.push({ feature, at: sampleAt });
    while (recentFeatures.length > 0 && sampleAt - recentFeatures[0].at > 900) recentFeatures.shift();
    const corrected = calibration.applyFeature(feature);
    const filterMode = config.gazeFilter ?? "saccade";
    if (filterMode === "oneeuro") {
      smoothed = [filterX.filter(corrected[0], sampleAt / 1000), filterY.filter(corrected[1], sampleAt / 1000)];
    } else if (filterMode === "ema") {
      if (smoothed === null) {
        smoothed = corrected;
      } else {
        const alphaX = Math.max(0, Math.min(0.95, config.smoothingAlpha));
        const alphaY = Math.max(0, Math.min(0.95, config.smoothingAlphaY));
        smoothed = [
          alphaX * smoothed[0] + (1 - alphaX) * corrected[0],
          alphaY * smoothed[1] + (1 - alphaY) * corrected[1]
        ];
      }
    } else {
      smoothed = saccadeFilter.update(corrected[0], corrected[1], sampleAt, gaze.yawDeg, gaze.pitchDeg);
    }
    dropStreakStart = 0;
    lastEmitCore = { x: clamp01(smoothed[0]), y: clamp01(smoothed[1]), distance: distanceM, yaw: gaze.yawDeg, pitch: gaze.pitchDeg };
    let confidence = Math.min(head.score, (eyes[0].score + eyes[1].score) * 0.5);
    confidence *= clamp01(eyeOpen);
    confidence *= Math.max(0.2, gaze.agreement);
    const payload: BackendMessage = {
      type: "gaze",
      x_norm: clamp01(smoothed[0]),
      y_norm: clamp01(smoothed[1]),
      raw_x_norm: latestRaw[0],
      raw_y_norm: latestRaw[1],
      confidence,
      distance_m: distanceM,
      iris_distance_m: irisDistanceM,
      distance_source: distanceSource,
      eye_open: eyeOpen,
      blink: false,
      gaze_filter: filterMode,
      tracking_source: trackingSource,
      filter_velocity_deg_s: filterMode === "saccade" ? saccadeFilter.velocityDegS : undefined,
      gaze_state: filterMode === "saccade" ? (saccadeFilter.inSaccade ? "saccade" : "fixation") : undefined,
      head_face_width_ratio: headFaceWidthRatio,
      eye_position_weight_x: projector.eyePositionWeightX,
      eye_position_weight_y: projector.eyePositionWeightY,
      gaze_projection_mode: config.gazeProjectionMode,
      detect_inference_ms: detectInferenceMs,
      gaze_inference_ms: gazeInferenceMs,
      lip_motion_inference_ms: lipMotionInferenceMs,
      inference_ms: detectInferenceMs + gazeInferenceMs + (lipMotionInferenceMs ?? 0),
      capture_ms: message.captureMs,
      preview_ms: previewMs,
      frame_interval_ms: processedIntervalMs,
      processed_fps: processedIntervalMs && processedIntervalMs > 0 ? 1000 / processedIntervalMs : undefined,
      dropped_frames: message.droppedFrames,
      main_thread_long_tasks: message.mainThreadLongTasks,
      yaw_deg: gaze.yawDeg,
      pitch_deg: gaze.pitchDeg
    };
    if (config.enableLipMotion && config.detector === "yolo") {
      payload.mouth_detected = mouth !== null;
      payload.mouth_open = mouthOpen;
      payload.mouth_open_probability = mouthOpenProbability;
    }
    emit(payload);
  } catch (error) {
    await handleFrameError(error);
  } finally {
    post({ type: "frame_done" });
  }
}

async function handleFrameError(error: unknown): Promise<void> {
  if (!config || !models) {
    return;
  }
  const now = performance.now();
  if (models.accelerator === "webgpu" && !fallbackInProgress && isRecoverableInferenceError(error)) {
    fallbackInProgress = true;
    const payload: BackendMessage = {
      type: "status",
      level: "warning",
      message: `WebGPU inference failed in worker: ${error instanceof Error ? error.message : String(error)}; falling back to wasm`,
      runtime: config.runtime,
      accelerator: "webgpu",
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
    try {
      models.dispose();
    } catch (disposeError) {
      logStatus(
        { type: "status", level: "warning", message: "WebGPU session dispose failed", runtime: config.runtime, accelerator: "webgpu" },
        disposeError
      );
    }
    try {
      models = await createRuntimeModels(config, "wasm");
      emitModelsLoaded(config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1);
    } catch (fallbackError) {
      const fallbackPayload: BackendMessage = {
        type: "status",
        level: "error",
        message: `Failed to reload worker models with wasm: ${fallbackError instanceof Error ? fallbackError.message : String(fallbackError)}`,
        runtime: config.runtime,
        accelerator: "wasm",
        logged: true
      };
      logStatus(fallbackPayload, fallbackError);
      emit(fallbackPayload);
    } finally {
      fallbackInProgress = false;
    }
  } else if (!fallbackInProgress && now - lastStatus > 1000) {
    const payload: BackendMessage = {
      type: "status",
      level: "warning",
      message: error instanceof Error ? error.message : String(error),
      runtime: config.runtime,
      accelerator: models.accelerator,
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
    lastStatus = now;
  }
}

async function captureCalibration(target: [number, number], validation: boolean): Promise<void> {
  if (calibration === null || config === null) {
    return;
  }
  try {
    const sample = stableFeatureSample(recentFeatures, performance.now());
    if (sample.feature === null) {
      emit({ type: "calibration", status: "unstable", message: sample.reason });
      return;
    }
    if (validation) await calibration.validate(sample.feature, target);
    else await calibration.capture(sample.feature, target);
  } catch (error) {
    emit({
      type: "status",
      level: "error",
      message: `Calibration capture failed: ${error instanceof Error ? error.message : String(error)}`,
      runtime: config.runtime,
      logged: true
    });
  }
}

function requestCalibrationRead(path: string): Promise<{ ok: true; text: string | null } | { ok: false; error: string }> {
  const id = requestId + 1;
  requestId = id;
  post({ type: "calibration_read", id, path });
  return new Promise((resolve) => pendingReads.set(id, resolve));
}

function requestCalibrationWrite(path: string, payload: unknown): Promise<{ ok: true; path: string } | { ok: false; error: string }> {
  const id = requestId + 1;
  requestId = id;
  post({ type: "calibration_write", id, path, payload });
  return new Promise((resolve) => pendingWrites.set(id, resolve));
}

async function emitWorkerPreview(
  frame: ImageData,
  head: Detection | null,
  eyes: Detection[],
  mouth: Detection | null,
  message: string | null,
  gazeAngles: [number, number] | null,
  widthRatio: number | null,
  irisContours?: [number, number][][]
): Promise<number> {
  const start = performance.now();
  const image = await createPreviewImageInWorker(frame.width, frame.height, head, eyes, mouth, message, widthRatio, gazeAngles ?? undefined, irisContours);
  if (image) {
    emit({
      type: "preview",
      image,
      head_detected: head !== null,
      eye_count: eyes.length,
      width_ratio: widthRatio
    });
  }
  return performance.now() - start;
}

let previewCanvas: OffscreenCanvas | null = null;
let previewCtxCached: OffscreenCanvasRenderingContext2D | null = null;

async function createPreviewImageInWorker(
  frameWidth: number,
  frameHeight: number,
  head: Detection | null,
  eyes: Detection[],
  mouth: Detection | null,
  message: string | null,
  widthRatio: number | null,
  gazeAngles?: [number, number],
  irisContours?: [number, number][][]
): Promise<string> {
  if (typeof OffscreenCanvas === "undefined" || frameCanvas === null) {
    return "";
  }
  const targetHeight = previewHeightFor(frameWidth, frameHeight);
  if (previewCanvas === null || previewCanvas.width !== PREVIEW_WIDTH || previewCanvas.height !== targetHeight) {
    previewCanvas = new OffscreenCanvas(PREVIEW_WIDTH, targetHeight);
    previewCtxCached = previewCanvas.getContext("2d");
  }
  const previewCtx = previewCtxCached;
  if (!previewCtx) {
    return "";
  }
  previewCtx.drawImage(frameCanvas, 0, 0, PREVIEW_WIDTH, targetHeight);
  renderPreviewAnnotations(
    previewCtx,
    frameWidth,
    frameHeight,
    head,
    eyes,
    mouth,
    message,
    widthRatio,
    gazeAngles,
    irisContours
  );
  const blob = await previewCanvas.convertToBlob({ type: "image/jpeg", quality: 0.72 });
  return blobToDataUrl(blob);
}

async function blobToDataUrl(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return `data:${blob.type};base64,${btoa(binary)}`;
}

function isRecoverableInferenceError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return (
    message.includes("OrtRun") ||
    message.includes("bad_array_new_length") ||
    message.includes("failed to call") ||
    message.includes("memory access out of bounds") ||
    message.includes("ERROR_CODE")
  );
}
