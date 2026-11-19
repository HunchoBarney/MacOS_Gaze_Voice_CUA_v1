import type { WebAccelerator, WebInferenceConfig } from "../global";
import {
  APPEARANCE_INPUT_SIZE,
  createAppearanceInput,
  createGazeInput,
  createLipMotionInput,
  createRetinaFaceInput,
  createYoloInput,
  decodeBinnedAngle,
  estimateGazeFromModelOutput,
  type AppearanceAngles,
  type Detection,
  type DetectionResult,
  type GazeEstimate,
  type GazeCrop,
  parseRetinaFaceOutput,
  parseYoloOutput,
  LIP_MOTION_INPUT_HEIGHT,
  LIP_MOTION_INPUT_WIDTH,
  YOLO_INPUT_HEIGHT,
  YOLO_INPUT_WIDTH
} from "./core";
import { faceFromLandmarkerResult, mediapipeFrame, type MediaPipeFrameResult } from "./mediapipe";

// WebGPU device-loss telemetry: runtimes reports a live `device.lost`
// resolution so the worker/page can log it as a status line instead of
// diagnosing the follow-on inference failures blind. Registered once by the
// runtime owner (inferenceWorker / webRuntime).
export interface GpuDeviceLostReport {
  reason: string;
  message: string;
}

let gpuDeviceLostListener: ((report: GpuDeviceLostReport) => void) | null = null;

export function setGpuDeviceLostListener(listener: ((report: GpuDeviceLostReport) => void) | null): void {
  gpuDeviceLostListener = listener;
}

export interface RuntimeModels {
  readonly accelerator: WebAccelerator;
  readonly detectorProviders: string[];
  readonly gazeProviders: string[];
  readonly lipMotionProviders: string[];
  // Phase-4 second signal: appearance gaze net, run at reduced cadence by the
  // caller (AppearanceChannel). Undefined while it isn't ready — which now
  // includes the whole boot window, since its session+warmup are deferred
  // off the startup critical path (see startAppearance).
  readonly appearance?: {
    estimate(frame: ImageData, head: Detection): Promise<AppearanceAngles>;
  };
  // Kicks the deferred appearance-model load — called by the frame loop
  // after the first real gaze emit so the create+compile can't sit on the
  // path to first frame. Idempotent and fire-and-forget.
  startAppearance?(): void;
  detect(frame: ImageData): Promise<DetectionResult>;
  estimate(frame: ImageData, head: Detection, eyes: Detection[]): Promise<GazeEstimate>;
  estimateLipMotion(frame: ImageData, mouth: Detection): Promise<number | null>;
  // Runtimes whose estimate needs a real face (MediaPipe) compile their
  // graph here instead of through the synthetic-box estimate below.
  warmup?(): Promise<void>;
  // Resolves only once ORT has actually freed every session's wasm heap —
  // callers reloading models must await it or the create races the free and
  // re-faults with the same "memory access out of bounds".
  dispose(): Promise<void>;
}

// Boot-time warmup stays non-throwing (its output is discarded anyway).
// Session recovery passes strict=true: a reloaded session that creates
// cleanly yet dies on its first real run must count as a failed attempt —
// the OOM kills the heap, not session.create.
export async function warmupRuntimeModels(models: RuntimeModels, strict = false): Promise<void> {
  if (models.warmup) {
    try {
      await models.warmup();
    } catch (error) {
      if (strict) {
        throw error;
      }
    }
    return;
  }
  const frame = new ImageData(160, 160);
  const head: Detection = { classId: 7, score: 1, x1: 20, y1: 10, x2: 140, y2: 150 };
  const eyes: Detection[] = [
    { classId: 17, score: 1, x1: 50, y1: 70, x2: 60, y2: 80 },
    { classId: 17, score: 1, x1: 100, y1: 70, x2: 110, y2: 80 }
  ];
  try {
    await models.estimate(frame, head, eyes);
    if (models.appearance) {
      // 480² warm frame is enough to compile the provider pipeline; discard.
      await models.appearance.estimate(new ImageData(480, 480), head).catch(() => undefined);
    }
  } catch (error) {
    if (strict) {
      throw error;
    }
    // Warmup output is discarded; the inference itself compiles provider pipelines.
  }
}

let onnxSessionCreateQueue = Promise.resolve();

export async function createRuntimeModels(config: WebInferenceConfig, accelerator: WebAccelerator): Promise<RuntimeModels> {
  runtimeAssetBaseUrl = config.assetBaseUrl ?? globalThis.location.href;
  if (config.detector === "mediapipe") {
    return createMediaPipeRuntimeModels(config);
  }
  return createOnnxRuntimeModels(config, accelerator);
}

// MediaPipe Face Landmarker: one synchronous VIDEO-mode call per frame gives
// boxes, iris and pose together. detect() runs it and estimate() reuses the
// result for the same frame object, so the worker pays one model call per
// frame. GPU (WebGL2 in the worker) is the default — 14 ms/frame and ~26% of
// one core at 20 fps on the M1 vs 20 ms and ~44% for the XNNPACK wasm CPU
// delegate — and a GPU create failure falls back to CPU. It never
// touches ONNX Runtime, so the accelerator reads "wasm" and the WebGPU
// recovery ladder stays out of the way.
async function createMediaPipeRuntimeModels(config: WebInferenceConfig): Promise<RuntimeModels> {
  const vision = await import("@mediapipe/tasks-vision");
  const base = absoluteAssetUrl(config.mediapipeWasmBaseUrl ?? "runtime-assets/mediapipe/");
  const model = await fetchModelBytes(config.detectorModelUrl);
  const create = (delegate: "GPU" | "CPU") =>
    vision.FaceLandmarker.createFromOptions(
      { wasmLoaderPath: `${base}vision_wasm_internal.js`, wasmBinaryPath: `${base}vision_wasm_internal.wasm` },
      {
        baseOptions:
          typeof model === "string" ? { modelAssetPath: absoluteAssetUrl(model), delegate } : { modelAssetBuffer: model, delegate },
        runningMode: "VIDEO",
        numFaces: 1,
        outputFaceBlendshapes: true,
        outputFacialTransformationMatrixes: true
      }
    );
  let delegate: "GPU" | "CPU" = config.mediapipeDelegate === "cpu" ? "CPU" : "GPU";
  let landmarker: Awaited<ReturnType<typeof create>>;
  try {
    landmarker = await create(delegate);
  } catch (error) {
    if (delegate === "CPU") {
      throw error;
    }
    console.warn("MediaPipe GPU delegate failed to start; using the CPU delegate", error);
    delegate = "CPU";
    landmarker = await create(delegate);
  }
  const providers = [`mediapipe-${delegate.toLowerCase()}`];
  let lastTimestamp = 0;
  let cached: { frame: ImageData; result: MediaPipeFrameResult | null } | null = null;
  let closed = false;
  const run = (frame: ImageData): MediaPipeFrameResult | null => {
    if (cached?.frame === frame) {
      return cached.result;
    }
    if (closed) {
      throw new Error("invalid session id: MediaPipe landmarker closed");
    }
    // VIDEO mode requires strictly increasing timestamps.
    lastTimestamp = Math.max(lastTimestamp + 1, performance.now());
    const face = faceFromLandmarkerResult(landmarker.detectForVideo(frame, lastTimestamp));
    const result = face === null ? null : mediapipeFrame(face, frame.width, frame.height);
    cached = { frame, result };
    return result;
  };
  return {
    accelerator: "wasm",
    detectorProviders: providers,
    gazeProviders: providers,
    lipMotionProviders: [],
    async detect(frame) {
      return run(frame)?.detection ?? { head: null, eyes: [], mouth: null };
    },
    async estimate(frame) {
      const result = run(frame);
      if (result === null) {
        throw new Error("MediaPipe found no face in this frame");
      }
      return result.estimate;
    },
    async estimateLipMotion() {
      return null;
    },
    async warmup() {
      run(new ImageData(640, 480));
    },
    async dispose() {
      closed = true;
      cached = null;
      landmarker.close();
    }
  };
}

async function createOnnxRuntimeModels(config: WebInferenceConfig, accelerator: WebAccelerator): Promise<RuntimeModels> {
  const ort = await import("onnxruntime-web/webgpu");
  // Threaded wasm (numThreads > 1 via crossOriginIsolation) faulted at
  // runtime under ORT 1.26 (memory access out of bounds) — the default stays
  // pinned to 1. `--wasm-threads N` on the host lands here as
  // config.wasmThreads and opts back into a threaded pool (needs
  // crossOriginIsolation to actually spawn workers).
  // The AppearanceChannel duty-cycle cap absorbs the ensemble's per-call cost.
  const requestedThreads = Number((config as WebInferenceConfig & { wasmThreads?: number }).wasmThreads);
  ort.env.wasm.numThreads = Number.isFinite(requestedThreads) ? Math.min(Math.max(1, Math.trunc(requestedThreads)), 16) : 1;
  ort.env.wasm.proxy = config.webInferenceWorker === "ort-proxy" && accelerator === "wasm";
  ort.env.wasm.wasmPaths = absoluteAssetUrl(config.onnxWasmBaseUrl);
  ort.env.logLevel = "error";
  const providers = [accelerator];
  // Byte reads overlap the serialized creates: the queue exists so CREATE
  // calls don't race ORT's wasm heap — it never needed to serialize the I/O.
  // Each fetch streams in while the previous session compiles, and a URL
  // that fetch can't reach (file:// in embeddings without the access flag)
  // falls back to ORT's own loader by returning the URL form.
  const detectorBytes = fetchModelBytes(config.detectorModelUrl);
  const gazeBytes = fetchModelBytes(config.gazeModelUrl);
  const lipMotionBytes = config.enableLipMotion && config.detector === "yolo" ? fetchModelBytes(config.lipMotionModelUrl) : null;
  // Prefetch errors surface at their awaits below — observe the tails now so
  // a slow first create can't read them as unhandled rejections.
  for (const pending of [gazeBytes, lipMotionBytes]) {
    void pending?.then(undefined, () => undefined);
  }
  const detector = await createOnnxSessionQueued(ort, await detectorBytes, providers, config.detectorModelUrl);
  let gaze: Awaited<ReturnType<typeof ort.InferenceSession.create>>;
  let lipMotion: Awaited<ReturnType<typeof ort.InferenceSession.create>> | null = null;
  try {
    if (accelerator === "webgpu") {
      await delay(50);
    }
    gaze = await createOnnxSessionQueued(ort, await gazeBytes, providers, config.gazeModelUrl);
    if (lipMotionBytes !== null) {
      lipMotion = await createOnnxSessionQueued(ort, await lipMotionBytes, providers, config.lipMotionModelUrl);
    }
  } catch (error) {
    void detector.release();
    if (lipMotion !== null) {
      void lipMotion.release();
    }
    throw error;
  }

  // Deferred ensemble: the appearance session is wasm-only (the MobileOne
  // net's partially-partitioned ops fault inside the WebGPU EP's wasm
  // fallback kernels), and it now builds off the startup critical path —
  // startAppearance() is kicked by the frame loop after the first real gaze
  // emit. `appearance` stays undefined until the session exists AND warmed.
  let appearanceSession: Awaited<ReturnType<typeof ort.InferenceSession.create>> | null = null;
  let appearanceEstimate: { estimate(frame: ImageData, head: Detection): Promise<AppearanceAngles> } | undefined;
  let appearanceLoading: Promise<void> | null = null;
  let sessionsDisposed = false;
  const startAppearance = (): void => {
    if (!config.appearanceModelUrl || appearanceLoading !== null || sessionsDisposed) {
      return;
    }
    appearanceLoading = (async () => {
      try {
        const session = await createOnnxSessionQueued(ort, config.appearanceModelUrl as string, ["wasm"], config.appearanceModelUrl);
        if (sessionsDisposed) {
          void session.release();
          return;
        }
        appearanceSession = session;
        const estimate = makeAppearanceEstimate(ort, session);
        try {
          // Compile the provider pipeline off the critical path too — the
          // channel's first real run shouldn't pay the compile cost.
          const warmHead: Detection = { classId: 7, score: 1, x1: 20, y1: 10, x2: 140, y2: 150 };
          await estimate(new ImageData(480, 480), warmHead);
        } catch {
          // A bad warm-up run must not kill the channel — AppearanceChannel's
          // own failure cap handles persistent faults per-run.
        }
        if (!sessionsDisposed) {
          appearanceEstimate = { estimate };
        }
      } catch (error) {
        // A missing/corrupt ensemble model must not take down the main path.
        console.warn("Appearance gaze model failed to load; continuing without it", error);
      }
    })();
  };
  if (accelerator === "webgpu") {
    // Arm device-loss telemetry once the session set owns the GPUDevice —
    // env.webgpu.device resolves to the device ORT just created.
    void reportGpuDeviceLost(ort);
  }
  const detectorInputName = config.detector === "yolo" ? detector.inputNames[0] ?? "images" : "input";
  const detectorOutputName = config.detector === "yolo" ? detector.outputNames[0] ?? "output0" : "batchno_classid_score_x1y1x2y2_landms";
  const gazeInputName = "input";
  const gazeOutputName = "output";
  const lipMotionInputName = "images";
  const lipMotionOutputName = "prob_open";
  return {
    accelerator,
    detectorProviders: providers,
    gazeProviders: providers,
    lipMotionProviders: lipMotion !== null ? providers : [],
    async detect(frame) {
      const input =
        config.detector === "yolo"
          ? new ort.Tensor("float32", createYoloInput(frame), [1, 3, YOLO_INPUT_HEIGHT, YOLO_INPUT_WIDTH])
          : new ort.Tensor("float32", createRetinaFaceInput(frame), [1, 3, 480, 640]);
      // Every run allocates wasm/GPU buffers — dispose inputs and outputs or
      // the 30fps loop churns memory until the EP falls over.
      let results: Awaited<ReturnType<typeof detector.run>> | null = null;
      try {
        results = await detector.run({ [detectorInputName]: input });
        const output = results[detectorOutputName] ?? results[detector.outputNames[0]];
        // Scale boxes into the frame that was actually captured — under the
        // default-policy VGA fallback that can differ from the configured
        // cameraWidth/Height request.
        if (config.detector === "yolo") {
          return parseYoloOutput(output.data as Float32Array, config.scoreThreshold, frame.width, frame.height);
        }
        return parseRetinaFaceOutput(output.data as Float32Array, config.scoreThreshold, frame.width, frame.height);
      } finally {
        input.dispose();
        if (results !== null) {
          for (const name of Object.keys(results)) {
            results[name].dispose();
          }
        }
      }
    },
    async estimate(frame, head, eyes) {
      const crop = createGazeInput(frame, head, eyes);
      const input = new ort.Tensor("float32", crop.input, [1, 3, 160, 160]);
      let results: Awaited<ReturnType<typeof gaze.run>> | null = null;
      try {
        results = await gaze.run({ [gazeInputName]: input });
        const output = results[gazeOutputName] ?? results[gaze.outputNames[0]];
        return estimateFromOutput(output.data as Float32Array, crop);
      } finally {
        input.dispose();
        if (results !== null) {
          for (const name of Object.keys(results)) {
            results[name].dispose();
          }
        }
      }
    },
    async estimateLipMotion(frame, mouth) {
      if (lipMotion === null) {
        return null;
      }
      const input = new ort.Tensor("float32", createLipMotionInput(frame, mouth), [1, 3, LIP_MOTION_INPUT_HEIGHT, LIP_MOTION_INPUT_WIDTH]);
      let results: Awaited<ReturnType<typeof lipMotion.run>> | null = null;
      try {
        results = await lipMotion.run({ [lipMotionInputName]: input });
        const output = results[lipMotionOutputName] ?? results[lipMotion.outputNames[0]];
        return Number((output.data as Float32Array)[0]);
      } finally {
        input.dispose();
        if (results !== null) {
          for (const name of Object.keys(results)) {
            results[name].dispose();
          }
        }
      }
    },
    get appearance() {
      return appearanceEstimate;
    },
    startAppearance,
    async dispose() {
      sessionsDisposed = true;
      // A deferred appearance create may still be queued — await it so
      // "dispose resolves only once the heap is freed" stays true (it
      // self-releases on the sessionsDisposed check above either way).
      if (appearanceLoading !== null) {
        await appearanceLoading;
      }
      // release() rejects (or throws) on an already-dead session — neither
      // should break cleanup. allSettled so one bad release can't strand
      // the others.
      const releases: Promise<void>[] = [];
      for (const session of [detector, gaze, lipMotion, appearanceSession]) {
        if (session === null) {
          continue;
        }
        try {
          releases.push(session.release());
        } catch {
          // Session already released.
        }
      }
      await Promise.allSettled(releases);
    }
  };
}

// Bounds a single serialized session create: on the UB-wedged ORT 1.26
// build (and any future Dawn-level wedge) a create can hang forever, which
// used to stall the whole queue — every later rebuild then starved behind
// it. The timeout rejects the rung and lets the chain continue; the late
// ORT promise still settles on its own (its session is orphaned, nothing
// references it, GC/bundle teardown reclaims it).
const ONNX_SESSION_CREATE_TIMEOUT_MS = 30_000;

function createOnnxSessionQueued(
  ort: typeof import("onnxruntime-web/webgpu"),
  model: string | Uint8Array,
  providers: string[],
  label?: string
): Promise<Awaited<ReturnType<typeof ort.InferenceSession.create>>> {
  const tag = label ?? (typeof model === "string" ? model : "bytes");
  const create = onnxSessionCreateQueue.then(() => {
    const createOpts = { executionProviders: providers, logSeverityLevel: 3 as const };
    const inner = typeof model === "string"
      ? ort.InferenceSession.create(model, createOpts)
      : ort.InferenceSession.create(model, createOpts);
    return withTimeout(inner, ONNX_SESSION_CREATE_TIMEOUT_MS, `InferenceSession.create(${tag})`).catch((error) => {
      // The timeout moved the ladder on but ORT may still finish — release
      // the late-arriving session rather than leaking it. If inner rejected
      // (its own create error), the .then never runs and the inner catch
      // swallows nothing new.
      void inner
        .then((late: Awaited<ReturnType<typeof ort.InferenceSession.create>>) => late.release())
        .then(
          () => undefined,
          () => undefined
        );
      throw error;
    });
  });
  onnxSessionCreateQueue = create.then(
    () => undefined,
    () => undefined
  );
  return create;
}

// env.webgpu.device is a Promise<GPUDevice> (resolves to the device the
// WebGPU EP created, or creates one on demand). `.lost` resolves once per
// device — reason "destroyed" is ORT's own release() tearing down during an
// intentional dispose/rebuild, which must not surface as a failure.
// lastWatchedDevice dedupes: if ORT hands back the same device across a
// session rebuild, hooking .lost again would double-report one loss.
let lastWatchedDevice: unknown = null;

async function reportGpuDeviceLost(ort: typeof import("onnxruntime-web/webgpu")): Promise<void> {
  try {
    const envDevice: unknown = (ort.env.webgpu as { device?: unknown }).device;
    const device =
      envDevice !== null &&
      (typeof envDevice === "object" || typeof envDevice === "function") &&
      typeof (envDevice as PromiseLike<unknown>).then === "function"
        ? await (envDevice as PromiseLike<unknown>)
        : envDevice;
    if (device === null || device === undefined || device === lastWatchedDevice) {
      return;
    }
    lastWatchedDevice = device;
    const lost = typeof device === "object" ? (device as { lost?: PromiseLike<{ reason?: string; message?: string }> }).lost : undefined;
    if (lost === undefined || lost === null || typeof lost.then !== "function") {
      return;
    }
    const info = await lost;
    if (info === undefined || info === null || info.reason === "destroyed") {
      return;
    }
    gpuDeviceLostListener?.({ reason: String(info.reason ?? "unknown"), message: String(info.message ?? "") });
  } catch {
    // Telemetry only — a weird env shape or a rejected lost promise must
    // never break session creation.
  }
}

export function withTimeout<T>(operation: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof globalThis.setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = globalThis.setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([operation, timeout]).finally(() => {
    if (timer !== undefined) {
      globalThis.clearTimeout(timer);
    }
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, ms));
}

// Streams the model body so session creates overlap network I/O with wasm
// compile. A URL fetch can't reach every embedding (file:// in a worker
// without the access flag) — on ANY failure fall back to the URL form and
// ORT's own loader gets the same chance it always had; a real 404 then
// still fails inside create() exactly as it would have before.
async function fetchModelBytes(modelUrl: string): Promise<Uint8Array | string> {
  try {
    const response = await fetch(absoluteAssetUrl(modelUrl));
    if (!response.ok) {
      return modelUrl;
    }
    return new Uint8Array(await response.arrayBuffer());
  } catch {
    return modelUrl;
  }
}

// The MobileOne ensemble session wrapper — lifted out of the create ladder
// so the deferred startAppearance() path can build it whenever it lands.
function makeAppearanceEstimate(
  ort: typeof import("onnxruntime-web/webgpu"),
  session: Awaited<ReturnType<typeof ort.InferenceSession.create>>
): (frame: ImageData, head: Detection) => Promise<AppearanceAngles> {
  return async (frame, head) => {
    const input = new ort.Tensor("float32", createAppearanceInput(frame, head), [
      1,
      3,
      APPEARANCE_INPUT_SIZE,
      APPEARANCE_INPUT_SIZE
    ]);
    let results: Awaited<ReturnType<typeof session.run>> | null = null;
    try {
      results = await session.run({ [session.inputNames[0] ?? "input"]: input });
      const yaw = results.yaw ?? results[session.outputNames[0]];
      const pitch = results.pitch ?? results[session.outputNames[1]];
      const yawDec = decodeBinnedAngle(yaw.data as Float32Array);
      const pitchDec = decodeBinnedAngle(pitch.data as Float32Array);
      return {
        yawDeg: yawDec.deg,
        pitchDeg: pitchDec.deg,
        confidence: Math.max(yawDec.peak, pitchDec.peak)
      };
    } finally {
      input.dispose();
      if (results !== null) {
        for (const name of Object.keys(results)) {
          results[name].dispose();
        }
      }
    }
  };
}

function absoluteAssetUrl(url: string): string {
  return new URL(url, runtimeAssetBaseUrl).toString();
}

let runtimeAssetBaseUrl = globalThis.location.href;

function estimateFromOutput(output: Float32Array, crop: GazeCrop): GazeEstimate {
  return estimateGazeFromModelOutput(output, crop);
}
