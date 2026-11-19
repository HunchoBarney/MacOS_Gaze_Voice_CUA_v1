import type { BackendMessage, WebAccelerator, WebInferenceConfig } from "../global";
import { logStatus } from "../logger";
import {
  AppearanceChannel,
  Calibration,
  calibrationContextFingerprint,
  DisplayGeometry,
  DISTANCE_MAX_M,
  DISTANCE_MIN_M,
  DISTANCE_SMOOTHING_ALPHA,
  GazeAngleSmoother,
  GazeJumpGate,
  HeadPoseBaseline,
  OneEuroFilter,
  reanchorDetection,
  SaccadeAwareGazeFilter,
  ScreenProjector,
  EyeValidity,
  DriftMonitor,
  center,
  clamp01,
  coastPosition,
  createPreviewImage,
  DEFAULT_CAMERA_RESOLUTION,
  FALLBACK_CAMERA_RESOLUTION,
  isHeadTurned,
  interpolateTargetAt,
  isRecoverableInferenceError,
  LIP_MOTION_OPEN_THRESHOLD,
  type CameraResolution,
  type GazeEstimate,
  type GazeFeature,
  type TimedFeature,
  height,
  width,
  type Detection,
  type DetectionResult
} from "./core";
import InferenceWorker from "./inferenceWorker.ts?worker";
import { PresentedFrames } from "./presentedFrame";
import { RuntimeSources } from "./runtimeSource";
import { createRuntimeModels, setGpuDeviceLostListener, warmupRuntimeModels, withTimeout, type RuntimeModels } from "./runtimes";

export interface WebFilterOptions {
  // When false the saccade filter's dwell-lock never engages — fixation
  // smoothing still applies, the dot just never freezes in place.
  dwellLock?: boolean;
}

export interface WebRuntimeController {
  pursuitBegin(mode?: "capture" | "verify"): void;
  pursuitTarget(x: number, y: number): void;
  pursuitEnd(): void;
  pursuitAbort(): void;
  implicitSample(xNorm: number, yNorm: number): void;
  setPaused(paused: boolean): void;
  setFilterOptions(options: WebFilterOptions): void;
  setPreviewEnabled(enabled: boolean): void;
  stop(): void;
}

const DETECT_INTERVAL_MS = 1000;
// Away-mode liveness cadence — well inside the host's 6s stale window so
// gaze.updated_at never lies about a live pipeline with no face in frame.
const AWAY_HEARTBEAT_MS = 1000;

// A released session frees its wasm heap asynchronously — a reload raced
// against that free re-faults with the same OOM ("memory access out of
// bounds"), which is how a recoverable crash became a permanent wedge.
// The backoff gives each retry a genuinely clean heap; bounded, because a
// permanently broken stack must not retry and log every frame forever.
// Same ladder policy as the dedicated worker: wasm keeps the long backoff,
// a transient webgpu device loss retries fast rather than costing 21s of
// dead gaze, and wedged dispose/create calls are timeout-bounded.
const SESSION_RECOVERY_DELAYS_MS = [3000, 6000, 12000];
const WEBGPU_RECOVERY_DELAYS_MS = [1500, 5000];
const SESSION_DISPOSE_TIMEOUT_MS = 5000;
const MODEL_CREATE_TIMEOUT_MS = 30000;
const SESSION_PROBE_TIMEOUT_MS = 30000;
const WEBGPU_REPROMOTION_FIRST_DELAY_MS = 60_000;
const WEBGPU_REPROMOTION_CADENCE_MS = 300_000;
const WEBGPU_REPROMOTION_MAX_ATTEMPTS = 4;
const SWAPPED_SET_DISPOSE_DELAY_MS = 2000;
// getUserMedia/enumerateDevices/play() carry no built-in deadline — a
// camera that accepts-but-never-delivers would wedge boot silently
// (waitForVideo's own 5s only covers the post-play leg).
const CAMERA_OPEN_TIMEOUT_MS = 15000;

const runtimeSources = new RuntimeSources();

export function startWebRuntime(
  config: WebInferenceConfig, publish: (payload: BackendMessage) => void, signal: AbortSignal
): Promise<WebRuntimeController> {
  return runtimeSources.start(signal, publish, emit =>
    config.webInferenceWorker === "dedicated" ? startDedicatedWorkerRuntime(config, emit) : startMainThreadRuntime(config, emit));
}

async function startMainThreadRuntime(
  config: WebInferenceConfig,
  emit: (payload: BackendMessage) => void
): Promise<WebRuntimeController> {
  let stopped = false;
  let latestRaw: [number, number] | null = null;
  const recentFeatures: TimedFeature[] = [];
  const jumpGate = new GazeJumpGate();
  // Corrected-space guard: tighter than the raw gate — a fitted map should
  // never jump 0.1 in one frame; one confirming sample still lets a real
  // saccade through.
  const correctedGate = new GazeJumpGate(0.1, 0.05, 500, 1000);
  let smoothed: [number, number] | null = null;
  let smoothedDistance: number | null = null;
  const eyeValidity = new EyeValidity();
  const appearanceChannel = new AppearanceChannel();
  const driftMonitor = new DriftMonitor();
  let smoothedPrev: [number, number] | null = null;
  let smoothedVel: [number, number] = [0, 0];
  let smoothedPrevAt = 0;
  let holdStartMs = 0;
  let smoothedHeadRoll: number | null = null;
  // EMA of the metric pose roll — one bad mesh vertex can snap the raw roll
  // several degrees, which pivots every de-rotated gaze angle it feeds.
  let smoothedPoseRoll: number | null = null;
  let jawBaselineX: number | null = null;
  let jawBaselineY: number | null = null;
  const filterX = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  const filterY = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  const saccadeFilter = new SaccadeAwareGazeFilter();
  const angleSmoother = new GazeAngleSmoother();
  // Session straight-ahead for the metric head pose — lives for the runtime's
  // lifetime, re-seeded by a restart like the other per-session estimators.
  const poseBaseline = new HeadPoseBaseline();
  let lastDetection: DetectionResult | null = null;
  let noFaceSince = 0;
  let lastDetectMs = 0;
  let forceRedetect = false;
  let appliedGeometryKey: string | null = null;
  let stream: MediaStream | null = null;
  let presentedFrames: PresentedFrames | undefined;
  let models: RuntimeModels | null = null;
  let lastStatus = 0;
  let lastPreview = 0;
  let lastProcessed = 0;
  let lastProjectionWarning = 0;
  let paused = false;
  let fallbackInProgress = false;
  // Latched once the last-resort wasm rebuild exhausts its attempts — the
  // loop then skips inference cleanly instead of throwing on a dead session.
  let inferenceUnrecoverable = false;
  // wasm→webgpu re-promotion: armed after any wasm landing while the config
  // prefers the fast path; the counter resets whenever webgpu is live.
  let repromotionAttempts = 0;
  let repromotionTimer: number | null = null;
  let repromotionInFlight = false;
  let previewEnabled = !config.hidePreview;
  let lastEmitCore: { x: number; y: number; distance: number; yaw?: number; pitch?: number } | null = null;
  let dropStreakStart = 0;
  // Away heartbeat — same contract as the dedicated worker: past the hold
  // horizon (or before any first fix) a ~1Hz away:true keepalive flows on
  // the gaze channel so the host's wedge watch can't read a healthy-but-
  // empty pipeline as dead. Liveness, not a sample. Starts one period due
  // so the first no-face frame beats immediately (worker mirrors this).
  let lastAwayBeat = -AWAY_HEARTBEAT_MS;
  // Actual capture size — filled in when the camera opens. Under the
  // default-resolution VGA fallback it differs from the configured request,
  // and telemetry/fingerprint/projection must report the truth.
  let captureWidth = config.cameraWidth;
  let captureHeight = config.cameraHeight;
  let captureResolutionName = config.cameraResolutionName;
  let pursuitActive = false;
  let pursuitMode: "capture" | "verify" = "capture";
  const pursuitTargetHistory: Array<{ at: number; pos: [number, number] }> = [];
  let pursuitLastMsgAt = 0;
  // Label lag = camera exposure (~1 frame) + the eye's own smooth-pursuit
  // latency (~100-125ms) — the eye trails the dot, so the honest label is
  // where the dot WAS when the camera saw this frame.
  const PURSUIT_LABEL_LAG_MS = 120;
  // How long the target has been parked at `pos` before time `t` — the
  // saccade-settle gate (same rule as the worker path: the first ~280ms of a
  // dwell still show the landing saccade under the target's label).
  const pursuitDwellMs = (t: number, pos: [number, number]): number => {
    let first = t;
    for (let i = pursuitTargetHistory.length - 1; i >= 0; i -= 1) {
      const e = pursuitTargetHistory[i];
      if (e.at > t) continue;
      if (Math.hypot(e.pos[0] - pos[0], e.pos[1] - pos[1]) > 0.005) break;
      first = e.at;
    }
    return t - first;
  };
  const PURSUIT_SETTLE_MS = 280;
  let lastPursuitCountEmit = 0;
  const longTasks = createLongTaskCounter();

  // On a dropped frame the marker should hold at the last stable pose rather
  // than freeze-and-expire; hold emits carry the reason for diagnostics. After
  // ~8s of continuous drops the marker is allowed to expire (real absence) —
  // but the pipeline is still alive and the host keys its wedge watch off
  // gaze.updated_at, so the no-face path keeps a ~1Hz away heartbeat going
  // forever. The heartbeat is liveness, not a sample: no coordinates, and
  // `away: true` marks it for any consumer that inspects the flag.
  const emitHold = (reason: string, rejectedRaw?: [number, number]) => {
    const now = performance.now();
    if (dropStreakStart === 0) {
      dropStreakStart = now;
    }
    if (now - dropStreakStart > 8000 || lastEmitCore === null) {
      if (reason === "no_face" && now - lastAwayBeat >= AWAY_HEARTBEAT_MS) {
        lastAwayBeat = now;
        emit({
          type: "gaze",
          away: true,
          held_reason: "no_face",
          confidence: 0
        });
      }
      return;
    }
    const coasted = coastPosition([lastEmitCore.x, lastEmitCore.y], smoothedVel, now - dropStreakStart);
    emit({
      type: "gaze",
      x_norm: coasted[0],
      y_norm: coasted[1],
      raw_x_norm: rejectedRaw?.[0],
      raw_y_norm: rejectedRaw?.[1],
      confidence: 0.2,
      distance_m: lastEmitCore.distance,
      yaw_deg: lastEmitCore.yaw,
      pitch_deg: lastEmitCore.pitch,
      held_reason: reason
    });
  };

  // No-face is a normal operating state (looked away, stepped out, bad
  // lighting), not a frame error — this loop used to throw it into
  // handleFrameError every frame, paying a per-frame exception just to reach
  // that handler's 1Hz status throttle. Emit the same throttled status
  // directly: state.status and the status pane keep reporting why no gaze is
  // flowing, and `logged: true` keeps the console calm — presence already
  // flows through the preview's head_detected flag and the gaze
  // away-heartbeat, so nothing needs a log line per second of absence.
  const emitNoFaceStatus = (now: number, message: string) => {
    if (now - lastStatus <= 1000) {
      return;
    }
    lastStatus = now;
    emit({
      type: "status",
      level: "warning",
      message,
      runtime: config.runtime,
      accelerator: models?.accelerator,
      logged: true
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
      if (payload.status === "saved") {
        driftMonitor.reset();
        appearanceChannel.reset();
        // The map just changed under the filter chain — stale smoothed/anchor
        // state would pin the marker where the OLD map thought gaze was.
        saccadeFilter.reset();
        smoothed = null;
        smoothedPrev = null;
        smoothedVel = [0, 0];
        smoothedPrevAt = 0;
        holdStartMs = 0;
        jumpGate.reset();
        correctedGate.reset();
      }
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

  const headFaceWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1;
  const previewWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : null;
  // ort-proxy mode exists because webgpu is unusable in that host context —
  // it pins wasm at create time AND opts out of webgpu-first recovery and
  // re-promotion.
  const useOrtProxy = config.webInferenceWorker === "ort-proxy";

  const emitModelsLoaded = (message: string) => {
    if (models === null) {
      return;
    }
    emit({
      type: "status",
      level: "info",
      message,
      runtime: config.runtime,
      accelerator: models.accelerator,
      detector: config.detector,
      detector_model: config.detectorModel,
      detector_providers: models.detectorProviders,
      head_face_width_ratio: headFaceWidthRatio,
      camera_fov_deg: config.cameraFov,
      camera_resolution_name: captureResolutionName,
      camera_width: captureWidth,
      camera_height: captureHeight,
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
  };

  // A dispose that can never hang the recovery path: on the wedged-release
  // ORT bug the promise never settles, so after 5s the reference is dropped
  // and the ladder moves on — its backoff absorbs the still-pending free.
  const disposeRuntimeModels = async (target: RuntimeModels | null, context: string): Promise<void> => {
    if (target === null) {
      return;
    }
    try {
      await withTimeout(target.dispose(), SESSION_DISPOSE_TIMEOUT_MS, "session dispose");
    } catch (disposeError) {
      logStatus(
        {
          type: "status",
          level: "warning",
          message: `${context} dispose failed`,
          runtime: config.runtime,
          accelerator: target.accelerator
        },
        disposeError
      );
    }
  };

  // Rebuild the inference sessions in place after a session died — the same
  // bounded-backoff recovery as the dedicated worker. Webgpu rungs use the
  // short ladder (transient device loss shouldn't cost 21s of dead gaze);
  // wasm keeps the long backoff so the heap actually frees between attempts.
  // Each attempt then has to survive a real probe run — create succeeding
  // while run faults counts as a failed attempt. Wasm exhaustion is terminal
  // (emitted once, models stays null); webgpu exhaustion falls through to
  // the wasm ladder. opts.promote keeps the live wasm set serving frames
  // until a webgpu candidate passes its probe; opts.quiet keeps a declined
  // probe log-only so the host never sees a false wedge signature.
  const recoverSessions = async (target: WebAccelerator, cause: unknown, opts: { promote?: boolean; quiet?: boolean } = {}): Promise<boolean> => {
    const quiet = opts.quiet === true;
    const promote = opts.promote === true;
    const preserved = promote ? models : null;
    if (!promote) {
      const dead = models;
      models = null;
      await disposeRuntimeModels(dead, "dead session");
    }
    const delays = target === "webgpu" ? WEBGPU_RECOVERY_DELAYS_MS : SESSION_RECOVERY_DELAYS_MS;
    const attempts = promote ? 1 : delays.length;
    let lastError: unknown = cause;
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const delayMs = promote ? 0 : delays[attempt];
      const attemptPayload: BackendMessage = {
        type: "status",
        level: "warning",
        message:
          `${target} inference session lost: ${lastError instanceof Error ? lastError.message : String(lastError)}; ` +
          `rebuilding sessions in ${delayMs / 1000}s (attempt ${attempt + 1}/${attempts})`,
        runtime: config.runtime,
        accelerator: target,
        logged: true
      };
      logStatus(attemptPayload);
      if (!quiet) {
        emit(attemptPayload);
      }
      if (delayMs > 0) {
        await new Promise<void>((resolve) => window.setTimeout(resolve, delayMs));
      }
      if (stopped) {
        return false;
      }
      try {
        const rebuilt = await withTimeout(createRuntimeModels(config, target), MODEL_CREATE_TIMEOUT_MS, "model create");
        try {
          await withTimeout(warmupRuntimeModels(rebuilt, true), SESSION_PROBE_TIMEOUT_MS, "session probe");
        } catch (probeError) {
          await disposeRuntimeModels(rebuilt, "failed-probe session");
          throw probeError;
        }
        if (stopped) {
          // A stop landed mid-rebuild — don't leave orphan sessions behind.
          await disposeRuntimeModels(rebuilt, "superseded rebuilt session");
          return false;
        }
        if (promote && models !== preserved) {
          // A frame error rebuilt the live set while this candidate was
          // compiling — discard it rather than stomp the fresh sessions.
          await disposeRuntimeModels(rebuilt, "orphaned promotion candidate");
          return false;
        }
        models = rebuilt;
        // The cached detection boxes came from the dead session's frame;
        // force a fresh detect rather than trusting them.
        forceRedetect = true;
        // Dead-session rejects may have tripped the appearance channel's
        // failure cap — the rebuilt session deserves a fresh counter.
        appearanceChannel.reset();
        emitModelsLoaded(`Models reloaded with ${target}`);
        if (target === "webgpu") {
          repromotionAttempts = 0;
        }
        if (promote && preserved !== null) {
          // Dispose the old wasm set once in-flight runs drain — a release
          // racing a live OrtRun would fault the very frame it interrupts.
          const stale = preserved;
          void new Promise<void>((resolve) => window.setTimeout(resolve, SWAPPED_SET_DISPOSE_DELAY_MS)).then(() =>
            disposeRuntimeModels(stale, "replaced wasm session set")
          );
        }
        return true;
      } catch (reloadError) {
        lastError = reloadError;
      }
    }
    if (quiet) {
      // Log-only: staying on wasm is a perfectly good state — the host must
      // not see a wedge signature for a routine declined probe.
      logStatus(
        {
          type: "status",
          level: "warning",
          message: `webgpu re-promotion declined (${lastError instanceof Error ? lastError.message : String(lastError)}); staying on wasm`,
          runtime: config.runtime,
          accelerator: "wasm",
          logged: true
        },
        lastError
      );
      return false;
    }
    if (target === "webgpu") {
      const payload: BackendMessage = {
        type: "status",
        level: "warning",
        message: `webgpu session rebuilds exhausted (${lastError instanceof Error ? lastError.message : String(lastError)}); falling back to wasm`,
        runtime: config.runtime,
        accelerator: "webgpu",
        logged: true
      };
      logStatus(payload);
      emit(payload);
      return false;
    }
    inferenceUnrecoverable = true;
    const payload: BackendMessage = {
      type: "status",
      level: "error",
      message: `inference unrecoverable — restart tracking (${lastError instanceof Error ? lastError.message : String(lastError)})`,
      runtime: config.runtime,
      accelerator: "wasm",
      logged: true
    };
    logStatus(payload);
    emit(payload);
    return false;
  };

  // wasm is the last resort, never a permanent silent downgrade: land on it
  // while webgpu is allowed and a quiet re-promotion retry is scheduled —
  // +60s first, then ~5min cadence, max ~4 attempts per demotion episode.
  const scheduleWebgpuRepromotion = () => {
    // ort-proxy mode is wasm-only by design — never try to promote out of it.
    // webgpu is opt-in only: "auto" resolves to wasm (WebGPU run() wedges
    // silently on Electron 42/macOS).
    if (useOrtProxy || config.webAccelerator !== "webgpu") {
      return;
    }
    if (stopped || repromotionTimer !== null || repromotionInFlight || repromotionAttempts >= WEBGPU_REPROMOTION_MAX_ATTEMPTS) {
      return;
    }
    repromotionTimer = window.setTimeout(
      () => {
        repromotionTimer = null;
        void attemptWebgpuRepromotion();
      },
      repromotionAttempts === 0 ? WEBGPU_REPROMOTION_FIRST_DELAY_MS : WEBGPU_REPROMOTION_CADENCE_MS
    );
  };

  const attemptWebgpuRepromotion = async (): Promise<void> => {
    if (stopped || fallbackInProgress || repromotionInFlight || models === null || models.accelerator !== "wasm") {
      return;
    }
    if (repromotionAttempts >= WEBGPU_REPROMOTION_MAX_ATTEMPTS) {
      return;
    }
    repromotionAttempts += 1;
    repromotionInFlight = true;
    let promoted = false;
    try {
      promoted = await recoverSessions("webgpu", "scheduled webgpu re-promotion", { promote: true, quiet: true });
    } finally {
      // Cleared BEFORE rescheduling — scheduleWebgpuRepromotion refuses to
      // arm while a promotion is in flight.
      repromotionInFlight = false;
    }
    if (promoted || stopped) {
      return;
    }
    scheduleWebgpuRepromotion();
  };

  const handleFrameError = async (error: unknown): Promise<void> => {
    const now = performance.now();
    if (!fallbackInProgress && !inferenceUnrecoverable && models !== null && isRecoverableInferenceError(error)) {
      fallbackInProgress = true;
      try {
        const preferWebgpu = !useOrtProxy && config.webAccelerator === "webgpu";
        const onWebgpu = models.accelerator === "webgpu";
        if (onWebgpu) {
          const payload: BackendMessage = {
            type: "status",
            level: "warning",
            message: preferWebgpu
              ? `WebGPU inference failed: ${error instanceof Error ? error.message : String(error)}; rebuilding webgpu sessions`
              : `WebGPU inference failed: ${error instanceof Error ? error.message : String(error)}; falling back to wasm`,
            runtime: config.runtime,
            accelerator: "webgpu",
            logged: true
          };
          logStatus(payload, error);
          emit(payload);
        }
        // WebGPU-first recovery: the fast path is retried on its own short
        // ladder before any demotion; an explicit wasm override (or ort-proxy
        // mode, which only runs wasm) skips the webgpu rungs entirely.
        const firstTarget: WebAccelerator = preferWebgpu ? "webgpu" : "wasm";
        const recovered = await recoverSessions(firstTarget, error);
        if (!recovered && firstTarget === "webgpu") {
          await recoverSessions("wasm", error);
        }
        if (models?.accelerator === "wasm" && preferWebgpu) {
          scheduleWebgpuRepromotion();
        }
      } finally {
        fallbackInProgress = false;
      }
      return;
    }
    if (!fallbackInProgress && now - lastStatus > 1000) {
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
  };

  // GPU device-loss telemetry from runtimes.ts — reason "destroyed" is
  // filtered there (ORT's own release()); anything landing here is a real
  // loss worth a status line for the host log.
  setGpuDeviceLostListener((info) => {
    const payload: BackendMessage = {
      type: "status",
      level: "warning",
      message: `GPU device lost: reason=${info.reason} message=${info.message}`,
      runtime: config.runtime,
      accelerator: "webgpu",
      logged: true
    };
    logStatus(payload);
    emit(payload);
  });

  // The boot-time session build, factored so it can run while the camera is
  // still answering — the creates don't need capture dims. This is the same
  // webgpu→wasm ladder as before, just launched up front.
  const buildModels = async (): Promise<RuntimeModels> => {
    const forceWasm = useOrtProxy || config.webAccelerator !== "webgpu";
    try {
      return forceWasm
        ? await withTimeout(createRuntimeModels(config, "wasm"), MODEL_CREATE_TIMEOUT_MS, "model create")
        : await withTimeout(createRuntimeModels(config, "webgpu"), MODEL_CREATE_TIMEOUT_MS, "model create");
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
      // ~1s heap settle, same as a recovery rung: the failed webgpu create
      // may still be tearing down asynchronously, and a same-beat wasm
      // create can inherit the debris.
      await new Promise<void>((resolve) => window.setTimeout(resolve, 1000));
      const fallbackModels = await withTimeout(createRuntimeModels(config, "wasm"), MODEL_CREATE_TIMEOUT_MS, "model create");
      try {
        // Strict probe: a wasm set that creates but can't run must not be
        // declared loaded — surface it as an init error instead.
        await withTimeout(warmupRuntimeModels(fallbackModels, true), SESSION_PROBE_TIMEOUT_MS, "session probe");
      } catch (probeError) {
        await disposeRuntimeModels(fallbackModels, "failed-probe fallback session");
        throw probeError;
      }
      forceRedetect = true;
      appearanceChannel.reset();
      // Landed on the last-resort accelerator despite preferring webgpu —
      // the fast path gets retried quietly once things settle.
      scheduleWebgpuRepromotion();
      return fallbackModels;
    }
  };

  // The session build launches BEFORE the camera answers — its seconds of
  // wasm/webgpu compilation overlap getUserMedia instead of serializing
  // behind it. Hoisted so a camera failure can still dispose whatever lands.
  let modelsPromise: Promise<RuntimeModels> | null = null;
  try {
    modelsPromise = buildModels();
    // Rejections surface through the await below — observe them now so a
    // failing build can't read as an unhandled rejection while the camera
    // and calibration.load() are still in flight.
    void modelsPromise.catch(() => undefined);
    const camera = await openCamera(
      config.camera,
      requestedCameraResolution(config),
      config.gazeMaxFps,
      emit,
      defaultCameraFallback(config)
    );
    stream = camera.stream;
    const video = camera.video;
    captureWidth = camera.resolution.width;
    captureHeight = camera.resolution.height;
    captureResolutionName = camera.resolution.name ?? `${captureWidth}x${captureHeight}`;
    // The delivered size is the truth — a default-policy VGA fallback
    // changes the real frame dims, and the projector, calibration
    // fingerprint and canvas below must all see them.
    projector.setCameraSize(captureWidth, captureHeight);
    // Same context tag the worker path applies — a file fit under a different
    // projection/display/camera context keeps feature-space state but drops
    // the raw-space fit and persisted drift offset.
    calibration.contextFingerprint = calibrationContextFingerprint({
      gazeProjectionMode: config.gazeProjectionMode,
      displayWidth: config.displayWidth,
      displayHeight: config.displayHeight,
      displaySizeInch: config.displaySizeInch,
      cameraFov: config.cameraFov,
      cameraWidth: captureWidth,
      cameraHeight: captureHeight,
      cameraScreenX: config.cameraScreenX,
      cameraScreenY: config.cameraScreenY,
      flipX: config.flipX,
      flipY: config.flipY,
      appearanceActive: Boolean(config.appearanceModelUrl)
    });
    // Inside the try, matching the worker path: a load() rejection must
    // surface as an error status, not fail silently outside the guard.
    await calibration.load();
    if (config.calibrate) {
      projector.retune(null, 1, 0.25);
      appliedGeometryKey = null;
    } else {
      syncGeometry();
    }
    models = await modelsPromise;
    emitModelsLoaded("Models loaded");
    await warmupRuntimeModels(models);

    const canvas = document.createElement("canvas");
    canvas.width = captureWidth;
    canvas.height = captureHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) {
      throw new Error("2D canvas context is not available");
    }

    const previewInterval = 1000 / Math.max(0.5, config.previewFps);
    const frames = presentedFrames = new PresentedFrames(video);

    const loop = async () => {
      if (stopped || models === null) {
        return;
      }
      const loopStart = performance.now();
      try {
        if (paused) {
          // Paused: skip capture+inference entirely — the finally still
          // re-arms the tick so unpause resumes on the normal cadence.
          return;
        }
        const captureStart = performance.now();
        const observation = frames.take();
        try {
          ctx.drawImage(observation.source, 0, 0, captureWidth, captureHeight);
        } finally {
          observation.close?.();
        }
        const frame = ctx.getImageData(0, 0, captureWidth, captureHeight);
        const captureMs = performance.now() - captureStart;
        const detectStart = performance.now();
        // Away mode: face-absent re-detection is a search loop — 4Hz while
        // recent, 1Hz after ~5s away, not every frame.
        const noFaceMs = noFaceSince === 0 ? 0 : detectStart - noFaceSince;
        const searchInterval = noFaceMs > 5000 ? 1000 : 250;
        const detectDue =
          lastDetection === null || forceRedetect
            ? detectStart - lastDetectMs > searchInterval
            : detectStart - lastDetectMs > DETECT_INTERVAL_MS;
        let head: Detection | null;
        let eyes: Detection[];
        let mouth: Detection | null;
        let nose: [number, number] | undefined;
        let mouthCenter: [number, number] | undefined;
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
          nose = detected.nose;
          mouthCenter = detected.mouthCenter;
          trackingSource = "detector";
        } else if (lastDetection !== null) {
          head = lastDetection.head;
          eyes = lastDetection.eyes;
          mouth = lastDetection.mouth;
          nose = lastDetection.nose;
          mouthCenter = lastDetection.mouthCenter;
          trackingSource = "iris";
        } else {
          // Detection isn't due yet (throttled search) and nothing is
          // tracked — mirror the worker: the no-face path below reports it
          // honestly. Dereferencing lastDetection here was a per-frame
          // TypeError while searching.
          head = null;
          eyes = [];
          mouth = null;
          trackingSource = "iris";
        }
        const now = performance.now();
        const frameIntervalMs = lastProcessed > 0 ? now - lastProcessed : undefined;
        lastProcessed = now;
        const processedFps = frameIntervalMs && frameIntervalMs > 0 ? 1000 / frameIntervalMs : undefined;
        const shouldEmitPreview = previewEnabled && now - lastPreview >= previewInterval;
        let previewMs = 0;
        if (head === null || eyes.length < 2) {
          lastDetection = null;
          forceRedetect = true;
          if (noFaceSince === 0) {
            noFaceSince = now;
          }
          if (shouldEmitPreview) {
            const message = head === null ? "Head not detected" : `Eyes detected: ${eyes.length}`;
            previewMs = emitPreview(frame, canvas, head, eyes, mouth, message, null, previewWidthRatio, emit);
            lastPreview = now;
          }
          emitHold("no_face");
          emitNoFaceStatus(now, head === null ? "Head was not detected" : "Two eyes were not detected");
          return;
        }
        lastDetection = { head, eyes, mouth, nose, mouthCenter };
        noFaceSince = 0;
        // Appearance ensemble signal: ~5Hz, non-blocking — the call resolves
        // on ORT's wasm threads while the frame loop keeps running.
        const appearance = models.appearance;
        if (appearance) {
          appearanceChannel.maybeRun(now, () => appearance.estimate(frame, head));
        }

        const gazeStart = performance.now();
        let gazeEstimate: GazeEstimate;
        try {
          gazeEstimate = await models.estimate(frame, head, eyes);
        } catch (error) {
          emitHold("estimate_failed");
          // A dead session (invalid session id, ortrun, device loss) is
          // recoverable — re-throw so the frame-level handler runs the
          // rebuild ladder. Swallowing it here wedged the tracker into
          // permanent held frames with zero recovery attempts.
          if (isRecoverableInferenceError(error)) {
            throw error;
          }
          if (now - lastProjectionWarning > 1000) {
            const message = error instanceof Error ? error.message : String(error);
            const cropW = Math.max(width(head) / 1.5, Math.hypot(center(eyes[1])[0] - center(eyes[0])[0], center(eyes[1])[1] - center(eyes[0])[1])) * 1.5;
            console.info(
              `[gaze-diag] estimate_failed: ${message} | head=(${head.x1.toFixed(0)},${head.y1.toFixed(0)},${head.x2.toFixed(0)},${head.y2.toFixed(0)}) ` +
                `eyes=(${center(eyes[0])[0].toFixed(0)},${center(eyes[0])[1].toFixed(0)}) (${center(eyes[1])[0].toFixed(0)},${center(eyes[1])[1].toFixed(0)}) crop=${cropW.toFixed(0)}px`
            );
            lastProjectionWarning = now;
          }
          return;
        }
        const gaze = angleSmoother.update(gazeEstimate, captureStart);
        // Metric head pose from the mesh subset — degrees vs the session
        // straight-ahead. null on a degenerate fit: the proxy fallback below
        // keeps the feature channels fed. It deliberately does NOT feed the
        // tilt gate — eye yaw is not head yaw, and substituting it would
        // gate exactly the far-corner fixations calibration needs.
        const headPose = gaze.headPosePoints ? poseBaseline.update(gaze.headPosePoints) : null;
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
                  },
            nose: nose === undefined ? undefined : [nose[0] + reanchored.dx, nose[1] + reanchored.dy],
            mouthCenter: mouthCenter === undefined ? undefined : [mouthCenter[0] + reanchored.dx, mouthCenter[1] + reanchored.dy]
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
        const validity = eyeValidity.update(eyeOpen, now);
        const blinking = validity === "closed";
        const headWidthPx = width(head) * headFaceWidthRatio;
        const [leftEyeCx, leftEyeCy] = center(eyes[0]);
        const [rightEyeCx, rightEyeCy] = center(eyes[1]);
        const eyeSpanPx = Math.hypot(rightEyeCx - leftEyeCx, rightEyeCy - leftEyeCy);
        const headTurned = isHeadTurned(eyeSpanPx, headWidthPx);
        const frozen = eyeValidity.holding || headTurned;
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
        // Clamp to the same [0.05, 3.0] band featureDistanceM enforces on the
        // fit side — an unclamped head estimate would project live gaze in a
        // range the calibration never saw. A NaN box would poison the EMA
        // forever; hold the smoothed value instead.
        const measuredDistanceM = irisDistanceM ?? headDistanceM;
        const rawDistanceM = Number.isFinite(measuredDistanceM)
          ? Math.min(DISTANCE_MAX_M, Math.max(0.05, measuredDistanceM))
          : smoothedDistance ?? 0.6;
        const distanceSource = irisDistanceM !== undefined ? "iris" : "head";
        smoothedDistance =
          smoothedDistance === null ? rawDistanceM : smoothedDistance + DISTANCE_SMOOTHING_ALPHA * (rawDistanceM - smoothedDistance);
        const distanceM = smoothedDistance;
        if (frozen) {
          if (smoothed !== null) {
            if (holdStartMs === 0) {
              holdStartMs = now;
            }
            const coasted = coastPosition(smoothed, smoothedVel, now - holdStartMs);
            emit({
              type: "gaze",
              x_norm: coasted[0],
              y_norm: coasted[1],
              confidence: 0,
              distance_m: distanceM,
              iris_distance_m: irisDistanceM,
              distance_source: distanceSource,
              eye_open: eyeOpen,
              blink: blinking,
              head_turned: headTurned,
              held_reason: headTurned ? "head_turned" : `eye_${validity}`,
              yaw_deg: headPose?.yawDeg,
              pitch_deg: headPose?.pitchDeg
            });
          } else {
            // Frozen with nothing emitted yet still counts as a drop —
            // otherwise the streak never starts and a pipeline that never
            // produces a first frame looks alive forever.
            emitHold(headTurned ? "head_turned" : `eye_${validity}`);
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
        const rollRaw = Math.atan2(rightEyeCy - leftEyeCy, rightEyeCx - leftEyeCx);
        smoothedHeadRoll = smoothedHeadRoll === null ? rollRaw : smoothedHeadRoll + 0.25 * (rollRaw - smoothedHeadRoll);
        // The metric pose roll gets the same 0.25 EMA before it de-rotates
        // the gaze angles — a mesh fit that jitters roll pivots the whole
        // feature vector, and every feature dim downstream of it.
        let poseRollRad: number | undefined;
        if (headPose !== null) {
          const rollSample = (headPose.rollDeg * Math.PI) / 180;
          smoothedPoseRoll = smoothedPoseRoll === null ? rollSample : smoothedPoseRoll + 0.25 * (rollSample - smoothedPoseRoll);
          poseRollRad = smoothedPoseRoll;
        }
        let jawDeltaX: number | undefined;
        let jawDeltaY: number | undefined;
        if (mouthCenter !== undefined) {
          const rawJawX = (mouthCenter[0] - (leftEyeCx + rightEyeCx) * 0.5) / Math.max(1, eyeSpanPx);
          const rawJawY = (mouthCenter[1] - (leftEyeCy + rightEyeCy) * 0.5) / Math.max(1, eyeSpanPx);
          if (jawBaselineX === null || jawBaselineY === null) {
            jawBaselineX = rawJawX;
            jawBaselineY = rawJawY;
          }
          jawDeltaX = rawJawX - jawBaselineX;
          jawDeltaY = rawJawY - jawBaselineY;
          // Speech is jaw displacement, not baseline drift: adapting toward an
          // open mouth re-zeros the jaw channels mid-sentence. Only a settled
          // jaw (raw within ~0.05 of baseline) or a confirmed-closed mouth may
          // pull the baseline.
          const jawSettled = Math.hypot(jawDeltaX, jawDeltaY) < 0.05;
          if (jawSettled || mouthOpen === false) {
            jawBaselineX += 0.04 * jawDeltaX;
            jawBaselineY += 0.04 * jawDeltaY;
          }
        }
        const sampleAt = performance.now();
        const app = appearanceChannel.latest(sampleAt);
        const headFrameX =
          head === null ? undefined : ((leftEyeCx + rightEyeCx) * 0.5 - center(head)[0]) / Math.max(1, width(head));
        const headFrameY =
          head === null ? undefined : ((leftEyeCy + rightEyeCy) * 0.5 - center(head)[1]) / Math.max(1, width(head));
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
          distanceM,
          // The vectorizer normalizes px terms by the frame they came from —
          // tag it so a VGA-fallback session stays commensurate with 720p.
          frameWidth: frame.width,
          frameHeight: frame.height,
          leftIrisOffset: irisInBox(gaze.leftIrisCenterPx, eyes[0]),
          rightIrisOffset: irisInBox(gaze.rightIrisCenterPx, eyes[1]),
          // True head roll moves slowly; the smoothed metric pose supplies it
          // when the mesh fit ran, otherwise the smoothed eye-box line stays
          // the fallback (its jitter would otherwise leak into the
          // roll-aligned gaze angles).
          headRollRad: poseRollRad ?? smoothedHeadRoll ?? 0,
          // Metric head pose (degrees) from the Kabsch mesh fit when
          // available; the nose/mouth-anchored proxies remain the fallback
          // so a degenerate mesh can't starve the pose channels.
          headYawProxy:
            headPose?.yawDeg ??
            (nose !== undefined
              ? (nose[0] - (leftEyeCx + rightEyeCx) * 0.5) / Math.max(1, eyeSpanPx)
              : mouth === null
                ? 0
                : (center(mouth)[0] - (leftEyeCx + rightEyeCx) * 0.5) / Math.max(1, eyeSpanPx)),
          headPitchProxy:
            headPose?.pitchDeg ??
            (nose !== undefined
              ? (nose[1] - (leftEyeCy + rightEyeCy) * 0.5) / Math.max(1, eyeSpanPx)
              : mouth === null
                ? 0
                : (center(mouth)[1] - (leftEyeCy + rightEyeCy) * 0.5) / Math.max(1, eyeSpanPx)),
          jawX: jawDeltaX,
          jawY: jawDeltaY,
          headFrameX,
          headFrameY,
          leftEllipseEcc: gaze.leftEllipseEcc,
          rightEllipseEcc: gaze.rightEllipseEcc,
          leftEllipseAngle: gaze.leftEllipseAngle,
          rightEllipseAngle: gaze.rightEllipseAngle,
          leftApertureRatio: gaze.leftApertureRatio,
          rightApertureRatio: gaze.rightApertureRatio,
          leftMeshOffset: gaze.leftMeshOffset,
          rightMeshOffset: gaze.rightMeshOffset,
          appYawDeg: app?.yawDeg,
          appPitchDeg: app?.pitchDeg,
          appConf: app?.confidence,
          // Position-conditioned fusion: appearance angle (deg) × head-frame
          // position — always finite so live features pass isUsableSample
          // under the 48-dim vector; absent appearance emits 0s.
          appYawHeadFrameX: (app?.yawDeg ?? 0) * (headFrameX ?? 0),
          appYawHeadFrameY: (app?.yawDeg ?? 0) * (headFrameY ?? 0),
          appPitchHeadFrameX: (app?.pitchDeg ?? 0) * (headFrameX ?? 0),
          appPitchHeadFrameY: (app?.pitchDeg ?? 0) * (headFrameY ?? 0),
          appConfHeadFrameRadius: (app?.confidence ?? 0) * Math.hypot(headFrameX ?? 0, headFrameY ?? 0)
        };
        recentFeatures.push({ feature, at: sampleAt });
        while (recentFeatures.length > 0 && sampleAt - recentFeatures[0].at > 900) recentFeatures.shift();
        // Quality gates: a depth-collapsed mesh or a disagreeing pair of eyes
        // labels a systematically-wrong feature — letting it into the pool
        // teaches the map the corruption.
        const pursuitHealthy = gaze.depthHealthy !== false && gaze.agreement >= 0.4;
        if (pursuitActive && pursuitHealthy && eyeOpen >= 0.55 && sampleAt - pursuitLastMsgAt < 250) {
          const labelAt = captureStart - PURSUIT_LABEL_LAG_MS;
          const label = interpolateTargetAt(pursuitTargetHistory, labelAt);
          // Skip the settle window — frames inside the first ~280ms of a
          // parked waypoint still show the landing saccade, not the target.
          if (label !== null && pursuitDwellMs(labelAt, label) >= PURSUIT_SETTLE_MS) {
            if (pursuitMode === "verify") {
              calibration.captureVerifyError(feature, label);
            } else {
              calibration.capturePursuit(feature, label);
              if (sampleAt - lastPursuitCountEmit > 500) {
                emit({ type: "calibration", status: "pursuit_sampled", count: calibration.samples.length });
                lastPursuitCountEmit = sampleAt;
              }
            }
          }
        }
        const corrected = calibration.applyFeature(feature);
        // Second, tighter gate in corrected space: the raw gate passed the
        // projection, but a misbehaving map (fresh refit, drift offset) can
        // still emit a 0.1+ jump the filters would happily follow.
        const acceptedCorrected = correctedGate.accept(corrected, sampleAt);
        if (acceptedCorrected === null) {
          emitHold("corrected_gate");
          return;
        }
        const filterMode = config.gazeFilter ?? "saccade";
        if (filterMode === "oneeuro") {
          smoothed = [filterX.filter(acceptedCorrected[0], sampleAt / 1000), filterY.filter(acceptedCorrected[1], sampleAt / 1000)];
        } else if (filterMode === "ema") {
          if (smoothed === null) {
            smoothed = acceptedCorrected;
          } else {
            const alphaX = Math.max(0, Math.min(0.95, config.smoothingAlpha));
            const alphaY = Math.max(0, Math.min(0.95, config.smoothingAlphaY));
            smoothed = [
              alphaX * smoothed[0] + (1 - alphaX) * acceptedCorrected[0],
              alphaY * smoothed[1] + (1 - alphaY) * acceptedCorrected[1]
            ];
          }
        } else {
          smoothed = saccadeFilter.update(acceptedCorrected[0], acceptedCorrected[1], sampleAt, gaze.yawDeg, gaze.pitchDeg);
        }
        if (smoothedPrev !== null && sampleAt > smoothedPrevAt) {
          const dtv = (sampleAt - smoothedPrevAt) / 1000;
          let vx = (smoothed[0] - smoothedPrev[0]) / dtv;
          let vy = (smoothed[1] - smoothedPrev[1]) / dtv;
          const speed = Math.hypot(vx, vy);
          if (speed > 1.5) {
            const s = 1.5 / speed;
            vx *= s;
            vy *= s;
          }
          smoothedVel = [vx, vy];
        }
        smoothedPrev = smoothed;
        smoothedPrevAt = sampleAt;
        holdStartMs = 0;
        dropStreakStart = 0;
        lastAwayBeat = 0;
        lastEmitCore = {
          x: clamp01(smoothed[0]),
          y: clamp01(smoothed[1]),
          distance: distanceM,
          yaw: headPose?.yawDeg,
          pitch: headPose?.pitchDeg
        };
        let confidence = Math.min(head.score, (eyes[0].score + eyes[1].score) * 0.5);
        confidence *= clamp01(eyeOpen);
        confidence *= Math.max(0.2, gaze.agreement);
        if (gaze.depthHealthy === false) {
          confidence *= 0.5;
        }
        const payload: BackendMessage = {
          type: "gaze",
          x_norm: clamp01(smoothed[0]),
          y_norm: clamp01(smoothed[1]),
          raw_x_norm: latestRaw[0],
          raw_y_norm: latestRaw[1],
          captured_at_ms: observation.capturedAtMs,
          confidence,
          distance_m: distanceM,
          iris_distance_m: irisDistanceM,
          distance_source: distanceSource,
          eye_open: eyeOpen,
          blink: false,
          gaze_filter: filterMode,
          tracking_source: trackingSource,
          filter_velocity_deg_s: filterMode === "saccade" ? saccadeFilter.velocityDegS : undefined,
          gaze_state:
            filterMode === "saccade"
              ? saccadeFilter.inSaccade
                ? "saccade"
                : saccadeFilter.dwellLocked
                  ? "dwell"
                  : "fixation"
              : undefined,
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
          yaw_deg: headPose?.yawDeg,
          pitch_deg: headPose?.pitchDeg
        };
        if (config.enableLipMotion && config.detector === "yolo") {
          payload.mouth_detected = mouth !== null;
          payload.mouth_open = mouthOpen;
          payload.mouth_open_probability = mouthOpenProbability;
        }
        emit(payload);
        // The ensemble model sits off the startup critical path — its wasm
        // session + warmup start only once the first real gaze frame has
        // emitted. Idempotent; a post-recovery set re-arms it the same way.
        models?.startAppearance?.();
      } catch (error) {
        await handleFrameError(error);
      } finally {
        if (!stopped) {
          // Away mode, matching the dedicated-worker pump: >8s with no face →
          // drop capture+inference to 2fps until someone returns. The floor is
          // a frame-to-frame *period* measured from this tick's start — a fixed
          // post-frame sleep stacked the whole frame's latency on top of it
          // (~60ms inference + 50ms sleep = ~9fps at the default 20fps cap).
          const now = performance.now();
          const awayMs = noFaceSince === 0 ? 0 : now - noFaceSince;
          const minIntervalMs = config.gazeMaxFps > 0 ? 1000 / config.gazeMaxFps : 33;
          const intervalMs = awayMs > 8000 ? Math.max(500, minIntervalMs) : minIntervalMs;
          window.setTimeout(loop, Math.max(0, intervalMs - (now - loopStart)));
        }
      }
    };
    void loop();
  } catch (error) {
    // A camera/canvas failure while sessions were still building must not
    // orphan the created set — dispose whatever the build lands.
    void modelsPromise?.then((built) => disposeRuntimeModels(built, "aborted boot session"), () => undefined);
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
    pursuitBegin: (mode) => {
      pursuitMode = mode === "verify" ? "verify" : "capture";
      if (pursuitMode === "verify") calibration.beginVerify();
      else calibration.beginPursuit();
      pursuitActive = true;
      pursuitTargetHistory.length = 0;
      pursuitLastMsgAt = 0;
      lastPursuitCountEmit = 0;
    },
    pursuitTarget: (x, y) => {
      const at = performance.now();
      pursuitTargetHistory.push({ at, pos: [x, y] });
      pursuitLastMsgAt = at;
      const cutoff = at - 2500;
      while (pursuitTargetHistory.length > 0 && pursuitTargetHistory[0].at < cutoff) pursuitTargetHistory.shift();
    },
    pursuitEnd: () => {
      pursuitActive = false;
      pursuitTargetHistory.length = 0;
      if (pursuitMode === "verify") void calibration.finishVerify();
      else calibration.finishPursuit();
    },
    pursuitAbort: () => {
      pursuitActive = false;
      pursuitMode = "capture";
      pursuitTargetHistory.length = 0;
      pursuitLastMsgAt = 0;
      lastPursuitCountEmit = 0;
      calibration.abortPursuit();
    },
    implicitSample: (xNorm, yNorm) => {
      if (handleImplicitSample(calibration, recentFeatures, xNorm, yNorm, pursuitActive, driftMonitor)) {
        emit({ type: "status", level: "warning", message: "drift_detected" });
      }
    },
    setPaused: (value) => {
      paused = value;
    },
    setFilterOptions: (options) => {
      if (options.dwellLock !== undefined) {
        saccadeFilter.anchorEnabled = options.dwellLock;
      }
    },
    setPreviewEnabled: (value) => {
      previewEnabled = value;
    },
    stop: () => {
      stopped = true;
      presentedFrames?.stop();
      if (repromotionTimer !== null) {
        window.clearTimeout(repromotionTimer);
        repromotionTimer = null;
      }
      setGpuDeviceLostListener(null);
      longTasks.stop();
      // Bounded: a wedged release must not keep a pending promise (and its
      // captured frame state) alive forever.
      void disposeRuntimeModels(models, "stopped session");
      for (const track of stream?.getTracks() ?? []) {
        track.stop();
      }
    }
  };
}

function irisInBox(irisCenter: [number, number] | undefined, box: Detection): [number, number] {
  if (irisCenter === undefined) {
    return [0, 0];
  }
  const [cx, cy] = center(box);
  const halfW = Math.max(4, width(box) * 0.5);
  const halfH = Math.max(3, height(box) * 0.5);
  const ox = Math.max(-1.5, Math.min(1.5, (irisCenter[0] - cx) / halfW));
  const oy = Math.max(-1.5, Math.min(1.5, (irisCenter[1] - cy) / halfH));
  return [ox, oy];
}

// COMETIC-style implicit label: accept a fixated on-screen position only when
// the current map already lands near it — filters "looked elsewhere" moments.
function handleImplicitSample(calibration: Calibration, recentFeatures: TimedFeature[], xNorm: number, yNorm: number, pursuitActive: boolean, driftMonitor: DriftMonitor): boolean {
  if (recentFeatures.length < 3 || pursuitActive) {
    return false;
  }
  if (calibration.featureMap === null && calibration.matrix === null) {
    return false;
  }
  const now = performance.now();
  const featureAt = now - 250;
  let best: TimedFeature | null = null;
  for (const entry of recentFeatures) {
    if (best === null || Math.abs(entry.at - featureAt) < Math.abs(best.at - featureAt)) {
      best = entry;
    }
  }
  if (best === null || Math.abs(best.at - featureAt) > 400) {
    return false;
  }
  const target: [number, number] = [clamp01(xNorm), clamp01(yNorm)];
  const estimate = calibration.applyFeature(best.feature);
  const offset: [number, number] = [target[0] - estimate[0], target[1] - estimate[1]];
  const agreed = Math.hypot(offset[0], offset[1]) <= 0.09;
  const correction = driftMonitor.record(agreed, offset, now, target);
  if (correction !== null) {
    const applied = calibration.applyDriftCorrection(correction[0] * 0.85, correction[1] * 0.85);
    // Match the worker path: escalate at 0.15 cumulative — ~8 sustained
    // confirmations — not the 0.35 hard bound.
    const saturated = Math.hypot(applied[0], applied[1]) >= 0.15;
    console.info("Drift auto-corrected", JSON.stringify({ applied, saturated }));
    if (saturated) {
      return true;
    }
  }
  if (!agreed) {
    // Bounded rejects still carry regional-bias signal: the map predicted a
    // point within 0.2 of this label — close enough that the miss is the
    // map's bias, not a look-elsewhere label. Low weight keeps a stray from
    // steering the field.
    if (Math.hypot(offset[0], offset[1]) <= 0.2) {
      calibration.addResidualBiasEvidence(best.feature, target, 0.3);
    }
    return false;
  }
  calibration.addImplicitSample(best.feature, target);
  void calibration.refitWithImplicit(now);
  return false;
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
  | {
      // Init finished — models built + warmed. The pump holds every frame
      // post until this lands; before it existed, boot churned dead
      // frame→ack cycles for the whole model load.
      type: "ready";
    }
  | { type: "frame_done" }
  | { type: "backend"; payload: BackendMessage }
  | { type: "calibration_read"; id: number; path: string }
  | { type: "calibration_write"; id: number; path: string; payload: unknown };

type MainToWorkerMessage =
  | { type: "init"; config: WebInferenceConfig }
  | {
      // Posted the moment getUserMedia answers so the worker's model build
      // (launched by init) overlaps camera acquisition. Carries the
      // DELIVERED dims — under the default-policy VGA fallback they differ
      // from the request and the projector/calibration fingerprint must
      // reconcile off them.
      type: "camera_geometry";
      width: number;
      height: number;
      resolutionName?: string;
    }
  | {
      type: "frame";
      data?: Uint8ClampedArray<ArrayBuffer>;
      bitmap?: ImageBitmap;
      width: number;
      height: number;
      captureMs: number;
      capturedAt: number;
      capturedAtMs?: number;
      frameIntervalMs?: number;
      droppedFrames: number;
      mainThreadLongTasks: number;
    }
  | { type: "pursuit_begin"; mode?: "capture" | "verify" }
  | { type: "pursuit_target"; x: number; y: number; at: number }
  | { type: "pursuit_end" }
  | { type: "pursuit_abort" }
  | { type: "implicit_sample"; x_norm: number; y_norm: number }
  | { type: "set_paused"; paused: boolean }
  | { type: "filter_options"; dwellLock?: boolean }
  | { type: "set_preview"; enabled: boolean }
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
  let presentedFrames: PresentedFrames | undefined;
  let paused = false;
  let inFlight = false;
  let inFlightSince = 0;
  let droppedFrames = 0;
  let lastCapture = 0;
  let captureTimer: number | null = null;
  // The pump is ack-driven: frame_done itself schedules the next capture, so
  // the only self-wake is the in-flight watchdog (or the paused heartbeat).
  // Assigned once the camera is open — a frame_done can't arrive before the
  // first frame is posted anyway.
  let scheduleNextCapture: (() => void) | null = null;
  const longTasks = createLongTaskCounter();
  const worker = new InferenceWorker();

  const post = (message: MainToWorkerMessage, transfer?: Transferable[]) => {
    worker.postMessage(message, transfer ?? []);
  };

  // Away detection, mirroring the worker's noFaceSince: the first "no_face"
  // hold emit starts the away clock — the pump can then drop to 2fps and save
  // ~90% of the frame copy/transfer cost until a face returns. The worker's
  // away heartbeat keeps emitting held_reason "no_face" so this stays armed.
  let noFaceSince = 0;
  // The worker's init is its long pole (model build + warmup). Frames posted
  // before it's done were only ever dead work — the worker dropped each one
  // and acked, so the pump burned the full transfer cost for nothing. Now it
  // signals `ready` and the pump waits on that instead.
  let workerReady = false;

  worker.onmessage = (event: MessageEvent<WorkerToMainMessage>) => {
    const message = event.data;
    if (message.type === "ready") {
      workerReady = true;
      scheduleNextCapture?.();
    } else if (message.type === "backend") {
      if (message.payload.type === "gaze") {
        if (message.payload.held_reason === "no_face") {
          if (noFaceSince === 0) {
            noFaceSince = performance.now();
          }
        } else {
          noFaceSince = 0;
        }
      }
      emit(message.payload);
    } else if (message.type === "frame_done") {
      inFlight = false;
      // The ack is the cadence — repost as soon as the worker frees up. The
      // gazeMaxFps floor and away mode still apply inside the scheduler.
      scheduleNextCapture?.();
    } else if (message.type === "calibration_read") {
      window.gazeBridge
        .readCalibration(message.path)
        .then((response) => {
          post({ type: "calibration_read_result", id: message.id, response });
        })
        .catch((error: unknown) => {
          // A rejected/throwing bridge must not leave the worker's pending
          // request hanging — answer with an error so load()/save() unwinds.
          post({
            type: "calibration_read_result",
            id: message.id,
            response: { ok: false, error: error instanceof Error ? error.message : String(error) }
          });
        });
    } else if (message.type === "calibration_write") {
      window.gazeBridge
        .writeCalibration(message.path, message.payload)
        .then((response) => {
          post({ type: "calibration_write_result", id: message.id, response });
        })
        .catch((error: unknown) => {
          post({
            type: "calibration_write_result",
            id: message.id,
            response: { ok: false, error: error instanceof Error ? error.message : String(error) }
          });
        });
    }
  };
  worker.onerror = (event) => {
    inFlight = false;
    const payload: BackendMessage = {
      type: "status",
      level: "error",
      message: `Inference worker error: ${event.message}`,
      runtime: config.runtime,
      logged: true
    };
    logStatus(payload, event);
    emit(payload);
    // The in-flight frame is dead with the error — resume the pump rather
    // than waiting out the watchdog.
    scheduleNextCapture?.();
  };

  try {
    // init goes out BEFORE the camera answers: the worker's model build —
    // the boot's long pole — overlaps getUserMedia instead of serializing
    // behind it. The init carries the REQUESTED dims; the delivered
    // resolution follows as camera_geometry below, and the worker gates
    // projector dims + the calibration fingerprint on it (a default-policy
    // VGA fallback must never enter the fingerprint as the 720p asked-for).
    post({
      type: "init",
      config: {
        ...config,
        assetBaseUrl: window.location.href
      }
    });
    const camera = await openCamera(
      config.camera,
      requestedCameraResolution(config),
      config.gazeMaxFps,
      emit,
      defaultCameraFallback(config)
    );
    stream = camera.stream;
    const video = camera.video;
    const captureWidth = camera.resolution.width;
    const captureHeight = camera.resolution.height;
    post({
      type: "camera_geometry",
      width: captureWidth,
      height: captureHeight,
      resolutionName: camera.resolution.name ?? `${captureWidth}x${captureHeight}`
    });
    const canvas = document.createElement("canvas");
    canvas.width = captureWidth;
    canvas.height = captureHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) {
      throw new Error("2D canvas context is not available");
    }

    // A frame_done that never arrives (worker wedged mid-frame) must not stall
    // the pump forever — this is the only self-wake while a frame is in flight.
    const IN_FLIGHT_WATCHDOG_MS = 2000;
    const frames = presentedFrames = new PresentedFrames(video);
    const scheduleCapture = (delayMs: number) => {
      if (captureTimer !== null) {
        window.clearTimeout(captureTimer);
      }
      captureTimer = window.setTimeout(() => {
        captureTimer = null;
        void captureLoop();
      }, Math.max(0, delayMs));
    };
    // Wall-clock floor shared by the ack path and the timer paths: captures
    // never start closer than 1/gazeMaxFps. Away mode: >8s without a face →
    // 2fps; the worker-side search interval still spots a returning face on
    // these sparse frames.
    const captureWaitMs = (now: number): number => {
      const minIntervalMs = config.gazeMaxFps > 0 ? 1000 / config.gazeMaxFps : 0;
      const awayMs = noFaceSince === 0 ? 0 : now - noFaceSince;
      const intervalMs = awayMs > 8000 ? Math.max(500, minIntervalMs) : minIntervalMs;
      return lastCapture > 0 ? Math.max(0, intervalMs - (now - lastCapture)) : 0;
    };
    scheduleNextCapture = () => {
      if (stopped) {
        return;
      }
      if (paused) {
        scheduleCapture(33);
        return;
      }
      if (inFlight) {
        // Ack paths clear inFlight before scheduling, so reaching this means
        // a stray wake — re-arm the watchdog remainder, never a blind poll.
        scheduleCapture(IN_FLIGHT_WATCHDOG_MS - (performance.now() - inFlightSince));
        return;
      }
      const waitMs = captureWaitMs(performance.now());
      if (waitMs > 0) {
        scheduleCapture(waitMs);
      } else {
        void captureLoop();
      }
    };

    const captureLoop = async () => {
      if (stopped) {
        return;
      }
      if (paused) {
        // Paused: never post a frame — zero inference cost. The pump stays
        // alive on a slow heartbeat so unpause resumes without a kick; the
        // worker also drops any already-posted frame silently.
        scheduleCapture(33);
        return;
      }
      if (!workerReady) {
        // Init still running (model build/warmup) — hold frame posts
        // entirely and poll cheaply. The old pump ack-churned dead frames
        // through the whole boot; now the worker says `ready` once its
        // sessions are warm.
        scheduleCapture(250);
        return;
      }
      if (inFlight) {
        // The only self-scheduled wake while in-flight is the watchdog.
        const waited = performance.now() - inFlightSince;
        if (waited < IN_FLIGHT_WATCHDOG_MS) {
          scheduleCapture(IN_FLIGHT_WATCHDOG_MS - waited);
          return;
        }
        inFlight = false;
        droppedFrames += 1;
        const payload: BackendMessage = {
          type: "status",
          level: "warning",
          message: "Inference worker did not finish a frame within 2s; resuming capture",
          runtime: config.runtime,
          logged: true
        };
        logStatus(payload);
        emit(payload);
      }
      const waitMs = captureWaitMs(performance.now());
      if (waitMs > 0) {
        scheduleCapture(waitMs);
        return;
      }
      inFlight = true;
      inFlightSince = performance.now();
      const captureStart = inFlightSince;
      const frameIntervalMs = lastCapture > 0 ? captureStart - lastCapture : undefined;
      lastCapture = captureStart;
      const mainThreadLongTasks = longTasks.count();
      const dropped = droppedFrames;
      let bitmap: ImageBitmap | null = null;
      const observation = frames.take();
      try {
        bitmap = await createImageBitmap(observation.source);
      } catch {
        if (!stopped) ctx.drawImage(observation.source, 0, 0, captureWidth, captureHeight);
      } finally {
        observation.close?.();
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
            width: captureWidth,
            height: captureHeight,
            captureMs: performance.now() - captureStart,
            capturedAt: captureStart,
            capturedAtMs: observation.capturedAtMs,
            frameIntervalMs,
            droppedFrames: dropped,
            mainThreadLongTasks
          },
          [bitmap]
        );
      } else {
        const frame = ctx.getImageData(0, 0, captureWidth, captureHeight);
        post(
          {
            type: "frame",
            data: frame.data,
            width: frame.width,
            height: frame.height,
            captureMs: performance.now() - captureStart,
            capturedAt: captureStart,
            capturedAtMs: observation.capturedAtMs,
            frameIntervalMs,
            droppedFrames: dropped,
            mainThreadLongTasks
          },
          [frame.data.buffer]
        );
      }
      // The next post is armed by frame_done — this timer is only the wedge
      // watchdog, not the cadence.
      scheduleCapture(IN_FLIGHT_WATCHDOG_MS);
    };
    void captureLoop();
  } catch (error) {
    // Camera acquisition can fail AFTER init went out — the worker is then
    // parked on its camera_geometry wait. Release it so init unwinds and
    // the in-flight model build's sessions get disposed.
    post({ type: "stop" });
    const payload: BackendMessage = {
      type: "status",
      level: "error",
      message: error instanceof Error ? error.message : String(error),
      runtime: config.runtime,
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
  }

  return {
    pursuitBegin: (mode) => {
      post({ type: "pursuit_begin", mode });
    },
    pursuitTarget: (x, y) => {
      post({ type: "pursuit_target", x, y, at: performance.now() });
    },
    pursuitEnd: () => {
      post({ type: "pursuit_end" });
    },
    pursuitAbort: () => {
      post({ type: "pursuit_abort" });
    },
    implicitSample: (xNorm, yNorm) => {
      post({ type: "implicit_sample", x_norm: xNorm, y_norm: yNorm });
    },
    setPaused: (value) => {
      paused = value;
      post({ type: "set_paused", paused: value });
    },
    setFilterOptions: (options) => {
      post({ type: "filter_options", dwellLock: options.dwellLock });
    },
    setPreviewEnabled: (value) => {
      post({ type: "set_preview", enabled: value });
    },
    stop: () => {
      stopped = true;
      if (captureTimer !== null) {
        window.clearTimeout(captureTimer);
      }
      presentedFrames?.stop();
      longTasks.stop();
      post({ type: "stop" });
      // Terminating synchronously discards the queued stop — let the worker's
      // dispose handler run first, then tear down on the next macrotask.
      window.setTimeout(() => worker.terminate(), 0);
      for (const track of stream?.getTracks() ?? []) {
        track.stop();
      }
    }
  };
}

// The default policy in one place: an explicit --camera-resolution always
// arrives with a name (main.cjs names presets and synthesizes "WxH" for
// explicit dims), so an unnamed config carrying the built-in default dims
// is the only "try harder" case — named requests keep their exact-or-fail
// semantics and a delivery failure surfaces as an error.
function isDefaultCameraRequest(config: WebInferenceConfig): boolean {
  return (
    config.cameraResolutionName === undefined &&
    config.cameraWidth === DEFAULT_CAMERA_RESOLUTION.width &&
    config.cameraHeight === DEFAULT_CAMERA_RESOLUTION.height
  );
}

// The resolution descriptor to ask for — default runs ask for the named
// preset so telemetry reports "HD" rather than the bare dims.
function requestedCameraResolution(config: WebInferenceConfig): CameraResolution {
  if (isDefaultCameraRequest(config)) {
    return DEFAULT_CAMERA_RESOLUTION;
  }
  return { name: config.cameraResolutionName, width: config.cameraWidth, height: config.cameraHeight };
}

function defaultCameraFallback(config: WebInferenceConfig): CameraResolution | null {
  return isDefaultCameraRequest(config) ? FALLBACK_CAMERA_RESOLUTION : null;
}

// Returns the resolution the sensor ACTUALLY delivered — under the
// default-policy fallback that differs from the request, and every
// downstream consumer (canvas, projector, detector scaling, calibration
// fingerprint) must key off it rather than the configured dims.
async function openCamera(
  camera: string,
  requested: CameraResolution,
  gazeMaxFps: number,
  emit: (payload: BackendMessage) => void,
  fallback: CameraResolution | null
): Promise<{ stream: MediaStream; video: HTMLVideoElement; resolution: CameraResolution }> {
  const constraints = await cameraConstraints(camera);
  const attempt = async (resolution: CameraResolution) => {
    // Bounded: a camera that accepts-but-never-delivers must surface as an
    // error, not wedge boot. If getUserMedia resolves AFTER the deadline
    // the stream is still real — stop its tracks so the LED doesn't stay
    // on for a capture nobody drives (same late-settle pattern as the
    // orphaned InferenceSession cleanup in runtimes.ts).
    const pending = navigator.mediaDevices.getUserMedia({
      video: {
        ...constraints,
        width: { exact: resolution.width },
        height: { exact: resolution.height },
        // ideal (not exact): unusual cameras may not hit the requested rate —
        // ask politely rather than fail the constraint.
        frameRate: { ideal: gazeMaxFps > 0 ? gazeMaxFps : 30 }
      },
      audio: false
    });
    const stream = await withTimeout(pending, CAMERA_OPEN_TIMEOUT_MS, "camera getUserMedia").catch((error) => {
      void pending.then(
        (late) => {
          for (const track of late.getTracks()) {
            track.stop();
          }
        },
        () => undefined
      );
      throw error;
    });
    try {
      const video = document.createElement("video");
      video.autoplay = true;
      video.muted = true;
      video.playsInline = true;
      video.srcObject = stream;
      await withTimeout(video.play(), CAMERA_OPEN_TIMEOUT_MS, "camera video play");
      await waitForVideo(video);
      const settings = stream.getVideoTracks()[0]?.getSettings();
      const actualWidth = settings?.width ?? video.videoWidth;
      const actualHeight = settings?.height ?? video.videoHeight;
      if (actualWidth !== resolution.width || actualHeight !== resolution.height) {
        throw new Error(`Camera returned ${actualWidth}x${actualHeight}, expected ${resolution.width}x${resolution.height}`);
      }
      return { stream, video, resolution };
    } catch (error) {
      // A failed attempt must not leak a live capture — the retry or the
      // caller's error path decides what happens next.
      for (const track of stream.getTracks()) {
        track.stop();
      }
      throw error;
    }
  };
  try {
    return await attempt(requested);
  } catch (error) {
    if (fallback === null || (fallback.width === requested.width && fallback.height === requested.height)) {
      throw error;
    }
    const payload: BackendMessage = {
      type: "status",
      level: "warning",
      message: `Camera could not deliver ${requested.width}x${requested.height} (${error instanceof Error ? error.message : String(error)}); falling back to ${fallback.width}x${fallback.height}`,
      camera_width: fallback.width,
      camera_height: fallback.height,
      camera_resolution_name: fallback.name,
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
    return attempt(fallback);
  }
}

async function cameraConstraints(camera: string): Promise<MediaTrackConstraints> {
  const index = Number.parseInt(camera, 10);
  if (Number.isFinite(index) && String(index) === camera.trim()) {
    const devices = (await withTimeout(navigator.mediaDevices.enumerateDevices(), CAMERA_OPEN_TIMEOUT_MS, "camera enumerateDevices")).filter((device) => device.kind === "videoinput");
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
