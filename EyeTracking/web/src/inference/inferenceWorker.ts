import type { BackendMessage, WebAccelerator, WebInferenceConfig } from "../global";
import { logStatus } from "../logger";
import {
  AppearanceChannel,
  Calibration,
  DisplayGeometry,
  DISTANCE_MAX_M,
  DISTANCE_MIN_M,
  DISTANCE_SMOOTHING_ALPHA,
  GazeAngleSmoother,
  GazeJumpGate,
  HeadPoseBaseline,
  LIP_MOTION_OPEN_THRESHOLD,
  OneEuroFilter,
  PREVIEW_WIDTH,
  previewHeightFor,
  renderPreviewAnnotations,
  SaccadeAwareGazeFilter,
  ScreenProjector,
  EyeValidity,
  calibrationContextFingerprint,
  center,
  clamp01,
  coastPosition,
  DriftMonitor,
  isHeadTurned,
  interpolateTargetAt,
  isRecoverableInferenceError,
  reanchorDetection,
  type DetectionResult,
  type GazeEstimate,
  type GazeFeature,
  type TimedFeature,
  height,
  type Detection,
  width
} from "./core";
import { createRuntimeModels, setGpuDeviceLostListener, warmupRuntimeModels, withTimeout, type RuntimeModels } from "./runtimes";

type MainToWorkerMessage =
  | { type: "init"; config: WebInferenceConfig }
  | {
      // The pump posts this the moment getUserMedia answers so init's model
      // build can overlap camera acquisition — the calibration fingerprint
      // and projector dims reconcile off the DELIVERED resolution, not the
      // request (a default-policy VGA fallback is exactly when they differ).
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

type WorkerToMainMessage =
  | {
      // Posted once init has models warmed — the main-side pump holds all
      // frame posts until this lands, so boot no longer runs the dead-frame
      // ack churn (capture → initializing drop → ack → repost at full fps).
      type: "ready";
    }
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
// Corrected-space guard (same as webRuntime): a fitted map should never jump
// 0.1 in one frame — one confirming sample still lets a real saccade through.
let correctedGate = new GazeJumpGate(0.1, 0.05, 500, 1000);
let smoothed: [number, number] | null = null;
let smoothedDistance: number | null = null;
const eyeValidity = new EyeValidity();
const appearanceChannel = new AppearanceChannel();
const driftMonitor = new DriftMonitor();
// Coast state: last filtered velocity lets held frames ease along the
// pre-hold motion instead of freezing (capped inside coastPosition).
let smoothedPrev: [number, number] | null = null;
let smoothedVel: [number, number] = [0, 0];
let smoothedPrevAt = 0;
let holdStartMs = 0;
let smoothedHeadRoll: number | null = null;
// EMA of the metric pose roll — one bad mesh vertex can snap the raw roll
// several degrees, which pivots every de-rotated gaze angle it feeds.
let smoothedPoseRoll: number | null = null;
// Jaw rest baseline — slow EMA of mouth position so jaw features are deltas
// from rest, firing on CHANGE (speech, jaw drop) not absolute mouth pose.
let jawBaselineX: number | null = null;
let jawBaselineY: number | null = null;
let filterX = new OneEuroFilter();
let filterY = new OneEuroFilter();
let saccadeFilter = new SaccadeAwareGazeFilter();
let angleSmoother = new GazeAngleSmoother();
// Session straight-ahead for the metric head pose — re-seeded on init like
// the other per-session estimators.
let poseBaseline = new HeadPoseBaseline();
let lastDetection: DetectionResult | null = null;
let noFaceSince = 0;
let lastDetectMs = 0;
let forceRedetect = false;
let frameCanvas: OffscreenCanvas | null = null;
let frameCtx: OffscreenCanvasRenderingContext2D | null = null;
let appliedGeometryKey: string | null = null;
let lastStatus = 0;
let lastPreview = 0;
let lastProjectionWarning = 0;
let lastProcessed = 0;
let paused = false;
let fallbackInProgress = false;
// Latched once the last-resort wasm rebuild exhausts its attempts — frames
// then skip inference cleanly instead of throwing on a dead session at 1Hz.
let inferenceUnrecoverable = false;
// initialize() bumps this so an in-flight rebuild abandons its result
// rather than stomping the freshly loaded sessions.
let initEpoch = 0;
// filter_options state lives outside the filter so a rebuilt filter (every
// initialize()) picks the current setting back up.
let filterDwellLock = true;
let previewEnabled = true;
let lastEmitCore: { x: number; y: number; distance: number; yaw?: number; pitch?: number } | null = null;
let dropStreakStart = 0;
// Away heartbeat: once a drop streak passes the hold horizon the marker is
// gone, but the gaze channel doubles as the host's liveness signal
// (gaze.updated_at). Keep a ~1Hz away:true heartbeat flowing — the boot-time
// case (user away when the tracker starts) has no lastEmitCore at all, so
// the heartbeat can't wait on one.
const AWAY_HEARTBEAT_MS = 1000;
// Starts one period due so the first no-face frame emits a beat
// immediately — liveness shouldn't wait a full second.
let lastAwayBeat = -AWAY_HEARTBEAT_MS;
// The DELIVERED camera dims arrive via camera_geometry — posted by the
// pump once getUserMedia answers, which may be before or after this init's
// model build finishes. A stop message resolves the wait with null so a
// failed camera can't leave initialize() hanging.
let deliveredCameraGeometry: { width: number; height: number; resolutionName?: string } | null = null;
let cameraGeometryWaiter: ((geometry: { width: number; height: number; resolutionName?: string } | null) => void) | null =
  null;
// Pursuit calibration state — the renderer streams the moving target's
// position; each accepted frame's feature is tagged with the freshest target.
let pursuitActive = false;
let pursuitMode: "capture" | "verify" = "capture";
// Renderer-clock target history lets each frame's feature pair with the
// target's position at the camera's capture instant — the mesh describes
// where the eye WAS ~30-90ms ago, not where the dot is now.
const pursuitTargetHistory: Array<{ at: number; pos: [number, number] }> = [];
let pursuitLastMsgAt = 0;

// Label lag = camera exposure (~1 frame) + the eye's own smooth-pursuit
// latency (~100-125ms, Rashbass) — during tracking the eye trails the dot,
// so the honest label for this frame's feature is where the dot WAS.
const PURSUIT_LABEL_LAG_MS = 120;

function pursuitLabelAt(t: number): [number, number] | null {
  return interpolateTargetAt(pursuitTargetHistory, t);
}

// How long the target has been parked at `pos` before time `t` — the
// saccade-settle gate. The first ~280ms of a dwell still contain the landing
// saccade and post-saccadic oscillation; those frames carry the target's
// label but the eye wasn't there yet, which is what polluted early-dwell
// calibration samples were. Capture only once the label is stable.
function pursuitDwellMs(t: number, pos: [number, number]): number {
  let first = t;
  for (let i = pursuitTargetHistory.length - 1; i >= 0; i -= 1) {
    const e = pursuitTargetHistory[i];
    if (e.at > t) continue;
    if (Math.hypot(e.pos[0] - pos[0], e.pos[1] - pos[1]) > 0.005) break;
    first = e.at;
  }
  return t - first;
}
const PURSUIT_SETTLE_MS = 280;
let lastPursuitCountEmit = 0;

// On a dropped frame the marker should hold at the last stable pose rather
// than freeze-and-expire; hold emits carry the reason for diagnostics. After
// ~8s of continuous drops the marker is allowed to expire (real absence) —
// but the pipeline is still alive and the host keys its wedge watch off
// gaze.updated_at, so the no-face path keeps a ~1Hz away heartbeat going
// forever. The heartbeat is liveness, not a sample: no coordinates, and
// `away: true` marks it for any consumer that inspects the flag.
function emitHold(reason: string, rejectedRaw?: [number, number]): void {
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
        confidence: 0,
        captured_at_ms: Date.now()
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
    captured_at_ms: Date.now(),
    confidence: 0.2,
    distance_m: lastEmitCore.distance,
    yaw_deg: lastEmitCore.yaw,
    pitch_deg: lastEmitCore.pitch,
    held_reason: reason
  });
}

// No-face is a normal operating state (looked away, stepped out, bad
// lighting), not a frame error — the pipeline used to throw it into
// handleFrameError every frame, paying a per-frame exception just to reach
// that handler's 1Hz status throttle. Emit the same throttled status
// directly: state.status and the status pane keep reporting why no gaze is
// flowing, and `logged: true` keeps the console calm — presence already
// flows through the preview's head_detected flag and the gaze
// away-heartbeat, so nothing needs a log line per second of absence.
function emitNoFaceStatus(now: number, message: string): void {
  if (now - lastStatus <= 1000) {
    return;
  }
  lastStatus = now;
  emit({
    type: "status",
    level: "warning",
    message,
    runtime: config?.runtime,
    accelerator: models?.accelerator,
    logged: true
  });
}
let initializing = false;
let stopped = false;
// Frame serialization: processFrameMessage must never overlap itself — two
// frames in flight interleave detect/estimate chains on shared detection
// state. The main-side pump already drops while a frame is in flight and
// only re-posts after its 2s wedge timeout, so a second frame arriving here
// is by definition stale: ack it like a normal drop so the pump never stalls.
let frameProcessing = false;
// wasm→webgpu re-promotion: armed after any wasm landing while the config
// prefers the fast path. Reset per init; the counter is per demotion episode
// (cleared whenever webgpu becomes live again).
let repromotionAttempts = 0;
let repromotionTimer: ReturnType<typeof globalThis.setTimeout> | null = null;
let repromotionInFlight = false;
let requestId = 0;
const pendingReads = new Map<number, (value: { ok: true; text: string | null } | { ok: false; error: string }) => void>();
const pendingWrites = new Map<number, (value: { ok: true; path: string } | { ok: false; error: string }) => void>();

const post = (message: WorkerToMainMessage) => {
  self.postMessage(message);
};

const DETECT_INTERVAL_MS = 1000;

// A released session frees its wasm heap asynchronously — a reload raced
// against that free re-faults with the same OOM ("memory access out of
// bounds"), which is how a recoverable crash became a permanent wedge.
// The backoff gives each retry a genuinely clean heap; bounded, because a
// permanently broken stack must not retry and log every frame forever.
// The wasm ladder keeps the original timings; a transient webgpu device loss
// gets a much shorter ladder — 21s of dead gaze for a Dawn hiccup is a worse
// outcome than the demotion it replaced.
const SESSION_RECOVERY_DELAYS_MS = [3000, 6000, 12000];
const WEBGPU_RECOVERY_DELAYS_MS = [1500, 5000];
// ORT 1.26 could wedge release() forever inside a Dawn callback (upstream
// UB, fixed in 1.29+). Recovery must never await an unbounded dispose or
// create — the timeout is what keeps a hung release from ending the tracker.
const SESSION_DISPOSE_TIMEOUT_MS = 5000;
const MODEL_CREATE_TIMEOUT_MS = 30000;
const SESSION_PROBE_TIMEOUT_MS = 30000;
// Re-promotion: after a wasm recovery the tracker keeps probing webgpu —
// first at +60s (let the device-loss transient settle), then on a 5min
// cadence, bounded per demotion episode so a hard-broken GPU doesn't churn.
const WEBGPU_REPROMOTION_FIRST_DELAY_MS = 60_000;
const WEBGPU_REPROMOTION_CADENCE_MS = 300_000;
const WEBGPU_REPROMOTION_MAX_ATTEMPTS = 4;
// After a promotion swap the old wasm set lingers briefly so an in-flight
// frame/appearance run finishes on it rather than faulting mid-release.
const SWAPPED_SET_DISPOSE_DELAY_MS = 2000;

function decodeFrame(message: Extract<MainToWorkerMessage, { type: "frame" }>): ImageData {
  if (frameCanvas === null || frameCanvas.width !== message.width || frameCanvas.height !== message.height) {
    frameCanvas = new OffscreenCanvas(message.width, message.height);
    frameCtx = frameCanvas.getContext("2d", { willReadFrequently: true });
  }
  if (frameCtx === null) {
    throw new Error("2D canvas context is not available in inference worker");
  }
  if (message.bitmap) {
    try {
      frameCtx.drawImage(message.bitmap, 0, 0);
    } finally {
      message.bitmap.close();
    }
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
    if (payload.status === "saved") {
      // A fresh map is a fresh drift baseline — reset the monitor so stale
      // rejections from the old geometry don't re-alarm on the first label.
      driftMonitor.reset();
      appearanceChannel.reset();
      // The map changed under the filter chain — stale smoothed/anchor state
      // would pin the marker where the OLD map thought gaze was.
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

// GPU device-loss telemetry from runtimes.ts: reason "destroyed" is ORT's
// own release() teardown and is filtered there — anything that lands here is
// a real loss worth a status line for the host log.
setGpuDeviceLostListener((info) => {
  const payload: BackendMessage = {
    type: "status",
    level: "warning",
    message: `GPU device lost: reason=${info.reason} message=${info.message}`,
    runtime: config?.runtime,
    accelerator: "webgpu",
    logged: true
  };
  logStatus(payload);
  emit(payload);
});

self.onmessage = (event: MessageEvent<MainToWorkerMessage>) => {
  const message = event.data;
  if (message.type === "frame") {
    if (frameProcessing) {
      // Overlapping processFrameMessage calls interleave detect/estimate on
      // shared state — drop this frame but still ack, matching the pump's
      // dropped-frame contract (in-flight timeout ⇒ post ⇒ we ack fast).
      message.bitmap?.close();
      post({ type: "frame_done" });
      return;
    }
    frameProcessing = true;
    void processFrameMessage(message)
      .catch((frameError) => console.warn("frame processing escaped its handler", frameError))
      .finally(() => {
        frameProcessing = false;
      });
    return;
  }
  // Control messages never queue behind a frame: stop/init/pause/calibration
  // must land immediately even while a slow inference is mid-flight.
  void handleMessage(message);
};

async function handleMessage(message: MainToWorkerMessage): Promise<void> {
  if (message.type === "init") {
    await initialize(message.config);
  } else if (message.type === "camera_geometry") {
    // The delivered capture dims — posted once getUserMedia resolves. If an
    // init is parked on the wait, release it; if it hasn't reached the wait
    // yet, the stash answers it.
    deliveredCameraGeometry = { width: message.width, height: message.height, resolutionName: message.resolutionName };
    const waiter = cameraGeometryWaiter;
    cameraGeometryWaiter = null;
    waiter?.(deliveredCameraGeometry);
  } else if (message.type === "pursuit_begin") {
    pursuitMode = message.mode === "verify" ? "verify" : "capture";
    if (pursuitMode === "verify") calibration?.beginVerify();
    else calibration?.beginPursuit();
    pursuitActive = true;
    pursuitTargetHistory.length = 0;
    pursuitLastMsgAt = 0;
    lastPursuitCountEmit = 0;
  } else if (message.type === "pursuit_target") {
    pursuitTargetHistory.push({ at: message.at, pos: [message.x, message.y] });
    pursuitLastMsgAt = performance.now();
    const cutoff = message.at - 2500;
    while (pursuitTargetHistory.length > 0 && pursuitTargetHistory[0].at < cutoff) pursuitTargetHistory.shift();
  } else if (message.type === "pursuit_end") {
    pursuitActive = false;
    pursuitTargetHistory.length = 0;
    if (pursuitMode === "verify") void calibration?.finishVerify();
    else calibration?.finishPursuit();
  } else if (message.type === "pursuit_abort") {
    pursuitActive = false;
    pursuitMode = "capture";
    pursuitTargetHistory.length = 0;
    pursuitLastMsgAt = 0;
    lastPursuitCountEmit = 0;
    calibration?.abortPursuit();
  } else if (message.type === "implicit_sample") {
    handleImplicitSample(message.x_norm, message.y_norm);
  } else if (message.type === "set_paused") {
    paused = message.paused;
  } else if (message.type === "set_preview") {
    previewEnabled = message.enabled;
  } else if (message.type === "filter_options") {
    if (message.dwellLock !== undefined) {
      filterDwellLock = message.dwellLock;
      saccadeFilter.anchorEnabled = message.dwellLock;
    }
  } else if (message.type === "stop") {
    stopped = true;
    settlePendingCalibrationRequests("runtime stopped");
    // A camera-acquire failure on the main side arrives as stop — release
    // any parked geometry wait so initialize() unwinds instead of hanging.
    cameraGeometryWaiter?.(null);
    cameraGeometryWaiter = null;
    if (repromotionTimer !== null) {
      globalThis.clearTimeout(repromotionTimer);
      repromotionTimer = null;
    }
    const outgoing = models;
    models = null;
    // Swallows + bounds: a wedged release must not leave an unobserved
    // rejection hanging off the worker.
    void disposeRuntimeModels(outgoing, "stopped session");
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
  paused = false;
  previewEnabled = !nextConfig.hidePreview;
  fallbackInProgress = false;
  inferenceUnrecoverable = false;
  initEpoch += 1;
  // A second init can re-enter while this one is parked on an await — every
  // commit point below re-checks the epoch so a stale init can't install
  // superseded models, clobber the flag, or post a stale `ready`.
  const epoch = initEpoch;
  latestRaw = null;
  recentFeatures.length = 0;
  jumpGate = new GazeJumpGate();
  correctedGate = new GazeJumpGate(0.1, 0.05, 500, 1000);
  smoothed = null;
  smoothedDistance = null;
  smoothedPrev = null;
  smoothedVel = [0, 0];
  smoothedPrevAt = 0;
  holdStartMs = 0;
  eyeValidity.reset();
  appearanceChannel.reset();
  driftMonitor.reset();
  smoothedHeadRoll = null;
  smoothedPoseRoll = null;
  jawBaselineX = null;
  jawBaselineY = null;
  filterX = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  filterY = new OneEuroFilter(config.filterMincutoff ?? 1.0, config.filterBeta ?? 0.7, config.filterDcutoff ?? 1.0);
  saccadeFilter = new SaccadeAwareGazeFilter();
  saccadeFilter.anchorEnabled = filterDwellLock;
  angleSmoother = new GazeAngleSmoother();
  poseBaseline = new HeadPoseBaseline();
  lastDetection = null;
  noFaceSince = 0;
  lastDetectMs = 0;
  forceRedetect = false;
  appliedGeometryKey = null;
  lastStatus = 0;
  lastPreview = 0;
  lastProjectionWarning = 0;
  lastProcessed = 0;
  lastEmitCore = null;
  dropStreakStart = 0;
  lastAwayBeat = 0;
  // A stale geometry from a previous init's camera must never satisfy this
  // one — the pump posts camera_geometry per session, after its init. And a
  // prior init still parked on the wait must unwind rather than hang.
  deliveredCameraGeometry = null;
  cameraGeometryWaiter?.(null);
  cameraGeometryWaiter = null;
  pursuitActive = false;
  pursuitMode = "capture";
  pursuitTargetHistory.length = 0;
  pursuitLastMsgAt = 0;
  lastPursuitCountEmit = 0;
  // A fresh init is a new demotion episode — cancel any pending re-promotion
  // and re-arm the attempt budget.
  if (repromotionTimer !== null) {
    globalThis.clearTimeout(repromotionTimer);
    repromotionTimer = null;
  }
  repromotionAttempts = 0;
  // A fresh init abandons any in-flight bridge IO — resolve it with an error
  // so a wedged load()/save() unwinds instead of hanging forever.
  settlePendingCalibrationRequests("runtime re-initialized");
  requestId = 0;
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
  try {
    // The session build starts BEFORE the camera answers — its seconds of
    // wasm/webgpu compilation overlap getUserMedia instead of serializing
    // behind it. The previous-set dispose and the webgpu→wasm fallback
    // ladder are unchanged, just launched up front; every geometry-sensitive
    // step (projector dims, the calibration context fingerprint, load())
    // waits on the camera_geometry message below.
    const previousModels = models;
    models = null;
    const modelsPromise = buildModelSet(nextConfig, previousModels);
    // Rejections surface through the await below — observe them now so a
    // failing build can't read as an unhandled rejection while the camera
    // geometry and calibration.load() are still in flight.
    void modelsPromise.catch(() => undefined);

    // The pump posts camera_geometry the moment getUserMedia answers — that
    // may be before or after the model build lands. The DELIVERED dims are
    // the truth: under the default-policy VGA fallback they differ from the
    // request, and projector/fingerprint must see them, not the ask.
    const geometry = await waitForCameraGeometry();
    if (stopped || geometry === null || epoch !== initEpoch) {
      if (epoch === initEpoch) {
        initializing = false;
      }
      // The build may still be in flight — dispose whatever it produced so
      // an aborted/superseded boot can't leave orphan sessions on the heap.
      void modelsPromise.then((built) => disposeRuntimeModels(built, "aborted boot session"), () => undefined);
      return;
    }
    // `config`/`projector`/`calibration` globals are still this init's —
    // the epoch guard above already retired us if a newer init replaced
    // them — so binding through them here is safe.
    config.cameraWidth = geometry.width;
    config.cameraHeight = geometry.height;
    config.cameraResolutionName = geometry.resolutionName ?? `${geometry.width}x${geometry.height}`;
    projector.setCameraSize(geometry.width, geometry.height);
    // Tag this run's projection/display context before load() — a file fit
    // under a different context keeps its feature-space state but drops the
    // raw-space fit (affine/RBF/source bounds) and any persisted drift offset.
    calibration.contextFingerprint = calibrationContextFingerprint({
      gazeProjectionMode: nextConfig.gazeProjectionMode,
      displayWidth: nextConfig.displayWidth,
      displayHeight: nextConfig.displayHeight,
      displaySizeInch: nextConfig.displaySizeInch,
      cameraFov: nextConfig.cameraFov,
      cameraWidth: geometry.width,
      cameraHeight: geometry.height,
      cameraScreenX: nextConfig.cameraScreenX,
      cameraScreenY: nextConfig.cameraScreenY,
      flipX: nextConfig.flipX,
      flipY: nextConfig.flipY,
      appearanceActive: Boolean(nextConfig.appearanceModelUrl)
    });
    // Inside the try: a load() rejection must surface as an error status, not
    // leave initializing=true forever with nothing reported.
    await calibration.load();
    if (epoch !== initEpoch) {
      // Replaced mid-load — let the newer init own the flag and the models.
      void modelsPromise.then((built) => disposeRuntimeModels(built, "superseded boot session"), () => undefined);
      return;
    }
    if (config.calibrate) {
      projector.retune(null, 1, 0.25);
      appliedGeometryKey = null;
    } else {
      syncProjectorGeometry();
    }
    const built = await modelsPromise;
    if (stopped || built === null || epoch !== initEpoch) {
      if (epoch === initEpoch) {
        initializing = false;
      }
      // Stopped mid-build (or the fallback ladder saw the stop first, or a
      // newer init claimed the slot) — never install a dead session's
      // successor; a superseded build would orphan once init2 disposes the
      // set it captured.
      await disposeRuntimeModels(built, "superseded boot session");
      return;
    }
    models = built;
    emitModelsLoaded(headFaceWidthRatio, "Models loaded");
    await warmupRuntimeModels(models);
    initializing = false;
    // The pump holds every frame post until this lands — no more
    // dead-frame ack churn across the boot window.
    post({ type: "ready" });
  } catch (error) {
    if (epoch === initEpoch) {
      initializing = false;
    }
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
}

// The init-time session build, factored so initialize() can launch it before
// the camera answers — the creates don't need capture dims. Resolves null
// when a mid-build stop cut the fallback ladder short; the caller then knows
// not to install the set.
async function buildModelSet(
  nextConfig: WebInferenceConfig,
  previousModels: RuntimeModels | null
): Promise<RuntimeModels | null> {
  // A re-init must free the previous sessions before creating new ones —
  // racing the old heap's async free is how a reload re-faults on the same
  // OOM. The dispose is timeout-wrapped: a wedged release must not stall
  // init forever.
  await disposeRuntimeModels(previousModels, "previous session set");
  // webgpu is opt-in only: "auto" resolves to wasm — the WebGPU EP wedges
  // silently in InferenceSession.run() on Electron 42/macOS.
  const preferredAccelerator: WebAccelerator = nextConfig.webAccelerator === "webgpu" ? "webgpu" : "wasm";
  try {
    return await withTimeout(createRuntimeModels(nextConfig, preferredAccelerator), MODEL_CREATE_TIMEOUT_MS, "model create");
  } catch (error) {
    if (preferredAccelerator === "wasm") {
      throw error;
    }
    const payload: BackendMessage = {
      type: "status",
      level: "warning",
      message: `WebGPU model load failed in inference worker: ${error}; falling back to wasm`,
      runtime: nextConfig.runtime,
      accelerator: "webgpu",
      logged: true
    };
    logStatus(payload, error);
    emit(payload);
    // ~1s heap settle, same as a recovery rung: the failed webgpu create
    // may still be tearing down asynchronously, and a same-beat wasm
    // create can inherit the debris.
    await new Promise<void>((resolve) => globalThis.setTimeout(resolve, 1000));
    if (stopped) {
      return null;
    }
    const fallbackModels = await withTimeout(createRuntimeModels(nextConfig, "wasm"), MODEL_CREATE_TIMEOUT_MS, "model create");
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
}

// Resolves with the DELIVERED camera dims the moment the pump's
// camera_geometry lands (it may already be stashed from an early answer),
// or null when a stop aborts the wait — a failed camera must not leave
// initialize() hanging.
function waitForCameraGeometry(): Promise<{ width: number; height: number; resolutionName?: string } | null> {
  // A stop that landed BEFORE this wait has no parked waiter to resolve —
  // resolve null here or initialize() hangs on a message that never comes.
  if (stopped) {
    return Promise.resolve(null);
  }
  if (deliveredCameraGeometry !== null) {
    const geometry = deliveredCameraGeometry;
    deliveredCameraGeometry = null;
    return Promise.resolve(geometry);
  }
  return new Promise((resolve) => {
    cameraGeometryWaiter = resolve;
  });
}

function emitModelsLoaded(headFaceWidthRatio: number, message: string): void {
  if (!config || !models) {
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
      paused ||
      fallbackInProgress ||
      config === null ||
      models === null ||
      calibration === null ||
      projector === null
    ) {
      // The transferred bitmap would never reach decodeFrame's close() —
      // release it here or every early-returned frame leaks GPU memory.
      message.bitmap?.close();
      return;
    }
    const frame = decodeFrame(message);
    const headFaceWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1;
    const previewWidthRatio = config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : null;
    const previewInterval = 1000 / Math.max(0.5, config.previewFps);
    const detectStart = performance.now();
    // Away mode: with no face tracked, re-detection is a search loop — 4Hz
    // while it's recent, 1Hz once the user's been gone a while. Running the
    // detector every frame (the old forceRedetect behaviour) burned ~200ms/s
    // of CPU for nothing.
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
      // Detection isn't due yet (throttled search) and nothing is tracked —
      // the no-face path below reports it honestly. Dereferencing
      // lastDetection here was a per-frame TypeError while searching.
      head = null;
      eyes = [];
      mouth = null;
      trackingSource = "iris";
    }
    const now = performance.now();
    const processedIntervalMs = lastProcessed > 0 ? now - lastProcessed : message.frameIntervalMs;
    lastProcessed = now;
    const shouldEmitPreview = previewEnabled && now - lastPreview >= previewInterval;
    let previewMs = 0;
    if (head === null || eyes.length < 2) {
      lastDetection = null;
      forceRedetect = true;
      if (noFaceSince === 0) {
        noFaceSince = now;
      }
      if (shouldEmitPreview) {
        const previewMessage = head === null ? "Head not detected" : `Eyes detected: ${eyes.length}`;
        previewMs = await emitWorkerPreview(frame, head, eyes, mouth, previewMessage, null, previewWidthRatio);
        lastPreview = now;
      }
      emitHold("no_face");
      emitNoFaceStatus(now, head === null ? "Head was not detected" : "Two eyes were not detected");
      return;
    }
    lastDetection = { head, eyes, mouth, nose, mouthCenter };
    noFaceSince = 0;
    // Appearance ensemble signal: ~5Hz, non-blocking — the call resolves on
    // ORT's wasm threads while the frame loop keeps running.
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
      // recoverable — re-throw so handleFrameError runs the rebuild
      // ladder. Swallowing it here wedged the tracker into permanent
      // held frames with zero recovery attempts.
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
    const gaze = angleSmoother.update(gazeEstimate, message.capturedAt);
    // Metric head pose from the mesh subset — degrees vs the session
    // straight-ahead. null on a degenerate fit: the proxy fallback below
    // keeps the feature channels fed. It deliberately does NOT feed the
    // tilt gate — eye yaw is not head yaw, and substituting it would
    // gate exactly the far-corner fixations calibration needs.
    const headPose = gaze.headPosePoints ? poseBaseline.update(gaze.headPosePoints) : null;
    const gazeEnd = performance.now();
    const gazeInferenceMs = gazeEnd - gazeStart;
    const reanchored = reanchorDetection(head, eyes, gaze.leftIrisCenterPx, gaze.rightIrisCenterPx, frame.width, frame.height);
    if (reanchored !== null) {
      lastDetection = {
        head: reanchored.head,
        eyes: reanchored.eyes,
        mouth:
          mouth === null
            ? null
            : { ...mouth, x1: mouth.x1 + reanchored.dx, y1: mouth.y1 + reanchored.dy, x2: mouth.x2 + reanchored.dx, y2: mouth.y2 + reanchored.dy },
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
    // Clamp to the same [0.05, 3.0] band featureDistanceM enforces on the fit
    // side — an unclamped head estimate projects live gaze in a range the
    // calibration never saw. A NaN box would poison the EMA forever; hold
    // the smoothed value instead.
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
        // Coast along the pre-hold velocity for ~400ms — a blink mid-glance
        // shouldn't park the dot where the eye was before closing.
        const coasted = coastPosition(smoothed, smoothedVel, now - holdStartMs);
        emit({
          type: "gaze",
          x_norm: coasted[0],
          y_norm: coasted[1],
          captured_at_ms: Date.now(),
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
        // Frozen with nothing emitted yet still counts as a drop — otherwise
        // the streak never starts and a pipeline that never produces a first
        // frame looks alive forever.
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
    const rollRaw = Math.atan2(rightEyeCy - leftEyeCy, rightEyeCx - leftEyeCx);
    smoothedHeadRoll = smoothedHeadRoll === null ? rollRaw : smoothedHeadRoll + 0.25 * (rollRaw - smoothedHeadRoll);
    // The metric pose roll gets the same 0.25 EMA before it de-rotates the
    // gaze angles — a mesh fit that jitters roll pivots the whole feature
    // vector, and every feature dim downstream of it.
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
      // open mouth re-zeros the jaw channels mid-sentence. Only a settled jaw
      // (raw within ~0.05 of baseline) or a confirmed-closed mouth may pull
      // the baseline (~0.04/frame — tracks rest drift over ~2s).
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
      // The vectorizer normalizes px terms by the frame they came from — tag
      // it so a VGA-fallback session stays commensurate with 720p.
      frameWidth: frame.width,
      frameHeight: frame.height,
      leftIrisOffset: irisInBox(gaze.leftIrisCenterPx, eyes[0]),
      rightIrisOffset: irisInBox(gaze.rightIrisCenterPx, eyes[1]),
      // True head roll moves slowly; the smoothed metric pose supplies it
      // when the mesh fit ran, otherwise the smoothed eye-box line stays the
      // fallback (its ~±3px jitter would otherwise inject ±2° of noise).
      headRollRad: poseRollRad ?? smoothedHeadRoll ?? 0,
      // Metric head pose (degrees) from the Kabsch mesh fit when available;
      // the nose/mouth-anchored proxies remain the fallback so a degenerate
      // mesh can't starve the pose channels the regression reads.
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
      // Jaw-motion channels — deltas from the running rest baseline, so the
      // map sees jaw CHANGE (speech) rather than absolute mouth pose.
      jawX: jawDeltaX,
      jawY: jawDeltaY,
      // Head-frame eye-midpoint: distance- and translation-invariant position.
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
      // position — always finite so live features pass isUsableSample under
      // the 48-dim vector; a stale/absent appearance channel emits 0s.
      appYawHeadFrameX: (app?.yawDeg ?? 0) * (headFrameX ?? 0),
      appYawHeadFrameY: (app?.yawDeg ?? 0) * (headFrameY ?? 0),
      appPitchHeadFrameX: (app?.pitchDeg ?? 0) * (headFrameX ?? 0),
      appPitchHeadFrameY: (app?.pitchDeg ?? 0) * (headFrameY ?? 0),
      appConfHeadFrameRadius: (app?.confidence ?? 0) * Math.hypot(headFrameX ?? 0, headFrameY ?? 0)
    };
    recentFeatures.push({ feature, at: sampleAt });
    while (recentFeatures.length > 0 && sampleAt - recentFeatures[0].at > 900) recentFeatures.shift();
    // Pursuit calibration: pair the frame's feature with the target position
    // at the camera's capture instant — the eye in this mesh looked at the
    // dot ~120ms before the latest target update, not at it. Frames with the
    // eyelid mid-closure produce garbage iris/angle features — skip them.
    // Quality gates: a depth-collapsed mesh or a disagreeing pair of eyes
    // labels a systematically-wrong feature — letting it into the pool
    // teaches the map the corruption.
    const pursuitHealthy = gaze.depthHealthy !== false && gaze.agreement >= 0.4;
    if (pursuitActive && pursuitHealthy && eyeOpen >= 0.55 && sampleAt - pursuitLastMsgAt < 250) {
      const labelAt = message.capturedAt - PURSUIT_LABEL_LAG_MS;
      const label = pursuitLabelAt(labelAt);
      // Skip the settle window — frames inside the first ~280ms of a parked
      // waypoint still show the landing saccade, not the target.
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
    // Track filtered velocity for hold-coasting; cap at a fast saccade so a
    // stale velocity can't extrapolate the marker off-screen.
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
    // Both depth channels collapsed → angles ride a reconstructed radius;
    // half-confidence keeps them emitted but lets downstream floors gate.
    if (gaze.depthHealthy === false) {
      confidence *= 0.5;
    }
    const payload: BackendMessage = {
      type: "gaze",
      x_norm: clamp01(smoothed[0]),
      y_norm: clamp01(smoothed[1]),
      raw_x_norm: latestRaw[0],
      raw_y_norm: latestRaw[1],
      captured_at_ms: message.capturedAtMs ?? Date.now(),
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
        filterMode === "saccade" ? (saccadeFilter.inSaccade ? "saccade" : saccadeFilter.dwellLocked ? "dwell" : "fixation") : undefined,
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
    post({ type: "frame_done" });
  }
}

async function handleFrameError(error: unknown): Promise<void> {
  if (!config || !models || inferenceUnrecoverable) {
    return;
  }
  const now = performance.now();
  if (!fallbackInProgress && isRecoverableInferenceError(error)) {
    fallbackInProgress = true;
    try {
      const preferWebgpu = config.webAccelerator === "webgpu";
      const onWebgpu = models.accelerator === "webgpu";
      if (onWebgpu) {
        const payload: BackendMessage = {
          type: "status",
          level: "warning",
          message: preferWebgpu
            ? `WebGPU inference failed in worker: ${error instanceof Error ? error.message : String(error)}; rebuilding webgpu sessions`
            : `WebGPU inference failed in worker: ${error instanceof Error ? error.message : String(error)}; falling back to wasm`,
          runtime: config.runtime,
          accelerator: "webgpu",
          logged: true
        };
        logStatus(payload, error);
        emit(payload);
      }
      // WebGPU-first recovery: a transient device loss gets the fast path
      // retried on its own short ladder before any demotion; an explicit
      // `--accelerator wasm` override skips the webgpu rungs entirely.
      // When the current set is already wasm we still try webgpu first — the
      // wasm death may itself be heap fallout that webgpu sidesteps.
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

// Rebuild the inference sessions in place after a session died. Target-
// parametrized: webgpu rungs use the short ladder (transient device loss),
// wasm keeps the long backoff (heap must actually free between attempts).
// Each attempt disposes the corpse with a timeout, waits out the backoff,
// then has to survive a real probe run — create succeeding while run faults
// counts as a failed attempt. After the last wasm failure the runtime
// latches terminal: models stays null (frames skip inference) and the error
// is emitted once. Webgpu exhaustion is NOT terminal — the caller falls
// through to the wasm ladder.
//
// opts.promote (used by the re-promotion timer): build the candidate WITHOUT
// tearing down the live wasm set — frames keep running on it through the
// ~1-3s rebuild, and a failed attempt leaves wasm untouched. The swap is
// committed only after the candidate passes its probe; the displaced set is
// disposed on a short delay so any in-flight run finishes first.
// opts.quiet: attempt/failure statuses are log-only — a probe that fails
// quietly must not feed the host's wedge signature a false alarm. A
// successful reload still emits "Models reloaded with …" either way.
async function recoverSessions(
  target: WebAccelerator,
  cause: unknown,
  opts: { promote?: boolean; quiet?: boolean } = {}
): Promise<boolean> {
  if (!config) {
    return false;
  }
  const epoch = initEpoch;
  const quiet = opts.quiet === true;
  const promote = opts.promote === true;
  // In promote mode the current (wasm) set keeps serving frames until a
  // webgpu candidate proves out — capture it so the commit can verify nobody
  // else swapped models mid-build.
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
    // In quiet mode the attempt is log-only — probing is invisible.
    if (!quiet) {
      emit(attemptPayload);
    }
    if (delayMs > 0) {
      await new Promise<void>((resolve) => globalThis.setTimeout(resolve, delayMs));
    }
    if (stopped || epoch !== initEpoch) {
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
      if (stopped || epoch !== initEpoch) {
        // A stop/re-init landed mid-rebuild — don't stomp its sessions.
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
      emitModelsLoaded(config.detector === "retinaface" ? config.retinafaceHeadFaceRatio : 1, `Models reloaded with ${target}`);
      if (target === "webgpu") {
        // The fast path is live again — a later demotion earns a fresh
        // re-promotion budget.
        repromotionAttempts = 0;
      }
      if (promote && preserved !== null) {
        // Dispose the old wasm set once in-flight runs drain — a release
        // racing a live OrtRun would fault the very frame it interrupts.
        const stale = preserved;
        void new Promise<void>((resolve) => globalThis.setTimeout(resolve, SWAPPED_SET_DISPOSE_DELAY_MS)).then(() =>
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
    // not see a wedge signature for what is a routine declined probe.
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
    // Fast-path rungs exhausted — not terminal, the wasm ladder runs next.
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
}

// wasm is the last resort, never a permanent silent downgrade: whenever the
// tracker lands on wasm while the config allows webgpu, schedule a quiet
// re-promotion — +60s first (the device-loss transient needs room to
// settle), then every ~5min, max ~4 attempts per demotion episode.
function scheduleWebgpuRepromotion(): void {
  if (!config || config.webAccelerator !== "webgpu" || stopped) {
    return;
  }
  if (repromotionTimer !== null || repromotionInFlight || repromotionAttempts >= WEBGPU_REPROMOTION_MAX_ATTEMPTS) {
    return;
  }
  repromotionTimer = globalThis.setTimeout(() => {
    repromotionTimer = null;
    void attemptWebgpuRepromotion();
  }, repromotionAttempts === 0 ? WEBGPU_REPROMOTION_FIRST_DELAY_MS : WEBGPU_REPROMOTION_CADENCE_MS);
}

async function attemptWebgpuRepromotion(): Promise<void> {
  if (!config || stopped || fallbackInProgress || repromotionInFlight || models === null || models.accelerator !== "wasm") {
    return;
  }
  if (repromotionAttempts >= WEBGPU_REPROMOTION_MAX_ATTEMPTS) {
    return;
  }
  repromotionAttempts += 1;
  repromotionInFlight = true;
  const epoch = initEpoch;
  let promoted = false;
  try {
    // promote+quiet: the live wasm set keeps serving frames through the
    // rebuild, a declined probe stays invisible to the host.
    promoted = await recoverSessions("webgpu", "scheduled webgpu re-promotion", { promote: true, quiet: true });
  } finally {
    // Cleared BEFORE rescheduling — scheduleWebgpuRepromotion refuses to arm
    // while a promotion is in flight, so doing this in the finally after the
    // schedule call would swallow every cadence retry.
    repromotionInFlight = false;
  }
  if (promoted || stopped || epoch !== initEpoch) {
    return;
  }
  scheduleWebgpuRepromotion();
}

// A dispose that can never hang the recovery path: on the wedged-release ORT
// bug the promise never settles, so after 5s we drop the reference and move
// on — the ladder's own backoff absorbs whatever heap free was still pending.
async function disposeRuntimeModels(target: RuntimeModels | null, context: string): Promise<void> {
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
        runtime: config?.runtime,
        accelerator: target.accelerator
      },
      disposeError
    );
  }
}

// Iris position inside its detected eye box, normalized to half-extents so a
// value of ±1 means the iris touched the box edge. Falls back to [0,0] when
// the mesh didn't localize the iris — the feature map treats it as neutral.
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

// COMETIC-style implicit label: an on-screen position the user provably
// fixated (cursor idle) is ground truth only if our estimate already roughly
// agrees — accept it when the current map lands within ~9% of screen, which
// filters "user looked elsewhere" events while keeping refinement local.
function handleImplicitSample(xNorm: number, yNorm: number): void {
  if (calibration === null || recentFeatures.length < 3) {
    return;
  }
  // No live map means nothing to refine and no honest gate — and labels must
  // never contaminate a calibration that's still being captured.
  if ((calibration.featureMap === null && calibration.matrix === null) || pursuitActive) {
    return;
  }
  const now = performance.now();
  // Gaze leads the cursor by ~200-300ms — label with the feature from then.
  const featureAt = now - 250;
  let best: TimedFeature | null = null;
  for (const entry of recentFeatures) {
    if (best === null || Math.abs(entry.at - featureAt) < Math.abs(best.at - featureAt)) {
      best = entry;
    }
  }
  if (best === null || Math.abs(best.at - featureAt) > 400) {
    return;
  }
  const target: [number, number] = [clamp01(xNorm), clamp01(yNorm)];
  const estimate = calibration.applyFeature(best.feature);
  const offset: [number, number] = [target[0] - estimate[0], target[1] - estimate[1]];
  const agreed = Math.hypot(offset[0], offset[1]) <= 0.09;
  // Sustained, directionally-consistent rejection = the camera/laptop moved.
  // The rejection vector is the translation error — apply it (damped) instead
  // of interrupting the user for a recalibration.
  const correction = driftMonitor.record(agreed, offset, now, target);
  if (correction !== null && calibration !== null) {
    const applied = calibration.applyDriftCorrection(correction[0] * 0.85, correction[1] * 0.85);
    // Escalate well before the 0.35 hard bound: 0.15 cumulative means ~8
    // separate sustained confirmations — a real reposition the user should
    // heal with one recalibration rather than minutes of nudges.
    const saturated = Math.hypot(applied[0], applied[1]) >= 0.15;
    console.info("Drift auto-corrected", JSON.stringify({ applied, saturated }));
    if (saturated) {
      post({
        type: "backend",
        payload: { type: "status", level: "warning", message: "drift_detected" }
      });
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
    return;
  }
  calibration.addImplicitSample(best.feature, target);
  void calibration.refitWithImplicit(now);
}

// A lost calibration_read/write response (terminated bridge, dropped relay)
// must not wedge load()/save() — fail the pending request after ~5s.
const CALIBRATION_IO_TIMEOUT_MS = 5000;

function requestCalibrationRead(path: string): Promise<{ ok: true; text: string | null } | { ok: false; error: string }> {
  const id = requestId + 1;
  requestId = id;
  post({ type: "calibration_read", id, path });
  return new Promise((resolve) => {
    pendingReads.set(id, resolve);
    globalThis.setTimeout(() => {
      if (pendingReads.delete(id)) {
        resolve({ ok: false, error: "calibration_read timed out" });
      }
    }, CALIBRATION_IO_TIMEOUT_MS);
  });
}

function requestCalibrationWrite(path: string, payload: unknown): Promise<{ ok: true; path: string } | { ok: false; error: string }> {
  const id = requestId + 1;
  requestId = id;
  post({ type: "calibration_write", id, path, payload });
  return new Promise((resolve) => {
    pendingWrites.set(id, resolve);
    globalThis.setTimeout(() => {
      if (pendingWrites.delete(id)) {
        resolve({ ok: false, error: "calibration_write timed out" });
      }
    }, CALIBRATION_IO_TIMEOUT_MS);
  });
}

// Pending requests hold only their resolve — resolve with an error result so
// the awaiting load()/save() unwinds instead of hanging forever.
function settlePendingCalibrationRequests(error: string): void {
  for (const resolve of pendingReads.values()) {
    resolve({ ok: false, error });
  }
  pendingReads.clear();
  for (const resolve of pendingWrites.values()) {
    resolve({ ok: false, error });
  }
  pendingWrites.clear();
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

