const { app, BrowserWindow, globalShortcut, ipcMain, Menu, nativeImage, screen, systemPreferences, Tray } = require("electron");
const fs = require("fs");
const path = require("path");
const { mouse, Button, Point } = require("@nut-tree-fork/nut-js");
const { startExternalApiServer } = require("./externalApi.cjs");
const { GazeStateStore, mergeSettings, parseSettingsPayload } = require("./externalStore.cjs");
const { createLipClickController } = require("./lipClickController.cjs");
const { startHostWatchdog } = require("./hostWatchdog.cjs");
const { copyIfStale } = require("./assetCopy.cjs");

const repoRoot = path.resolve(__dirname, "..");
const defaultCalibrationFile = path.join(repoRoot, ".gaze_calibration.json");
// 18x18 alpha-only dot — macOS recolors template images for the menu bar.
const TRAY_ICON_DATA_URL =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAAAaElEQVR42sXU2wnAIAyFYcfoMNkv22Qb5/lLIU+ircppeyAvoh94iQUoiipfQAY4EFmeY9PQkQtHiZxzC10TKs+pLdZCwXxiBBnrsR7kG5D3oNiA4lVItjXZYcuuX/ogZS0ibdp//6MTUndVBX1rzEYAAAAASUVORK5CYII=";
const ortWasmDir = path.dirname(require.resolve("onnxruntime-web/wasm"));
let mainWindow = null;
let selectedDisplay = null;
let rendererConfig = null;
let rendererReady = false;
// Set by the renderer's modal-interactive IPC — while a calibration/accuracy
// modal owns the screen the overlay must keep mouse+keyboard focus, and both
// the region updater and the cursor-idle sampler must stand down.
let modalInteractive = false;
// Renderer-driven pause (set-paused IPC / report-state): gates the
// cursor-idle sampler and the lip-click path exactly like modalInteractive.
let paused = false;
let debugOverlay = false;
let shapeOverlay = false;
// Set by the child-process-gone handler when the GPU child dies — pure
// telemetry for WebGPU device-loss diagnosis; the inference layer owns any
// reaction, nothing here branches on it.
let gpuProcessDied = false;
let externalApi = null;
let lipClickController = null;
let tray = null;
// Re-evaluates trayStateLabel on the preview-stale cadence — a wedged
// renderer stops sending messages entirely, and without a poll the menu
// would freeze at the last label ("Tracking") forever. The refresh is a
// no-op unless the computed word changed.
let trayLabelPoll = null;
let lastTrayLabel = "";
let settingsFilePath = null;
let cachedSettings = {};
// Serializes read-modify-write on settings.json so a tray click and a
// renderer set-settings can't interleave into a lost update.
let settingsWriteQueue = Promise.resolve();
const pendingMessages = [];
// Bounded so a dead-not-yet-reloaded renderer can't let the queue grow
// forever (control API / tray traffic keeps posting) and can't replay a
// storm of stale intents on reconnect — oldest drops first.
const MAX_PENDING_MESSAGES = 256;
const gazeStateStore = new GazeStateStore({
  readCalibrationFile: (filePath) => {
    try {
      return fs.readFileSync(filePath, "utf8");
    } catch (error) {
      if (error && error.code === "ENOENT") {
        return null;
      }
      throw error;
    }
  },
  // Cheap freshness probe for the store's calibration-payload cache —
  // "calibration" backend messages arrive at ~2Hz through a capture while
  // the file itself only changes on commitPending, so the store stats
  // first and re-parses only when (path, mtime, size) moved.
  statCalibrationFile: (filePath) => {
    try {
      const stat = fs.statSync(filePath);
      return { mtimeMs: stat.mtimeMs, size: stat.size };
    } catch {
      return null;
    }
  }
});

function appendGpuSwitches() {
  app.commandLine.appendSwitch("ignore-gpu-blocklist");
  app.commandLine.appendSwitch("enable-zero-copy");
  // Retained deliberately: sandbox-related WebGPU device loss is a
  // documented failure mode on macOS, and this window only ever loads
  // bundled local content — the sandbox buys nothing here.
  app.commandLine.appendSwitch("disable-gpu-sandbox");
  app.commandLine.appendSwitch("enable-unsafe-webgpu");
  const features =
    process.platform === "linux"
      ? "Vulkan,WebGPU,WebGPUService"
      : process.platform === "darwin"
        ? "Metal,WebGPU,WebGPUService"
        : "WebGPU,WebGPUService";
  app.commandLine.appendSwitch("enable-features", features);
  // Pin Dawn to Metal — on Apple Silicon "default" resolves there anyway,
  // and naming it removes the compat-adapter ambiguity when ORT requests
  // the WebGPU device. (enable-webgpu-developer-features was removed: it
  // exposed an experimental surface ORT does not use.)
  app.commandLine.appendSwitch("use-webgpu-adapter", process.platform === "darwin" ? "metal" : "default");
  app.commandLine.appendSwitch("disable-features", "UseSkiaRenderer,UseChromeOSDirectVideoDecoder");
  // The prod path loads dist/ over file:// — onnxruntime-web fetches the
  // bundled models by relative URL, which Chromium denies for file pages
  // unless this switch is set (file→file only; http stays isolated).
  app.commandLine.appendSwitch("allow-file-access-from-files");
}

// One tracker per app identity: the control API binds a fixed port and the
// camera is exclusive, so a second launch can neither serve the host nor
// see — it must yield to the running instance. A port-bind failure would
// otherwise leave a camera-hogging zombie the host can't reach. This runs
// before any window/API/watchdog setup, so exiting here leaves nothing to
// clean up; app.quit() alone wouldn't stop the registration code below.
if (!app.requestSingleInstanceLock()) {
  console.log("another tracker instance already holds the lock — quitting");
  app.quit();
  process.exit(0);
}
app.on("second-instance", () => {
  // The duplicate already exited — nothing to focus, the overlay stays put.
});

appendGpuSwitches();

// The default uncaught-exception handler is a native JS-error modal — on a
// transparent, click-through, focusable:false overlay that dialog is
// invisible and unkillable, leaving a half-dead tracker running forever.
// Log loudly and exit so the host (or dev wrapper) sees a real failure.
process.on("uncaughtException", (error) => {
  console.error(`Uncaught exception in main process: ${error instanceof Error ? error.stack || error.message : error}`);
  app.exit(1);
});

function cliArgs() {
  const args = process.argv.slice(2);
  return args.filter((arg) => arg !== ".");
}

function readOption(args, name, fallback) {
  const index = args.indexOf(name);
  if (index >= 0) {
    const next = args[index + 1];
    // "--camera --calibrate" — the next token is another flag, not a value;
    // consuming it would silently disable --calibrate.
    if (next === undefined || next.startsWith("--")) {
      console.warn(`${name} was passed without a value; using default`);
      return fallback;
    }
    return next;
  }
  const prefix = `${name}=`;
  const match = args.find((arg) => arg.startsWith(prefix));
  return match ? match.slice(prefix.length) : fallback;
}

function hasFlag(args, name) {
  return args.includes(name);
}

// "--no-tray" is the hosted-mode marker: Jarvis launches the tracker as
// `node scripts/dev.cjs --external-api --no-tray`, and the host's menu-bar
// item owns every control (pause/recalibrate route through POST /control).
// Detection keys on the flag, never on JARVIS_* env vars — a shell can leak
// those into a standalone run.
function isHostedMode() {
  return hasFlag(cliArgs(), "--no-tray");
}

function readNumberOption(args, name, fallback) {
  const value = Number.parseFloat(readOption(args, name, String(fallback)));
  return Number.isFinite(value) ? value : fallback;
}

function readPositiveNumberOption(args, name, fallback) {
  const value = readNumberOption(args, name, fallback);
  return value > 0 ? value : fallback;
}

function readPortOption(args, name, fallback) {
  const value = Number.parseInt(readOption(args, name, String(fallback)), 10);
  return value > 0 && value <= 65535 ? value : fallback;
}

function readCameraFovOption(args) {
  const value = readNumberOption(args, "--camera-fov", 90);
  return value > 0 && value < 180 ? value : 90;
}

// rendererConfig and webInference both expose the camera's screen position —
// one clamped read so the same flag can't arrive as two different values.
function readCameraScreenOption(args, name, fallback) {
  const value = Number.parseFloat(readOption(args, name, String(fallback)));
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : fallback;
}

// 720p default: roughly double the iris pixels of VGA, which the accuracy
// work needs. Not an "exact" demand — with no flag the renderer may retry
// at VGA when the sensor can't deliver; a flag means "exactly this".
const defaultCameraResolution = { name: "HD", width: 1280, height: 720 };
const rejectedCameraResolutionNames = new Set(["2mp", "4mp", "8mp"]);
const cameraResolutionPresets = new Map();
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
]) {
  const resolution = { name, width, height };
  for (const alias of aliases) {
    cameraResolutionPresets.set(normalizeCameraResolutionName(alias), resolution);
  }
}

function normalizeCameraResolutionName(value) {
  return Array.from(value.toLowerCase()).filter((ch) => /[a-z0-9]/.test(ch)).join("");
}

function parseCameraResolution(value) {
  const raw = String(value).trim();
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
  if (rejectedCameraResolutionNames.has(normalized)) {
    throw new Error(`camera resolution alias is not accepted; use WIDTHxHEIGHT instead: ${value}`);
  }
  const preset = cameraResolutionPresets.get(normalized);
  if (!preset) {
    throw new Error(`unknown camera resolution: ${value}`);
  }
  return preset;
}

// {resolution, explicit} — the flag's absence vs presence changes failure
// policy downstream: an unnamed (default) request may fall back to VGA when
// the sensor won't deliver 720p; an explicit request stays exact-or-fail.
function readCameraResolutionOption(args) {
  const requested = readOption(args, "--camera-resolution", null);
  if (requested === null) {
    return { resolution: defaultCameraResolution, explicit: false };
  }
  return { resolution: parseCameraResolution(requested), explicit: true };
}

// Canonical runtime: onnxweb in the dedicated inference worker. The Python
// backend and LiteRT path were removed — they were three divergent pipelines
// pretending to be one tracker.
function resolveRuntime(args) {
  const requested = readOption(args, "--runtime", "onnxweb");
  if (requested !== "onnxweb") {
    console.warn(`--runtime ${requested} is no longer supported; using onnxweb`);
  }
  return "onnxweb";
}

function readWebInferenceWorkerMode(args) {
  const mode = readOption(args, "--web-inference-worker", "dedicated");
  return ["off", "ort-proxy", "dedicated"].includes(mode) ? mode : "dedicated";
}

function readWebAccelerator(args) {
  const mode = readOption(args, "--web-accelerator", "auto");
  const normalized = ["auto", "webgpu", "wasm"].includes(mode) ? mode : "auto";
  // "auto" resolves to wasm: on Electron 42/macOS the WebGPU execution
  // provider wedges silently (InferenceSession.run() never returns — 0% CPU,
  // no error), so the reliable provider is the default and webgpu stays
  // reachable only via an explicit `--web-accelerator webgpu`.
  return normalized === "webgpu" ? "webgpu" : "wasm";
}

// MediaPipe Face Landmarker (Apache-2.0) is the default gaze front end. The
// five legacy ONNX weights (RetinaFace, YOLO wholebody, the 160² gaze mesh,
// VSDLM lip motion, MobileOne appearance) carry no license grant, so they
// load only for a developer A/B behind --legacy-models; --legacy-models
// alone selects the old RetinaFace pipeline.
function readDetector(args) {
  const legacyModels = hasFlag(args, "--legacy-models");
  const requested = readOption(args, "--detector", legacyModels ? "retinaface" : "mediapipe");
  if (!["mediapipe", "retinaface", "yolo"].includes(requested)) {
    console.warn(`--detector ${requested} is not supported; using mediapipe`);
    return "mediapipe";
  }
  if (requested !== "mediapipe" && !legacyModels) {
    console.warn(`--detector ${requested} needs the unlicensed legacy weights; pass --legacy-models to opt in. Using mediapipe.`);
    return "mediapipe";
  }
  return requested;
}

function resolveRepoPath(value) {
  const raw = value || "";
  return path.resolve(repoRoot, raw);
}

function useDevServer() {
  return Boolean(process.env.VITE_DEV_SERVER_URL) || (!app.isPackaged && process.env.NODE_ENV !== "production");
}

function rendererStaticDir() {
  return useDevServer() ? path.join(repoRoot, "public") : path.join(repoRoot, "dist");
}

function rendererModelDir() {
  return path.join(rendererStaticDir(), "models");
}

// Relative "models/x" resolves against the *worker's* script URL
// (dist/assets/), not the page's — so prod hands the worker an absolute
// file:// URL into dist/.
function rendererAssetPrefix() {
  return useDevServer() ? "/" : `${require("url").pathToFileURL(rendererStaticDir()).href}/`;
}

function copyFileForRenderer(sourcePath, relativeDir) {
  const source = path.resolve(sourcePath);
  const targetDir = path.join(rendererStaticDir(), relativeDir);
  const target = path.join(targetDir, path.basename(source));
  try {
    fs.mkdirSync(targetDir, { recursive: true });
    // Same-path short-circuit first (a file already living under the static
    // dir needs no copy at all), then the freshness check: the same bytes
    // get re-copied every launch otherwise — multi-MB models make that the
    // loudest no-op in boot.
    if (source !== target) {
      copyIfStale(source, target);
    }
  } catch (error) {
    console.error(`Failed to copy renderer asset ${source} -> ${target}: ${error.message}`);
  }
  return `${rendererAssetPrefix()}${relativeDir}/${encodeURIComponent(path.basename(source))}`;
}

function copyModelForRenderer(modelPath) {
  return copyFileForRenderer(modelPath, "models");
}

function copyRuntimeAssetsForRenderer(sourceDir, relativeDir, predicate) {
  const names = fs.readdirSync(sourceDir).filter(predicate).sort();
  for (const name of names) {
    copyFileForRenderer(path.join(sourceDir, name), relativeDir);
  }
  // Same worker-relative fix as copyFileForRenderer — ORT loads its wasm
  // assets inside the inference worker, where a relative dir resolves
  // against dist/assets/ and never resolves at all.
  return `${rendererAssetPrefix()}${relativeDir}/`;
}

function copyOnnxRuntimeAssetsForRenderer() {
  return copyRuntimeAssetsForRenderer(
    ortWasmDir,
    "runtime-assets/onnxruntime-web",
    (name) => name.startsWith("ort-wasm-simd-threaded.") && (name.endsWith(".wasm") || name.endsWith(".mjs"))
  );
}

function webInferenceConfig(args, displayBounds) {
  const detector = readDetector(args);
  const legacy = detector !== "mediapipe";
  const cameraResolution = readCameraResolutionOption(args);
  const calibrationFile = resolveRepoPath(readOption(args, "--calibration-file", defaultCalibrationFile));
  const retinafaceModel = resolveRepoPath(
    readOption(args, "--retinaface-model", "public/models/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx")
  );
  const yoloModel = resolveRepoPath(
    readOption(args, "--yolo-model", "public/models/yolomit_t_wholebody28_1x3x480x640.onnx")
  );
  const mediapipeModel = resolveRepoPath(readOption(args, "--mediapipe-model", "public/models/face_landmarker.task"));
  const defaultDetectorModel = detector === "mediapipe" ? mediapipeModel : detector === "yolo" ? yoloModel : retinafaceModel;
  const detectorModel = resolveRepoPath(readOption(args, "--detector-model", defaultDetectorModel));
  const gazeModel = legacy ? resolveRepoPath(readOption(args, "--gaze-model", "public/models/gaze_1x3x160x160.onnx")) : null;
  const lipMotionModel = legacy ? resolveRepoPath(readOption(args, "--lip-motion-model", "public/models/vsdlm_l.onnx")) : null;
  // Phase-4 ensemble signal: MobileOne-S0 gaze net (~5MB). Runs async at ~5Hz
  // alongside the mesh pipeline; the feature map fuses it with geometry.
  const appearanceModel = !legacy || hasFlag(args, "--no-appearance-model")
    ? null
    : resolveRepoPath(readOption(args, "--appearance-model", "public/models/mobileone_s0_gaze.onnx"));
  const enableLipMotion = hasFlag(args, "--enable-lip-motion") && detector === "yolo";
  return {
    runtime: "onnxweb",
    webInferenceWorker: readWebInferenceWorkerMode(args),
    webAccelerator: readWebAccelerator(args),
    calibrate: hasFlag(args, "--calibrate"),
    detector,
    camera: readOption(args, "--camera", "0"),
    // cameraResolutionName doubles as the "explicitly requested" marker for
    // the renderer: it is unset only when no flag was passed, which is what
    // licenses the default-policy VGA fallback. Explicit WIDTHxHEIGHT values
    // synthesize a name so they stay on the exact-or-fail path too.
    cameraResolutionName: cameraResolution.explicit
      ? (cameraResolution.resolution.name ?? `${cameraResolution.resolution.width}x${cameraResolution.resolution.height}`)
      : undefined,
    cameraWidth: cameraResolution.resolution.width,
    cameraHeight: cameraResolution.resolution.height,
    cameraFov: readCameraFovOption(args),
    scoreThreshold: readNumberOption(args, "--score-threshold", 0.5),
    displaySizeInch: readPositiveNumberOption(args, "--display-size-inch", 31.5),
    displayWidth: displayBounds.width,
    displayHeight: displayBounds.height,
    calibrationFile,
    detectorModel,
    lipMotionModel: lipMotionModel ?? "",
    // Only *ModelUrl fields cross the bridge — the renderer loads models by
    // URL; on-disk paths stay in main (detectorModel covers the active one).
    detectorModelUrl: copyModelForRenderer(detectorModel),
    gazeModelUrl: gazeModel ? copyModelForRenderer(gazeModel) : "",
    lipMotionModelUrl: lipMotionModel ? copyModelForRenderer(lipMotionModel) : "",
    onnxWasmBaseUrl: legacy ? copyOnnxRuntimeAssetsForRenderer() : "",
    // The vite build emits the landmarker's wasm into dist/runtime-assets/
    // mediapipe/ and the dev server serves it from node_modules (see
    // vite.config.ts), so nothing is copied at boot.
    mediapipeWasmBaseUrl: legacy ? undefined : `${rendererAssetPrefix()}runtime-assets/mediapipe/`,
    mediapipeDelegate: readOption(args, "--mediapipe-delegate", "gpu") === "cpu" ? "cpu" : "gpu",
    appearanceModelUrl: appearanceModel ? copyModelForRenderer(appearanceModel) : undefined,
    smoothingAlpha: readNumberOption(args, "--smoothing-alpha", 0.65),
    smoothingAlphaY: readNumberOption(args, "--smoothing-alpha-y", 0.45),
    gazeFilter: (() => {
      const mode = readOption(args, "--gaze-filter", "saccade");
      return ["saccade", "oneeuro", "ema"].includes(mode) ? mode : "saccade";
    })(),
    filterMincutoff: readNumberOption(args, "--filter-mincutoff", 1.0),
    filterBeta: readNumberOption(args, "--filter-beta", 0.7),
    filterDcutoff: readNumberOption(args, "--filter-dcutoff", 1.0),
    disableIrisDistance: hasFlag(args, "--no-iris-distance"),
    previewFps: readNumberOption(args, "--preview-fps", 8.0),
    gazeMaxFps: readPositiveNumberOption(args, "--gaze-max-fps", 20),
    // Threaded wasm stayed pinned to 1 because the historical OOM was the
    // release↔create heap race (fixed in the recovery rework) — the host
    // can opt into threads via --wasm-threads N; 1 remains the default.
    wasmThreads: readPositiveNumberOption(args, "--wasm-threads", 1),
    // The camera preview is a diagnostic — hidden by default so customers
    // never see their face; `--show-preview` opts back in.
    hidePreview: !hasFlag(args, "--show-preview"),
    flipX: !hasFlag(args, "--no-flip-x"),
    flipY: !hasFlag(args, "--no-flip-y"),
    cameraScreenX: readCameraScreenOption(args, "--camera-screen-x", 0.5),
    cameraScreenY: readCameraScreenOption(args, "--camera-screen-y", 0),
    eyePositionWeightX: readNumberOption(args, "--eye-position-weight-x", 1),
    eyePositionWeightY: readNumberOption(args, "--eye-position-weight-y", 0.25),
    retinafaceHeadFaceRatio: readNumberOption(args, "--retinaface-head-face-ratio", 1.545),
    gazeProjectionMode: readOption(args, "--gaze-projection-mode", "legacy"),
    enableLipMotion
  };
}

function maybeStartExternalApi(args) {
  if (!hasFlag(args, "--external-api")) {
    return;
  }
  const host = readOption(args, "--external-api-host", "127.0.0.1");
  const port = readPortOption(args, "--external-api-port", 47892);
  externalApi = startExternalApiServer({
    store: gazeStateStore,
    host,
    port,
    logger: console,
    onControl: handleControlAction,
    // POST /control quit — the host's polite shutdown path. Routes through
    // app.quit() so before-quit teardown (API close, lip-click release)
    // still runs instead of a bare SIGKILL.
    onQuit: () => app.quit()
  });
}

function stopExternalApi() {
  if (!externalApi) {
    return;
  }
  externalApi.close();
  externalApi = null;
}

function sendToRenderer(payload, options = {}) {
  const updateStore = options.updateStore !== false;
  if (updateStore) {
    gazeStateStore.updateFromBackendMessage(payload);
    handleLipMotionMessage(payload);
    refreshTrayStateLabel();
  }
  if (payload && payload.type === "status" && (payload.level === "warning" || payload.level === "error")) {
    const log = payload.level === "error" ? console.error : console.warn;
    log(`[renderer-status:${payload.level}] ${payload.message}`);
  }
  sendToRendererChannel("backend-message", payload);
}

// Channel-agnostic send with the same ready/queue semantics — control
// messages like "recalibrate" must not bypass the queue mid-reload.
function sendToRendererChannel(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed() && rendererReady) {
    try {
      if (payload === undefined) {
        mainWindow.webContents.send(channel);
      } else {
        mainWindow.webContents.send(channel, payload);
      }
      return;
    } catch {
      // Frame disposed mid-reload — queue and let the renderer reattach.
    }
  }
  if (pendingMessages.length >= MAX_PENDING_MESSAGES) {
    pendingMessages.shift();
  }
  pendingMessages.push({ channel, payload });
}

// Menu-style control dispatch — POST /control, ⌘⇧P, and the tray menu all
// land here; the renderer turns the action into a UI state change and
// reports it back through set-paused / report-state / set-settings.
function dispatchMenuAction(action, value) {
  const payload = { type: "menu_action", action };
  if (value !== undefined) {
    payload.value = value;
  }
  sendToRendererChannel("backend-message", payload);
}

// The single recalibration path — ⌘⇧G, the tray menu, and POST /control
// share the status echo and the lip-click re-arm.
function requestRecalibration(source) {
  sendToRenderer({ type: "status", level: "info", message: `recalibration requested (${source})` });
  // Re-arm the lip-click shield now — a mouth-click in the gap before
  // the renderer opens the modal would drive the real OS cursor.
  lipClickController?.setCalibrationActive(true);
  sendToRendererChannel("recalibrate");
  // If the renderer ignored the request (a modal is already up, or it is
  // dead), modal-interactive never arrives — re-evaluate the shield so
  // mouth-clicks are not swallowed forever.
  setTimeout(() => {
    lipClickController?.setCalibrationActive(paused || modalInteractive);
  }, 4000);
}

function handleControlAction(action, value) {
  if (action === "recalibrate") {
    requestRecalibration("control api");
    return;
  }
  if (action === "accuracy_check") {
    // Same lip-click shield as a recalibration: the check opens with one.
    lipClickController?.setCalibrationActive(true);
    dispatchMenuAction("accuracy_check");
    return;
  }
  // set_paused carries the target state (the host's screen-lock parking),
  // not a toggle — the renderer applies it through the same path a manual
  // pause uses and reports it back through set-paused / report-state.
  if (action === "set_paused") {
    dispatchMenuAction("set_paused", Boolean(value));
    return;
  }
  // Quit is a lifecycle action, not a renderer menu action — handle it here
  // whether the API layer routes it through onControl or a dedicated hook.
  if (action === "quit") {
    app.quit();
    return;
  }
  if (action === "implicit_sample") {
    // The host's commit-time implicit label — forwarded as the same
    // cursor_idle message the idle sampler emits, so the renderer feeds it
    // through the inference worker's COMETIC quality gate unchanged.
    // externalApi already range-validates the point; the second check keeps
    // this entry honest if another caller ever bypasses the HTTP layer.
    if (!value || !Number.isFinite(value.x_norm) || !Number.isFinite(value.y_norm) ||
        value.x_norm < 0 || value.x_norm > 1 || value.y_norm < 0 || value.y_norm > 1) {
      return { status: 400, error: "invalid_value" };
    }
    // Decline (409) under the same conditions the sampler stands down — no
    // live renderer, a modal owning the screen, a paused tracker, or models
    // that never reported loaded. A label queued behind any of those would
    // land on stale features or corrupt an in-flight accuracy measurement.
    const snapshot = gazeStateStore.getSnapshot();
    const inferenceUp = Boolean(snapshot.runtime?.name && snapshot.models?.detector && snapshot.models?.gaze);
    if (!mainWindow || mainWindow.isDestroyed() || !rendererReady || modalInteractive || paused || !inferenceUp) {
      return { status: 409, error: "tracking_inactive" };
    }
    sendToRenderer({ type: "cursor_idle", x_norm: value.x_norm, y_norm: value.y_norm }, { updateStore: false });
    return;
  }
  dispatchMenuAction(action, value);
}

function applyPausedFlag(value) {
  const next = Boolean(value);
  if (next === paused) {
    return;
  }
  paused = next;
  // Same stand-down as modal mode — a paused tracker must not land
  // mouth-clicks on whatever happens to sit under the gaze point.
  lipClickController?.setCalibrationActive(paused || modalInteractive);
}

function readSettingsFileSync() {
  if (!settingsFilePath) {
    return {};
  }
  try {
    return parseSettingsPayload(fs.readFileSync(settingsFilePath, "utf8"));
  } catch {
    return {};
  }
}

async function readSettingsFile() {
  if (!settingsFilePath) {
    return {};
  }
  try {
    return parseSettingsPayload(await fs.promises.readFile(settingsFilePath, "utf8"));
  } catch {
    return {};
  }
}

function persistSettingsPatch(patch) {
  settingsWriteQueue = settingsWriteQueue
    .catch(() => {})
    .then(async () => {
      const merged = mergeSettings(await readSettingsFile(), patch);
      if (merged.version === undefined) {
        merged.version = 1;
      }
      await writeJsonFileAtomic(settingsFilePath, merged);
      cachedSettings = merged;
      gazeStateStore.updateSharedState({ settings: merged });
      rebuildTrayMenu();
    })
    .catch((error) => {
      console.error(`Failed to persist settings: ${error instanceof Error ? error.message : error}`);
    });
  return settingsWriteQueue;
}

// Freshness bounds for the label — mirrors TrackerControl.swift: a stale
// preview stamp means the feed froze, and a gaze stamp older than the
// host's stale window counts as dead air.
const PREVIEW_STALE_MS = 3000;
const GAZE_STALE_MS = 1500;
// First-frame allowance — mirrors the host's 45s gazeGraceWindow: cold
// shader compiles stay "Starting" inside it, a never-producing pipeline
// past it is "No gaze", never "Tracking".
const BOOT_GRACE_MS = 45000;

function trayStateLabel() {
  if (paused) {
    return "Paused";
  }
  const calibrationStatus = gazeStateStore.getSlice("calibration_status");
  if (calibrationStatus === "missing" || calibrationStatus === "invalid") {
    return "Needs calibration";
  }
  if (
    typeof calibrationStatus === "string" &&
    calibrationStatus !== "loaded" &&
    calibrationStatus !== "saved"
  ) {
    return "Calibrating";
  }
  const preview = gazeStateStore.getSlice("preview");
  // The preview slice's head claim counts only while its own stamp is
  // fresh — a frozen preview keeps serving its last answer and would hold
  // the menu at "Tracking" through a wedge. No stamp keeps the raw claim:
  // nothing disproves it.
  const previewStamp = Date.parse(preview?.updated_at ?? "");
  const previewStale =
    Number.isFinite(previewStamp) && Date.now() - previewStamp > PREVIEW_STALE_MS;
  const headDetected = preview && !previewStale ? preview.head_detected : undefined;
  if (headDetected === false) {
    return "No face";
  }
  const gaze = gazeStateStore.getSlice("gaze");
  const gazeStamp = Date.parse(gaze?.updated_at ?? "");
  if (Number.isFinite(gazeStamp)) {
    if (Date.now() - gazeStamp <= GAZE_STALE_MS) {
      return "Tracking";
    }
    // Feed went quiet — "No gaze" when a face was ever claimed.
    return headDetected === true || preview?.head_detected === true ? "No gaze" : "No face";
  }
  if (headDetected === true) {
    return "Tracking";
  }
  // No gaze stamp, no live face claim — the tracker has never produced a
  // frame. Inside the boot grace that's still "Starting"; past it (or with
  // no boot stamp to prove it's still warming) the honest word is "No gaze".
  const startedStamp = Date.parse(gazeStateStore.getSlice("started_at") ?? "");
  return Number.isFinite(startedStamp) && Date.now() - startedStamp <= BOOT_GRACE_MS
    ? "Starting"
    : "No gaze";
}

// The state label can change without a settings/report event (calibration
// status + preview head-detect flow through updateFromBackendMessage) — only
// rebuild when the label text actually differs so an open menu is never
// dismissed and per-frame store updates stay cheap.
function refreshTrayStateLabel() {
  if (!tray) {
    return;
  }
  const label = trayStateLabel();
  if (label === lastTrayLabel) {
    return;
  }
  lastTrayLabel = label;
  rebuildTrayMenu();
}

function rebuildTrayMenu() {
  if (!tray) {
    return;
  }
  lastTrayLabel = trayStateLabel();
  const dotScale = Number(cachedSettings.dot_scale);
  const diagnostics = cachedSettings.diagnostics || {};
  const menu = Menu.buildFromTemplate([
    { label: `Eye Tracking — ${trayStateLabel()}`, enabled: false },
    { type: "separator" },
    { label: "Recalibrate", click: () => requestRecalibration("tray") },
    {
      label: paused ? "Resume Tracking" : "Pause Tracking",
      click: () => dispatchMenuAction("pause_toggle")
    },
    { type: "separator" },
    {
      label: "Show Gaze Dot",
      type: "checkbox",
      // Default hidden — the element-level halo carries the pointing cue
      // (Vision Pro posture); this brings the floating dot back.
      checked: cachedSettings.gaze_dot_visible === true,
      click: (item) => {
        dispatchMenuAction("gaze_dot", item.checked);
        persistSettingsPatch({ gaze_dot_visible: item.checked });
      }
    },
    {
      label: "Dot Size",
      submenu: [
        { label: "Small", type: "radio", checked: dotScale === 0.8, click: () => applyTrayDotScale(0.8) },
        { label: "Default", type: "radio", checked: !Number.isFinite(dotScale) || dotScale === 1.0, click: () => applyTrayDotScale(1.0) },
        { label: "Large", type: "radio", checked: dotScale === 1.25, click: () => applyTrayDotScale(1.25) }
      ]
    },
    {
      label: "Dwell Lock",
      type: "checkbox",
      // Runtime default is anchorEnabled=true — unset means on, not off.
      checked: cachedSettings.dwell_lock !== false,
      click: (item) => {
        dispatchMenuAction("dwell_lock", item.checked);
        persistSettingsPatch({ dwell_lock: item.checked });
      }
    },
    { type: "separator" },
    {
      label: "Diagnostics",
      submenu: [
        { label: "Preview", type: "checkbox", checked: diagnostics.preview === true, click: (item) => applyTrayDiagnostic("preview", item.checked) },
        { label: "Status Panel", type: "checkbox", checked: diagnostics.status === true, click: (item) => applyTrayDiagnostic("status", item.checked) },
        { label: "Inference Time", type: "checkbox", checked: diagnostics.inference_time === true, click: (item) => applyTrayDiagnostic("inference_time", item.checked) }
      ]
    },
    { type: "separator" },
    // Only reachable in standalone dev — the Jarvis-spawned tracker
    // always passes --no-tray, so this never competes with the host's quit.
    { label: "Quit", click: () => app.quit() }
  ]);
  tray.setContextMenu(menu);
}

function applyTrayDotScale(scale) {
  dispatchMenuAction("dot_scale", scale);
  persistSettingsPatch({ dot_scale: scale });
}

function applyTrayDiagnostic(key, checked) {
  dispatchMenuAction(`${key}_toggle`, checked);
  persistSettingsPatch({ diagnostics: { [key]: checked } });
}

function maybeCreateTray(args) {
  if (hasFlag(args, "--no-tray")) {
    return;
  }
  try {
    const image = nativeImage.createFromDataURL(TRAY_ICON_DATA_URL);
    image.setTemplateImage(true);
    tray = new Tray(image);
    tray.setToolTip("Eye Tracking");
    rebuildTrayMenu();
    trayLabelPoll = setInterval(refreshTrayStateLabel, PREVIEW_STALE_MS);
  } catch (error) {
    console.error(`Failed to create tray icon: ${error instanceof Error ? error.message : error}`);
    tray = null;
  }
}

// Under Jarvis the tracker is a background service — the host's menu-bar
// item owns all chrome, so any Electron surface (Dock tile, Cmd-Tab entry,
// menu bar if the process is ever activated) reads as a second app. macOS
// only: app.dock and the activation policy don't exist elsewhere, and the
// host is a macOS app.
function applyHostedChromePolicy() {
  if (!isHostedMode() || process.platform !== "darwin") {
    return;
  }
  try {
    app.dock?.hide();
    // Belt-and-suspenders: dock.hide() flips the same activation policy,
    // but pinning it keeps the app out of Cmd-Tab even if something re-
    // shows the dock tile. Guarded — the method is macOS-only.
    if (typeof app.setActivationPolicy === "function") {
      app.setActivationPolicy("accessory");
    }
    // If the process is ever forced active anyway, a null application menu
    // means it cannot take over the menu bar.
    Menu.setApplicationMenu(null);
    // Cosmetic only — system surfaces that still resolve a name show the
    // tracker rather than "Electron". Nothing reads app.getName() or the
    // userData path, so this shifts nothing.
    app.setName("Jarvis Eye Tracking");
  } catch (error) {
    console.error(`Failed to suppress Electron chrome in hosted mode: ${error instanceof Error ? error.message : error}`);
  }
}

function createNutMouseAdapter() {
  return {
    move: (point) => mouse.setPosition(new Point(point.x, point.y)),
    press: () => mouse.pressButton(Button.LEFT),
    release: () => mouse.releaseButton(Button.LEFT)
  };
}

function configureLipClickController(args, displayBounds) {
  const detector = readDetector(args);
  const requested = hasFlag(args, "--enable-lip-motion");
  lipClickController = createLipClickController({
    mouse: createNutMouseAdapter(),
    getDisplayBounds: () => displayBounds,
    logger: console,
    emitEffect: (payload) => sendToRenderer(payload, { updateStore: false })
  });
  lipClickController.setCalibrationActive(hasFlag(args, "--calibrate"));
  lipClickController.setEnabled(requested && detector === "yolo");
  if (requested && detector !== "yolo") {
    sendToRenderer({
      type: "status",
      level: "warning",
      message: "--enable-lip-motion requires --detector yolo; disabling lip motion",
      detector
    });
  }
}

function handleLipMotionMessage(payload) {
  if (!lipClickController || !payload) {
    return;
  }
  if (payload.type === "calibration" && payload.status === "saved") {
    // Drift-path persistOffset writes also land here — don't drop the
    // mouth-click shield while a calibration modal still owns the screen;
    // the modal-interactive true→false transition re-arms clicks on close.
    if (!modalInteractive && !paused) {
      lipClickController.setCalibrationActive(false);
    }
    return;
  }
  if (payload.type === "gaze") {
    lipClickController.update(payload);
  }
}

function shouldSuppressRendererConsole(message) {
  return (
    message.includes("VerifyEachNodeIsAssignedToAnEp") ||
    message.includes("Some nodes were not assigned to the preferred execution providers") ||
    message.includes("Rerunning with verbose output on a non-minimal build will show node assignments")
  );
}

function applyPassiveOverlayMode() {
  if (!mainWindow || mainWindow.isDestroyed() || debugOverlay) {
    return;
  }
  mainWindow.setFocusable(false);
  mainWindow.setIgnoreMouseEvents(true);
}

function sanitizeOverlayRegions(regions) {
  if (!Array.isArray(regions)) {
    return [];
  }
  return regions
    .slice(0, 16)
    .map((region) => ({
      x: Math.max(0, Math.floor(Number(region.x) || 0)),
      y: Math.max(0, Math.floor(Number(region.y) || 0)),
      width: Math.max(0, Math.ceil(Number(region.width) || 0)),
      height: Math.max(0, Math.ceil(Number(region.height) || 0))
    }))
    .filter((region) => region.width > 0 && region.height > 0);
}

// Implicit-calibration source (COMETIC/WebGazer): when the cursor rests on a
// spot inside the calibrated display for a beat, that point is a likely gaze
// target — emitted once per rest, the worker decides whether to keep it.
let cursorIdlePoll = null;
function startCursorIdlePoll(bounds) {
  let last = { x: Number.NaN, y: Number.NaN };
  let movedAt = 0;
  let emitted = false;
  cursorIdlePoll = setInterval(() => {
    // modalInteractive/paused: an implicit label mutating the feature map
    // while the accuracy test scores it corrupts the measurement — and a
    // paused tracker must not learn from a cursor it isn't driving.
    if (!mainWindow || mainWindow.isDestroyed() || !rendererReady || modalInteractive || paused) {
      return;
    }
    const point = screen.getCursorScreenPoint();
    const now = Date.now();
    if (!Number.isFinite(last.x) || Math.hypot(point.x - last.x, point.y - last.y) > 8) {
      last = { x: point.x, y: point.y };
      movedAt = now;
      emitted = false;
      return;
    }
    if (emitted || now - movedAt < 700) {
      return;
    }
    const xNorm = (point.x - bounds.x) / bounds.width;
    const yNorm = (point.y - bounds.y) / bounds.height;
    if (xNorm < 0 || xNorm > 1 || yNorm < 0 || yNorm > 1) {
      return;
    }
    emitted = true;
    sendToRenderer({ type: "cursor_idle", x_norm: xNorm, y_norm: yNorm }, { updateStore: false });
  }, 100);
}

function createWindow() {
  const args = cliArgs();
  const runtime = resolveRuntime(args);
  const displays = screen.getAllDisplays().sort((a, b) => a.bounds.x - b.bounds.x || a.bounds.y - b.bounds.y);
  const displayIndexArg = readOption(args, "--display-index", null);
  const primaryDisplay = screen.getPrimaryDisplay();
  const primaryDisplayIndex = Math.max(
    0,
    displays.findIndex((display) => display.id === primaryDisplay.id)
  );
  const requestedDisplayIndex =
    displayIndexArg === null ? primaryDisplayIndex : Number.parseInt(displayIndexArg, 10);
  selectedDisplay = displays[requestedDisplayIndex] || displays[0];
  const invalidDisplay = !displays[requestedDisplayIndex];
  const bounds = selectedDisplay.bounds;
  debugOverlay = hasFlag(args, "--debug-overlay");
  shapeOverlay = hasFlag(args, "--shape-overlay");
  const cameraScreenX = readCameraScreenOption(args, "--camera-screen-x", 0.5);
  const cameraScreenY = readCameraScreenOption(args, "--camera-screen-y", 0.0);

  rendererConfig = {
    calibrate: hasFlag(args, "--calibrate"),
    accuracyTest: hasFlag(args, "--accuracy-test"),
    hitTest: hasFlag(args, "--hit-test"),
    calibrateIfMissing: hasFlag(args, "--calibrate-if-missing"),
    viewingDistanceCm: readNumberOption(args, "--viewing-distance-cm", 0) > 0 ? readNumberOption(args, "--viewing-distance-cm", 0) : undefined,
    calibrationTier: ["full", "standard", "quick"].includes(readOption(args, "--calibration-tier", "full"))
      ? readOption(args, "--calibration-tier", "full")
      : "full",
    runtime,
    displayIndex: invalidDisplay ? 0 : requestedDisplayIndex,
    requestedDisplayIndex,
    displayCount: displays.length,
    displayBounds: bounds,
    invalidDisplay,
    cameraScreenX,
    cameraScreenY,
    enableInferenceTime: hasFlag(args, "--enable-inference-time"),
    debug: hasFlag(args, "--debug"),
    showCameraMarker: hasFlag(args, "--show-camera-marker"),
    webInference: webInferenceConfig(args, bounds)
  };
  // webInference is always populated, so every former options fallback
  // duplicated a webInferenceConfig field — nothing left to pass.
  gazeStateStore.initialize(rendererConfig);
  // settings.json lives beside the calibration file; seed the store slice
  // from whatever is on disk (missing/corrupt reads as {}).
  settingsFilePath = path.join(
    path.dirname(rendererConfig.webInference?.calibrationFile || defaultCalibrationFile),
    "settings.json"
  );
  cachedSettings = readSettingsFileSync();
  gazeStateStore.updateSharedState({ settings: cachedSettings });
  configureLipClickController(args, bounds);
  maybeStartExternalApi(args);

  mainWindow = new BrowserWindow({
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    frame: debugOverlay,
    transparent: !debugOverlay,
    backgroundColor: debugOverlay ? "#0f172a" : undefined,
    resizable: false,
    movable: false,
    // macOS clamps window bounds to the work area (excludes the menu bar) —
    // the gaze overlay must own every pixel, notch and menu bar included.
    enableLargerThanScreen: true,
    skipTaskbar: !debugOverlay,
    focusable: debugOverlay,
    fullscreenable: false,
    hasShadow: false,
    // OS surfaces that read a window title (screen-share pickers, a11y
    // tools) should name the product, not "Electron". The page-title-updated
    // pin below keeps the renderer's <title> from overwriting it on load.
    title: "Jarvis Eye Tracking",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      // The prod path loads dist/ over file:// and onnxruntime-web fetches
      // models *inside a Web Worker* — --allow-file-access-from-files does
      // not reach worker contexts, so model loads 403 without this. The
      // window only ever shows bundled local content, so disabling web
      // security exposes nothing remote.
      webSecurity: false
    }
  });
  mainWindow.webContents.session.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(permission === "media");
  });
  // COOP/COEP → crossOriginIsolated. numThreads is pinned to 1 today
  // (threaded wasm faulted at session init), but the headers stay so ONNX
  // Runtime wasm can take real worker threads (SharedArrayBuffer) when
  // threading is re-enabled. All app assets are same-origin so isolation is
  // safe.
  mainWindow.webContents.session.webRequest.onHeadersReceived((details, callback) => {
    const headers = details.responseHeaders ?? {};
    if (details.url.startsWith("http://") || details.url.startsWith("https://")) {
      headers["Cross-Origin-Opener-Policy"] = ["same-origin"];
      headers["Cross-Origin-Embedder-Policy"] = ["require-corp"];
    }
    callback({ responseHeaders: headers });
  });
  // Space-universal HUD: the gaze dot, calibration targets and chips must
  // survive a macOS Space switch — without this the overlay stays welded to
  // the Space it booted on and every other desktop looks untracked. Joins
  // full-screen Spaces too. This call resets the always-on-top level on
  // macOS, so the level is re-asserted after it.
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  mainWindow.setAlwaysOnTop(true, "screen-saver");
  mainWindow.on("page-title-updated", (event) => event.preventDefault());
  if (isHostedMode()) {
    // The gaze dot/cards are a private HUD — keep them out of screenshots
    // and the screen-share window picker entirely.
    mainWindow.setContentProtection(true);
  }
  applyPassiveOverlayMode();
  startCursorIdlePoll(bounds);
  console.log(
    `Overlay display ${rendererConfig.displayIndex + 1}/${displays.length}: x=${bounds.x}, y=${bounds.y}, width=${bounds.width}, height=${bounds.height}`
  );
  console.log(
    displays
      .map(
        (display, index) =>
          `Display ${index}: id=${display.id}, primary=${display.id === primaryDisplay.id}, x=${display.bounds.x}, y=${display.bounds.y}, width=${display.bounds.width}, height=${display.bounds.height}`
      )
      .join("\n")
  );

  mainWindow.webContents.on("did-start-loading", () => {
    // Navigation/reload starts a fresh renderer that hasn't sent
    // renderer-ready — stop treating the old one as sendable and drop the
    // click shield back until it re-asks for modal interactivity. `paused`
    // stays main's truth: the fresh renderer boots unpaused, so the
    // renderer-ready handler re-emits it — forcing it false here would
    // silently drop a deliberate pause (and the host's screen-lock park).
    rendererReady = false;
    modalInteractive = false;
    lipClickController?.setCalibrationActive(paused || modalInteractive);
    gazeStateStore.updateSharedState({ paused });
    rebuildTrayMenu();
    applyPassiveOverlayMode();
  });
  mainWindow.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
    rendererReady = false;
    console.error(`Renderer failed to load ${validatedURL}: ${errorCode} ${errorDescription}`);
    sendToRenderer({
      type: "status",
      level: "error",
      message: `Renderer failed to load: ${errorDescription}`
    });
  });
  mainWindow.webContents.on("did-finish-load", () => {
    console.log("Renderer loaded");
    applyPassiveOverlayMode();
  });
  mainWindow.once("ready-to-show", applyPassiveOverlayMode);
  mainWindow.webContents.on("render-process-gone", (_event, details) => {
    console.error(`Renderer process gone: ${details.reason}`);
    rendererReady = false;
    // A crash while modal-interactive leaves an invisible always-on-top
    // window eating every mouse event on the screen — re-shield first, then
    // reload to auto-recover. Same pause-truth rule as did-start-loading:
    // the flag survives the crash and is re-emitted on renderer-ready.
    modalInteractive = false;
    lipClickController?.setCalibrationActive(paused || modalInteractive);
    gazeStateStore.updateSharedState({ paused });
    rebuildTrayMenu();
    applyPassiveOverlayMode();
    setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.reload();
      }
    }, 500);
  });
  mainWindow.webContents.on("console-message", (_event, levelOrDetails, messageArg, lineArg, sourceIdArg) => {
    const details =
      typeof levelOrDetails === "object" && levelOrDetails !== null
        ? levelOrDetails
        : {
            level: levelOrDetails,
            message: messageArg,
            lineNumber: lineArg,
            sourceId: sourceIdArg
          };
    const level = Number(details.level ?? 0);
    const message = String(details.message ?? "");
    if (shouldSuppressRendererConsole(message)) {
      return;
    }
    const line = details.lineNumber ?? details.line ?? 0;
    const sourceId = details.sourceId ?? "";
    const prefix = sourceId ? `${sourceId}:${line}` : `renderer:${line}`;
    if (level >= 3) {
      console.error(`[renderer-console] ${prefix} ${message}`);
    } else if (level === 2) {
      console.warn(`[renderer-console] ${prefix} ${message}`);
    } else {
      console.log(`[renderer-console] ${prefix} ${message}`);
    }
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else if (!app.isPackaged && process.env.NODE_ENV !== "production") {
    mainWindow.loadURL("http://127.0.0.1:5173");
  } else {
    mainWindow.loadFile(path.join(repoRoot, "dist", "index.html"));
  }
  if (debugOverlay) {
    mainWindow.webContents.openDevTools({ mode: "detach" });
  }

  if (invalidDisplay) {
    sendToRenderer({
      type: "status",
      level: "warning",
      message: `Display index ${requestedDisplayIndex} is not available; using display 0`
    });
  }

  sendToRenderer({
    type: "status",
    level: "info",
    message: `Using ${runtime} runtime in Electron renderer`,
    runtime
  });
  if (readOption(args, "--backend", null) !== null) {
    sendToRenderer({
      type: "status",
      level: "warning",
      message: `--backend is ignored by ${runtime} runtime`,
      runtime
    });
  }
}

ipcMain.handle("get-config", () => rendererConfig);

ipcMain.handle("read-calibration", async (_event, filePath) => {
  const resolved = resolveRepoPath(filePath || defaultCalibrationFile);
  try {
    const text = await fs.promises.readFile(resolved, "utf8");
    return { ok: true, text };
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return { ok: true, text: null };
    }
    return { ok: false, error: error.message };
  }
});

// Per-path writer mutex: drift-path persistOffset writes can overlap a
// commitPending save over the same file — plain writeFile can interleave into
// torn JSON. Chain writes per path and swap in via same-dir rename so the
// file is always whole.
const fileWriteQueues = new Map();
function writeJsonFileAtomic(filePath, payload) {
  const text = JSON.stringify(payload, null, 2);
  const previous = fileWriteQueues.get(filePath) || Promise.resolve();
  const next = previous
    .catch(() => {})
    .then(async () => {
      const tmpPath = `${filePath}.tmp`;
      await fs.promises.writeFile(tmpPath, text, "utf8");
      await fs.promises.rename(tmpPath, filePath);
    });
  fileWriteQueues.set(filePath, next);
  const cleanup = () => {
    if (fileWriteQueues.get(filePath) === next) {
      fileWriteQueues.delete(filePath);
    }
  };
  next.then(cleanup, cleanup);
  return next;
}

ipcMain.handle("write-calibration", async (_event, filePath, payload) => {
  const resolved = resolveRepoPath(filePath || defaultCalibrationFile);
  try {
    await writeJsonFileAtomic(resolved, payload);
    const message = { type: "calibration", status: "saved", path: resolved };
    gazeStateStore.updateFromBackendMessage(message);
    handleLipMotionMessage(message);
    return { ok: true, path: resolved };
  } catch (error) {
    return { ok: false, error: error.message };
  }
});

// Generic JSON report writer (accuracy test, diagnostics) — unlike
// write-calibration it must not emit a calibration-saved message into the
// external store, since the payload isn't a calibration.
// Relative report names land beside the calibration file: a bundled tracker
// lives in a sealed Resources dir, and the host already redirects the
// calibration (and reads accuracy_report.json) from Application Support.
ipcMain.handle("write-report", async (_event, filePath, payload) => {
  const calibrationFile = rendererConfig?.webInference?.calibrationFile;
  const resolved = calibrationFile ? path.resolve(path.dirname(calibrationFile), filePath) : resolveRepoPath(filePath);
  try {
    await writeJsonFileAtomic(resolved, payload);
    return { ok: true, path: resolved };
  } catch (error) {
    return { ok: false, error: error.message };
  }
});

ipcMain.on("publish-backend-message", (_event, payload) => {
  gazeStateStore.updateFromBackendMessage(payload);
  handleLipMotionMessage(payload);
  refreshTrayStateLabel();
});

ipcMain.on("renderer-ready", () => {
  rendererReady = true;
  // Drain a snapshot, never the live queue: a send that throws on a
  // crashed-but-undestroyed webContents re-queues its message once and
  // stops — pushing back into the queue being drained spins forever.
  const queue = pendingMessages.splice(0);
  for (let i = 0; i < queue.length; i += 1) {
    const item = queue[i];
    let sent = false;
    if (mainWindow && !mainWindow.isDestroyed()) {
      try {
        if (item.payload === undefined) {
          mainWindow.webContents.send(item.channel);
        } else {
          mainWindow.webContents.send(item.channel, item.payload);
        }
        sent = true;
      } catch {
        // Torn down mid-drain — requeue this message and the rest, don't spin.
      }
    }
    if (!sent) {
      pendingMessages.push(...queue.slice(i));
      break;
    }
  }
  // A fresh renderer boots unpaused — push main's pause truth down so a
  // deliberate pause (or the host's screen-lock park) survives a
  // reload/crash. Pause actions already queued above are the LATEST
  // intent and outrank the flag — pushing the stale flag over them would
  // un-park a pause that was requested while the renderer was down.
  let effectivePaused = paused;
  for (const item of queue) {
    const payload = item.payload;
    if (item.channel !== "backend-message" || !payload || payload.type !== "menu_action") {
      continue;
    }
    if (payload.action === "set_paused") {
      effectivePaused = payload.value === true;
    } else if (payload.action === "pause_toggle") {
      effectivePaused = !effectivePaused;
    }
  }
  dispatchMenuAction("set_paused", effectivePaused);
});

// Modal phases (calibration, accuracy test) own the whole screen — disable
// click-through so their buttons actually receive clicks; restore on exit.
// The window is focusable:false, so without setFocusable+focus the renderer
// never sees keydown and Escape can't cancel the modal.
ipcMain.on("modal-interactive", (_event, interactive) => {
  modalInteractive = Boolean(interactive);
  // While any calibration modal is up (or tracking is paused), mouth-clicks
  // must not actuate the OS cursor — it could land on the modal's own exit
  // button.
  lipClickController?.setCalibrationActive(modalInteractive || paused);
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }
  if (modalInteractive) {
    mainWindow.setFocusable(true);
    mainWindow.setIgnoreMouseEvents(false);
    // Hosted mode must never steal OS focus — the user stays in whatever app
    // they were in while the modal is driven by gaze + hotkeys. Standalone
    // still needs focus(): the window rests at focusable:false, so Escape
    // can't reach the modal without it.
    if (!isHostedMode()) {
      mainWindow.focus();
    }
    return;
  }
  if (debugOverlay) {
    // Debug windows stay normal interactive windows — click-through would
    // leave a dead opaque frame on screen.
    mainWindow.setIgnoreMouseEvents(false);
    return;
  }
  applyPassiveOverlayMode();
  if (isHostedMode() && process.platform === "darwin") {
    // Clicking the modal while it was focusable may have activated this
    // process — blur() alone can't undo an app-level activation. app.hide()
    // hands activation back to the previously frontmost app; it also hides
    // the overlay window, so app.show() on the next tick puts it back
    // (unhiding does not reactivate us).
    app.hide();
    setTimeout(() => {
      try {
        app.show();
      } catch (error) {
        console.error(`Failed to re-show overlay after modal close: ${error instanceof Error ? error.message : error}`);
      }
    }, 50);
    return;
  }
  mainWindow.blur();
});

ipcMain.on("overlay-regions", (_event, regions) => {
  if (!mainWindow || mainWindow.isDestroyed() || debugOverlay || !shapeOverlay) {
    return;
  }
  const rects = sanitizeOverlayRegions(regions);
  if ((process.platform === "linux" || process.platform === "win32") && typeof mainWindow.setShape === "function") {
    try {
      mainWindow.setShape(rects);
    } catch (error) {
      console.error(`Failed to set overlay shape: ${error.message}`);
    }
  }
  // Regions arrive every ~250ms — re-applying passive mode while a modal is
  // interactive would kill its focus/clickability one update after grant.
  if (!modalInteractive) {
    applyPassiveOverlayMode();
  }
});

// Renderer pause toggle (tray/menu/hotkey actions all funnel through the
// renderer, which confirms the new state here) — gates cursor-idle sampling
// and the lip-click path, and lands in the /snapshot `paused` slice.
ipcMain.on("set-paused", (_event, value) => {
  applyPausedFlag(value);
  gazeStateStore.updateSharedState({ paused });
  rebuildTrayMenu();
});

// Periodic shared-state report — merges whichever slices the renderer
// included (paused, calibration_status, settings) into the snapshot.
ipcMain.on("report-state", (_event, report) => {
  if (report && typeof report === "object" && report.paused !== undefined) {
    applyPausedFlag(report.paused);
  }
  const changed = gazeStateStore.updateSharedState(report);
  if (changed.length > 0) {
    rebuildTrayMenu();
  }
});

// settings.json beside the calibration file — read tolerates missing/corrupt
// (returns {}), write is merge + atomic rename under the settings queue.
ipcMain.handle("get-settings", () => readSettingsFile());

ipcMain.on("set-settings", (_event, patch) => {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) {
    return;
  }
  persistSettingsPatch(patch);
});

app.whenReady().then(async () => {
  // First in line — every beat of Dock/menu-bar visibility reads as a
  // second app next to Jarvis.
  applyHostedChromePolicy();
  // Host-death watchdog: Jarvis passes --host-pid so a spawned tracker
  // can never outlive the app — a crashed, force-quit, or wedged-shutdown
  // host means this process must be gone too (the graceful /control quit
  // only covers an orderly stop). Predicate + polling semantics live in
  // hostWatchdog.cjs; absent flag (standalone run) = no watchdog by design.
  const hostPid = Number.parseInt(readOption(cliArgs(), "--host-pid", "0"), 10);
  startHostWatchdog(hostPid, { onGone: () => app.quit() });
  if (process.platform === "darwin") {
    try {
      const cameraStatus = systemPreferences.getMediaAccessStatus("camera");
      console.log(`macOS camera status before request: ${cameraStatus}`);
      if (cameraStatus === "granted") {
        // Already granted — the TCC entry exists, so asking again buys
        // nothing and keeps the request on the code path that SIGABRTs when
        // camera attribution lands on a helper bundle. A JS rejection from
        // askForMediaAccess is survivable, a native SIGABRT is not — the
        // real defense-in-depth for the not-determined path is
        // scripts/patch-electron-app.sh stamping usage strings into every
        // helper plist, not anything we do here.
        console.log("macOS camera access already granted; skipping request");
      } else {
        const cameraAccess = await systemPreferences.askForMediaAccess("camera");
        console.log(`macOS camera status after request: ${systemPreferences.getMediaAccessStatus("camera")}`);
        console.log(`macOS camera access ${cameraAccess ? "granted" : "not granted"}`);
      }
    } catch (error) {
      console.error(`Failed to request macOS camera access: ${error.message}`);
    }
  }
  // Global recalibration hotkey — the drift notice points users here. Works
  // while the overlay is unfocused/click-through; never auto-triggers.
  try {
    const registered = globalShortcut.register("CommandOrControl+Shift+G", () => {
      try {
        requestRecalibration("⌘⇧G");
      } catch (error) {
        console.error(`Recalibrate hotkey dispatch failed: ${error}`);
      }
    });
    if (!registered) {
      // register() returns false when another app holds the shortcut —
      // silent failure would strand the drift notice's only instruction.
      console.error("⌘⇧G recalibration hotkey is held by another app; drift recalibration will not fire");
    }
  } catch (error) {
    console.error(`Failed to register recalibration hotkey: ${error}`);
  }
  // Global pause hotkey — same guarded registration as ⌘⇧G; dispatches the
  // identical menu_action the tray and POST /control send.
  try {
    const registered = globalShortcut.register("CommandOrControl+Shift+P", () => {
      try {
        dispatchMenuAction("pause_toggle");
      } catch (error) {
        console.error(`Pause hotkey dispatch failed: ${error}`);
      }
    });
    if (!registered) {
      console.error("⌘⇧P pause hotkey is held by another app; keyboard pause will not fire");
    }
  } catch (error) {
    console.error(`Failed to register pause hotkey: ${error}`);
  }
  createWindow();
  maybeCreateTray(cliArgs());
}).catch((error) => {
  // A createWindow throw (bad --camera-resolution, zero displays) would
  // otherwise leave a windowless app idling with the hotkey registered.
  console.error(`Startup failed: ${error instanceof Error ? error.stack || error.message : error}`);
  app.quit();
});

app.on("window-all-closed", () => {
  // Hosted mode is a background service — Jarvis owns the lifecycle and
  // terminates the process itself, so window teardown must never quit it
  // (that would sever POST /control). The overlay has no close affordance,
  // so reaching here means an explicit app.quit() is already in flight —
  // quit still proceeds, and before-quit already ran the same teardown.
  if (isHostedMode()) {
    return;
  }
  globalShortcut.unregisterAll();
  lipClickController?.releaseNow();
  if (cursorIdlePoll) {
    clearInterval(cursorIdlePoll);
    cursorIdlePoll = null;
  }
  stopExternalApi();
  app.quit();
});

// GPU-process telemetry — WebGPU device loss under the inference worker is
// a documented failure mode (sandbox kills, Metal resets). The flag is set
// here for the inference layer to consume; the log line is what makes a
// silent device drop diagnosable from tracker.log.
app.on("child-process-gone", (_event, details) => {
  if (details && details.type === "GPU") {
    gpuProcessDied = true;
    console.error(
      `GPU child process gone: reason=${details.reason} exitCode=${details.exitCode} name=${details.name ?? details.serviceName ?? "unknown"}`
    );
  }
});

app.on("before-quit", () => {
  lipClickController?.releaseNow();
  if (cursorIdlePoll) {
    clearInterval(cursorIdlePoll);
    cursorIdlePoll = null;
  }
  stopExternalApi();
  if (trayLabelPoll) {
    clearInterval(trayLabelPoll);
    trayLabelPoll = null;
  }
  if (tray) {
    tray.destroy();
    tray = null;
  }
});
