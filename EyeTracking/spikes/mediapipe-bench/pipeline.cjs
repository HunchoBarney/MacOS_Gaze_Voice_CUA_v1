// End-to-end tracker pipeline bench: the BUILT inference worker
// (dist/assets/inferenceWorker-*.js) fed jittered frames of a still face at
// the tracker's 20 fps cap, exactly as the renderer's pump posts them — no
// camera, no overlay window. Reports emitted-gaze rate, inference ms and CPU
// summed over every Electron process (top, 100 = one core).
//   pnpm build && [FPS=20] [DELEGATE=gpu|cpu] node_modules/.bin/electron spikes/mediapipe-bench/pipeline.cjs <image> [mediapipe|retinaface] [seconds] [models-dir]
const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const [image, detector = "mediapipe", seconds = "30", modelsDir] = process.argv.slice(2).filter((a) => !a.startsWith("--") && !a.endsWith(".cjs"));
const root = path.resolve(__dirname, "../..");
const dist = path.join(root, "dist");
const worker = fs.readdirSync(path.join(dist, "assets")).find((n) => /^inferenceWorker-.*\.js$/.test(n));
const models = modelsDir ? path.resolve(modelsDir) : path.join(dist, "models");
const url = (p) => pathToFileURL(p).href;

const config = {
  runtime: "onnxweb",
  webInferenceWorker: "dedicated",
  webAccelerator: "wasm",
  detector,
  backend: "web",
  camera: "0",
  cameraWidth: 640,
  cameraHeight: 480,
  cameraFov: 78,
  scoreThreshold: 0.5,
  displaySizeInch: 13.3,
  displayWidth: 1440,
  displayHeight: 900,
  calibrationFile: "bench-calibration.json",
  detectorModel: "",
  lipMotionModel: "",
  detectorModelUrl: detector === "mediapipe" ? url(path.join(models, "face_landmarker.task")) : url(path.join(models, "retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx")),
  gazeModelUrl: detector === "mediapipe" ? "" : url(path.join(models, "gaze_1x3x160x160.onnx")),
  lipMotionModelUrl: "",
  onnxWasmBaseUrl: url(path.join(root, "node_modules/onnxruntime-web/dist")) + "/",
  mediapipeWasmBaseUrl: url(path.join(dist, "runtime-assets/mediapipe")) + "/",
  mediapipeDelegate: process.env.DELEGATE === "cpu" ? "cpu" : "gpu",
  appearanceModelUrl: detector === "mediapipe" || !fs.existsSync(path.join(models, "mobileone_s0_gaze.onnx")) ? undefined : url(path.join(models, "mobileone_s0_gaze.onnx")),
  smoothingAlpha: 0.65,
  smoothingAlphaY: 0.45,
  calibrate: false,
  gazeFilter: "saccade",
  filterMincutoff: 1,
  filterBeta: 0.7,
  filterDcutoff: 1,
  disableIrisDistance: false,
  previewFps: 8,
  gazeMaxFps: 20,
  wasmThreads: 1,
  hidePreview: true,
  flipX: true,
  flipY: true,
  cameraScreenX: 0.5,
  cameraScreenY: 0,
  eyePositionWeightX: 1,
  eyePositionWeightY: 0.25,
  retinafaceHeadFaceRatio: 1.545,
  gazeProjectionMode: "binocular-screen",
  enableLipMotion: false
};

app.whenReady().then(async () => {
  const win = new BrowserWindow({ show: false, webPreferences: { preload: path.join(__dirname, "preload.cjs"), sandbox: false } });
  let top = null;
  let topOut = "";
  ipcMain.on("phase", () => {
    const pids = app.getAppMetrics().map((m) => m.pid);
    top = require("child_process").spawn("top", ["-l", String(Number(seconds) + 2), "-s", "1", "-stats", "pid,cpu", ...pids.flatMap((p) => ["-pid", String(p)])]);
    top.stdout.on("data", (c) => (topOut += c));
  });
  ipcMain.on("done", (_e, result) => {
    top?.kill();
    const pids = new Set(app.getAppMetrics().map((m) => String(m.pid)));
    const cpu = topOut
      .split(/^Processes:/m)
      .slice(2)
      .map((b) => b.split("\n").map((l) => l.trim().split(/\s+/)).filter((c) => pids.has(c[0])).reduce((s, c) => s + Number(c[1]), 0))
      .sort((a, b) => a - b);
    const rss = app.getAppMetrics().reduce((s, m) => s + m.memory.workingSetSize, 0) / 1024;
    console.log(
      JSON.stringify(
        {
          detector,
          target_fps: Number(process.env.FPS ?? 20),
          delegate: detector === "mediapipe" ? config.mediapipeDelegate : "ort-wasm",
          ...result,
          cpu_percent_of_one_core_all_processes: cpu.length
            ? { mean: cpu.reduce((a, b) => a + b, 0) / cpu.length, p50: cpu[Math.floor(cpu.length / 2)], max: cpu[cpu.length - 1], samples: cpu.length }
            : null,
          rss_mb_all_processes: rss
        },
        null,
        2
      )
    );
    app.exit(0);
  });
  ipcMain.on("fail", (_e, m) => {
    console.error("pipeline bench failed:", m);
    app.exit(1);
  });
  const q = new URLSearchParams({ image: url(path.resolve(image)), worker: url(path.join(dist, "assets", worker)), seconds, fps: process.env.FPS ?? "20", config: JSON.stringify(config) });
  await win.loadFile(path.join(__dirname, "pipeline.html"), { search: q.toString() });
});
