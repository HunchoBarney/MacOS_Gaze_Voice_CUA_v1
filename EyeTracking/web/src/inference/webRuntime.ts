import type { BackendMessage, WebInferenceConfig } from "../global";
import { logStatus } from "../logger";
import {
  Calibration,
  DisplayGeometry,
  DISTANCE_MAX_M,
  DISTANCE_MIN_M,
  DISTANCE_SMOOTHING_ALPHA,
  GazeAngleSmoother,
  GazeJumpGate,
  OneEuroFilter,
  reanchorDetection,
  SaccadeAwareGazeFilter,
  ScreenProjector,
  center,
  clamp01,
  createPreviewImage,
  isHeadTurned,
  LIP_MOTION_OPEN_THRESHOLD,
  stableFeatureSample,
  updateBlinkState,
  type GazeEstimate,
  type GazeFeature,
  type TimedFeature,
  width,
  type Detection
} from "./core";
import InferenceWorker from "./inferenceWorker.ts?worker";
import { createRuntimeModels, warmupRuntimeModels, type RuntimeModels } from "./runtimes";

export interface WebRuntimeController {
  captureCalibration(target: [number, number], validation: boolean): Promise<void>;
  stop(): void;
}

const DETECT_INTERVAL_MS = 1000;

export async function startWebRuntime(
  config: WebInferenceConfig,
  emit: (payload: BackendMessage) => void
): Promise<WebRuntimeController> {
  if (config.webInferenceWorker === "dedicated") {
    return startDedicatedWorkerRuntime(config, emit);
  }
  if (config.webInferenceWorker === "ort-proxy" && config.runtime !== "onnxweb") {
    emit({
      type: "status",
      level: "warning",
      message: "--web-inference-worker ort-proxy is only supported by onnxweb; using normal renderer inference",
      runtime: config.runtime,
      logged: true
    });
  }
  let stopped = false;
  let latestRaw: [number, number] | null = null;
  const recentFeatures: TimedFeature[] = [];
  const jumpGate = new GazeJumpGate();
  let smoothed: [number, number] | null = null;
  let smoothedDistance: number | null = null;
  let blinking = false;
  const filterX = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  const filterY = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  const saccadeFilter = new SaccadeAwareGazeFilter();
  const angleSmoother = new GazeAngleSmoother();
  let lastDetection: { head: Detection; eyes: Detection[]; mouth: Detection | null } | null = null;
  let lastDetectMs = 0;
  let forceRedetect = false;
  let appliedGeometryKey: string | null = null;
  let stream: MediaStream | null = null;
  let models: RuntimeModels | null = null;
  let lastStatus = 0;
  let lastPreview = 0;
  let lastProcessed = 0;
  let lastProjectionWarning = 0;
  let fallbackInProgress = false;
  let lastEmitCore: { x: number; y: number; distance: number; yaw: number; pitch: number } | null = null;
  let dropStreakStart = 0;
  const longTasks = createLongTaskCounter();

  const emitHold = (reason: string) => {
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
      confidence: 0.2,
      distance_m: lastEmitCore.distance,
      yaw_deg: lastEmitCore.yaw,
      pitch_deg: lastEmitCore.pitch,
      held_reason: reason
    });
  };

  const syncGeometry = () => {
    if (!calibration.geometry) {
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
  };

  const emitAndSync = (payload: BackendMessage) => {
    emit(payload);
    if (
      payload.type === "calibration" &&
      (payload.status === "saved" || (payload.status === "geometry" && !config.calibrate))
    ) {
      syncGeometry();
    }
  };

  const projector = new ScreenProjector(
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
  const calibration = new Calibration(config.calibrationFile, emitAndSync, undefined, (feature, weightX, weightY) =>
    projector.projectFeatures(feature, config.gazeProjectionMode, weightX, weightY, !config.disableIrisDistance)
  );
  await calibration.load();
  if (config.calibrate) {
    projector.retune(null, 1, 0.25);
    appliedGeometryKey = null;
  } else {
    syncGeometry();
  }

  const headFaceWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1;
  const previewWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : null;

  try {
    const useOrtProxy = config.webInferenceWorker === "ort-proxy" && config.runtime === "onnxweb";
    const forceWasm = useOrtProxy || config.webAccelerator === "wasm";
    try {
      models = forceWasm ? await createRuntimeModels(config, "wasm") : await createRuntimeModels(config, "webgpu");
    } catch (error) {
      if (forceWasm) {
        throw error;
      }
      const payload: BackendMessage = {
        type: "status",
        level: "warning",
        message: `WebGPU model load failed: ${error}; falling back to wasm`,
        runtime: config.runtime,
        accelerator: "webgpu",
        logged: true
      };
      logStatus(payload, error);
      emit(payload);
      models = await createRuntimeModels(config, "wasm");
    }
    emit({
      type: "status",
      level: "info",
      message: "Models loaded",
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
    await warmupRuntimeModels(models);

    const camera = await openCamera(config.camera, config.cameraWidth, config.cameraHeight);
    stream = camera.stream;
    const video = camera.video;
    const canvas = document.createElement("canvas");
    canvas.width = config.cameraWidth;
    canvas.height = config.cameraHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) {
      throw new Error("2D canvas context is not available");
    }

    const previewInterval = 1000 / Math.max(0.5, config.previewFps);

    const loop = async () => {
      if (stopped || models === null) {
        return;
      }
      try {
        const captureStart = performance.now();
        ctx.drawImage(video, 0, 0, config.cameraWidth, config.cameraHeight);
        const frame = ctx.getImageData(0, 0, config.cameraWidth, config.cameraHeight);
        const captureMs = performance.now() - captureStart;
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
        const frameIntervalMs = lastProcessed > 0 ? now - lastProcessed : undefined;
        lastProcessed = now;
        const processedFps = frameIntervalMs && frameIntervalMs > 0 ? 1000 / frameIntervalMs : undefined;
        const shouldEmitPreview = !config.hidePreview && now - lastPreview >= previewInterval;
        let previewMs = 0;
        if (head === null || eyes.length < 2) {
          lastDetection = null;
          forceRedetect = true;
          if (shouldEmitPreview) {
            const message = head === null ? "Head not detected" : `Eyes detected: ${eyes.length}`;
            previewMs = emitPreview(frame, canvas, head, eyes, mouth, message, null, previewWidthRatio, emit);
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
        } catch {
          emitHold("estimate_failed");
          return;
        }
        const gaze = angleSmoother.update(gazeEstimate);
        const gazeEnd = performance.now();
        const gazeInferenceMs = gazeEnd - gazeStart;
        const reanchored = reanchorDetection(
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
                : {
                    ...mouth,
                    x1: mouth.x1 + reanchored.dx,
                    y1: mouth.y1 + reanchored.dy,
                    x2: mouth.x2 + reanchored.dx,
                    y2: mouth.y2 + reanchored.dy
                  }
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
          previewMs = emitPreview(
            frame,
            canvas,
            head,
            eyes,
            mouth,
            blinking ? "Blink" : headTurned ? "Head turned" : null,
            [gaze.yawDeg, gaze.pitchDeg],
            previewWidthRatio,
            emit,
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
          const payload: BackendMessage = {
            type: "status",
            level: "warning",
            message: `${projection.fallbackReason}; falling back to legacy projection`,
            runtime: config.runtime,
            accelerator: models.accelerator,
            gaze_projection_mode: config.gazeProjectionMode,
            logged: true
          };
          logStatus(payload);
          emit(payload);
          lastProjectionWarning = now;
        }
        // A real screen hit can only land near the display — beyond a full
        // screen away is a broken estimate; never let one teleport the marker.
        if (
          !Number.isFinite(projection.point[0]) ||
          !Number.isFinite(projection.point[1]) ||
          Math.abs(projection.point[0] - 0.5) > 1 ||
          Math.abs(projection.point[1] - 0.5) > 1
        ) {
          emitHold("implausible_raw");
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
          capture_ms: captureMs,
          preview_ms: previewMs,
          frame_interval_ms: frameIntervalMs,
          processed_fps: processedFps,
          dropped_frames: 0,
          main_thread_long_tasks: longTasks.count(),
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
        const now = performance.now();
        if (models?.accelerator === "webgpu" && !fallbackInProgress && isRecoverableInferenceError(error)) {
          fallbackInProgress = true;
          const payload: BackendMessage = {
            type: "status",
            level: "warning",
            message: `WebGPU inference failed: ${error instanceof Error ? error.message : String(error)}; falling back to wasm`,
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
            emit({
              type: "status",
              level: "info",
              message: "Models reloaded with wasm",
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
          } catch (fallbackError) {
            const fallbackPayload: BackendMessage = {
              type: "status",
              level: "error",
              message: `Failed to reload models with wasm: ${fallbackError instanceof Error ? fallbackError.message : String(fallbackError)}`,
              runtime: config.runtime,
              accelerator: "wasm",
              logged: true
            };
            logStatus(fallbackPayload, fallbackError);
            emit(fallbackPayload);
          } finally {
            fallbackInProgress = false;
          }
        } else if (fallbackInProgress) {
          // Suppress repeated frame errors while runtime fallback is rebuilding sessions.
        } else {
          if (now - lastStatus > 1000) {
            const payload: BackendMessage = {
              type: "status",
              level: "warning",
              message: error instanceof Error ? error.message : String(error),
              runtime: config.runtime,
              accelerator: models?.accelerator,
              logged: true
            };
            logStatus(payload, error);
            emit(payload);
            lastStatus = now;
          }
        }
      } finally {
        if (!stopped) {
          window.setTimeout(loop, 33);
        }
      }
    };
    void loop();
  } catch (error) {
    const payload: BackendMessage = {
      type: "status",
      level: "error",
      message: error instanceof Error ? error.message : String(error),
      runtime: config.runtime,
      accelerator: models?.accelerator,
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
  }

  return {
    captureCalibration: (target, validation) => captureCalibration(calibration, recentFeatures, target, validation, emit, config),
    stop: () => {
      stopped = true;
      longTasks.stop();
      models?.dispose();
      for (const track of stream?.getTracks() ?? []) {
        track.stop();
      }
    }
  };
}

function createLongTaskCounter(): { count(): number; stop(): void } {
  let count = 0;
  let observer: PerformanceObserver | null = null;
  try {
    observer = new PerformanceObserver((list) => {
      count += list.getEntries().length;
    });
    observer.observe({ entryTypes: ["longtask"] });
  } catch {
    observer = null;
  }
  return {
    count: () => count,
    stop: () => observer?.disconnect()
  };
}

type WorkerToMainMessage =
  | { type: "ready" }
  | { type: "frame_done" }
  | { type: "backend"; payload: BackendMessage }
  | { type: "calibration_read"; id: number; path: string }
  | { type: "calibration_write"; id: number; path: string; payload: unknown };

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

async function startDedicatedWorkerRuntime(
  config: WebInferenceConfig,
  emit: (payload: BackendMessage) => void
): Promise<WebRuntimeController> {
  let stopped = false;
  let stream: MediaStream | null = null;
  let inFlight = false;
  let droppedFrames = 0;
  let lastCapture = 0;
  let captureTimer: number | null = null;
  const longTasks = createLongTaskCounter();
  const worker = new InferenceWorker();

  const post = (message: MainToWorkerMessage, transfer?: Transferable[]) => {
    worker.postMessage(message, transfer ?? []);
  };

  worker.onmessage = (event: MessageEvent<WorkerToMainMessage>) => {
    const message = event.data;
    if (message.type === "backend") {
      emit(message.payload);
    } else if (message.type === "frame_done") {
      inFlight = false;
    } else if (message.type === "calibration_read") {
      window.gazeBridge.readCalibration(message.path).then((response) => {
        post({ type: "calibration_read_result", id: message.id, response });
      });
    } else if (message.type === "calibration_write") {
      window.gazeBridge.writeCalibration(message.path, message.payload).then((response) => {
        post({ type: "calibration_write_result", id: message.id, response });
      });
    }
  };
  worker.onerror = (event) => {
    emit({
      type: "status",
      level: "error",
      message: `Inference worker error: ${event.message}`,
      runtime: config.runtime,
      logged: true
    });
  };

  post({ type: "init", config: { ...config, assetBaseUrl: window.location.href } });

  try {
    const camera = await openCamera(config.camera, config.cameraWidth, config.cameraHeight);
    stream = camera.stream;
    const video = camera.video;
    const canvas = document.createElement("canvas");
    canvas.width = config.cameraWidth;
    canvas.height = config.cameraHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) {
      throw new Error("2D canvas context is not available");
    }

    const captureLoop = async () => {
      if (stopped) {
        return;
      }
      if (inFlight) {
        droppedFrames += 1;
        captureTimer = window.setTimeout(() => void captureLoop(), 33);
        return;
      }
      const pacingNow = performance.now();
      const minIntervalMs = config.gazeMaxFps > 0 ? 1000 / config.gazeMaxFps : 0;
      if (minIntervalMs > 0 && lastCapture > 0 && pacingNow - lastCapture < minIntervalMs) {
        captureTimer = window.setTimeout(() => void captureLoop(), minIntervalMs - (pacingNow - lastCapture));
        return;
      }
      inFlight = true;
      const captureStart = performance.now();
      const now = performance.now();
      const frameIntervalMs = lastCapture > 0 ? now - lastCapture : undefined;
      lastCapture = now;
      const mainThreadLongTasks = longTasks.count();
      const dropped = droppedFrames;
      let bitmap: ImageBitmap | null = null;
      try {
        bitmap = await createImageBitmap(video);
      } catch {
        // createImageBitmap can fail on detached/ended tracks; fall back to
        // canvas readback below.
      }
      if (stopped) {
        bitmap?.close();
        return;
      }
      if (bitmap !== null) {
        post(
          {
            type: "frame",
            bitmap,
            width: config.cameraWidth,
            height: config.cameraHeight,
            captureMs: performance.now() - captureStart,
            frameIntervalMs,
            droppedFrames: dropped,
            mainThreadLongTasks
          },
          [bitmap]
        );
      } else {
        ctx.drawImage(video, 0, 0, config.cameraWidth, config.cameraHeight);
        const frame = ctx.getImageData(0, 0, config.cameraWidth, config.cameraHeight);
        post(
          {
            type: "frame",
            data: frame.data,
            width: frame.width,
            height: frame.height,
            captureMs: performance.now() - captureStart,
            frameIntervalMs,
            droppedFrames: dropped,
            mainThreadLongTasks
          },
          [frame.data.buffer]
        );
      }
      captureTimer = window.setTimeout(() => void captureLoop(), 33);
    };
    void captureLoop();
  } catch (error) {
    emit({
      type: "status",
      level: "error",
      message: error instanceof Error ? error.message : String(error),
      runtime: config.runtime,
      logged: true
    });
  }

  return {
    captureCalibration: async (target, validation) => {
      post({ type: "capture_calibration", target, validation });
    },
    stop: () => {
      stopped = true;
      if (captureTimer !== null) {
        window.clearTimeout(captureTimer);
      }
      longTasks.stop();
      post({ type: "stop" });
      worker.terminate();
      for (const track of stream?.getTracks() ?? []) {
        track.stop();
      }
    }
  };
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

async function captureCalibration(
  calibration: Calibration,
  recentFeatures: TimedFeature[],
  target: [number, number],
  validation: boolean,
  emit: (payload: BackendMessage) => void,
  config: WebInferenceConfig
): Promise<void> {
  const sample = stableFeatureSample(recentFeatures, performance.now());
  if (sample.feature === null) {
    emit({ type: "calibration", status: "unstable", message: sample.reason });
    return;
  }
  try {
    if (validation) await calibration.validate(sample.feature, target);
    else await calibration.capture(sample.feature, target);
  } catch (error) {
    const payload: BackendMessage = {
      type: "status",
      level: "error",
      message: `Calibration capture failed: ${error instanceof Error ? error.message : String(error)}`,
      runtime: config.runtime,
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
  }
}

async function openCamera(
  camera: string,
  expectedWidth: number,
  expectedHeight: number
): Promise<{ stream: MediaStream; video: HTMLVideoElement }> {
  const constraints = await cameraConstraints(camera);
  const stream = await navigator.mediaDevices.getUserMedia({
    video: {
      ...constraints,
      width: { exact: expectedWidth },
      height: { exact: expectedHeight }
    },
    audio: false
  });
  const video = document.createElement("video");
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;
  video.srcObject = stream;
  await video.play();
  await waitForVideo(video);
  const settings = stream.getVideoTracks()[0]?.getSettings();
  const actualWidth = settings?.width ?? video.videoWidth;
  const actualHeight = settings?.height ?? video.videoHeight;
  if (actualWidth !== expectedWidth || actualHeight !== expectedHeight) {
    for (const track of stream.getTracks()) {
      track.stop();
    }
    throw new Error(`Camera returned ${actualWidth}x${actualHeight}, expected ${expectedWidth}x${expectedHeight}`);
  }
  return { stream, video };
}

async function cameraConstraints(camera: string): Promise<MediaTrackConstraints> {
  const index = Number.parseInt(camera, 10);
  if (Number.isFinite(index) && String(index) === camera.trim()) {
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter((device) => device.kind === "videoinput");
    const selected = devices[index];
    return selected?.deviceId ? { deviceId: { exact: selected.deviceId } } : {};
  }
  if (camera) {
    return { deviceId: { exact: camera } };
  }
  return {};
}

function waitForVideo(video: HTMLVideoElement): Promise<void> {
  if (video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      cleanup();
      reject(new Error("Camera video did not become ready"));
    }, 5000);
    const onReady = () => {
      cleanup();
      resolve();
    };
    const cleanup = () => {
      window.clearTimeout(timeout);
      video.removeEventListener("loadeddata", onReady);
    };
    video.addEventListener("loadeddata", onReady, { once: true });
  });
}

function emitPreview(
  frame: ImageData,
  source: HTMLCanvasElement | null,
  head: Detection | null,
  eyes: Detection[],
  mouth: Detection | null,
  message: string | null,
  gazeAngles: [number, number] | null,
  widthRatio: number | null,
  emit: (payload: BackendMessage) => void,
  irisContours?: [number, number][][]
): number {
  const start = performance.now();
  const image = createPreviewImage(source ?? frame, frame.width, frame.height, head, eyes, mouth, message, widthRatio, gazeAngles ?? undefined, irisContours);
  if (!image) {
    return performance.now() - start;
  }
  emit({
    type: "preview",
    image,
    head_detected: head !== null,
    eye_count: eyes.length,
    width_ratio: widthRatio
  });
  return performance.now() - start;
}
