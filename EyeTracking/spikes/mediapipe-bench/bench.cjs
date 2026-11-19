// MediaPipe Face Landmarker throughput/CPU bench for JARA-27. Runs the
// landmarker exactly as the tracker does (classic worker, VIDEO mode,
// 640x480 ImageData from an OffscreenCanvas) on a still face image that is
// jittered a few pixels per frame — no camera, hidden window.
//   node_modules/.bin/electron spikes/mediapipe-bench/bench.cjs <image> [cpu|gpu] [seconds] [fps]
const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");

const [image, delegate = "cpu", seconds = "30", fps = "20"] = process.argv.slice(2).filter((a) => !a.startsWith("--") && !a.endsWith(".cjs"));
const root = path.resolve(__dirname, "../..");

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    webPreferences: { preload: path.join(__dirname, "preload.cjs"), sandbox: false }
  });
  const cpuSamples = [];
  let topProc = null;
  let topOut = "";
  let sampling = null;
  ipcMain.on("phase", (_e, phase) => {
    if (phase === "paced-start") {
      // top's per-interval %CPU is per core (100 = one core), summed over
      // every process of this Electron app (main, GPU, renderer+worker).
      const pids = app.getAppMetrics().map((m) => m.pid);
      topProc = require("child_process").spawn("top", ["-l", String(Number(seconds) + 2), "-s", "1", "-stats", "pid,cpu,mem", ...pids.flatMap((p) => ["-pid", String(p)])]);
      topProc.stdout.on("data", (chunk) => (topOut += chunk));
      app.getAppMetrics();
      sampling = setInterval(() => {
        const renderer = app.getAppMetrics().find((m) => m.pid === win.webContents.getOSProcessId());
        if (renderer) cpuSamples.push(renderer.cpu.percentCPUUsage);
      }, 1000);
    }
  });
  ipcMain.on("done", (_e, result) => {
    clearInterval(sampling);
    topProc?.kill();
    const pidSet = new Set(app.getAppMetrics().map((m) => String(m.pid)));
    const perSample = topOut
      .split(/^Processes:/m)
      .slice(2)
      .map((block) =>
        block
          .split("\n")
          .map((line) => line.trim().split(/\s+/))
          .filter((cols) => pidSet.has(cols[0]))
          .reduce((sum, cols) => sum + Number(cols[1]), 0)
      )
      .filter(Number.isFinite)
      .sort((a, b) => a - b);
    const metrics = app.getAppMetrics();
    const renderer = metrics.find((m) => m.pid === win.webContents.getOSProcessId());
    const sorted = cpuSamples.slice(1).sort((a, b) => a - b);
    const out = {
      ...result,
      delegate,
      top_cpu_percent_of_one_core_all_processes: perSample.length
        ? { mean: perSample.reduce((a, b) => a + b, 0) / perSample.length, p50: perSample[Math.floor(perSample.length / 2)], max: perSample[perSample.length - 1], samples: perSample.length }
        : null,
      electron_app_metrics_cpu_percent: sorted.length ? { mean: sorted.reduce((a, b) => a + b, 0) / sorted.length, p50: sorted[Math.floor(sorted.length / 2)], max: sorted[sorted.length - 1], samples: sorted.length } : null,
      renderer_rss_mb: renderer ? renderer.memory.workingSetSize / 1024 : null,
      electron: process.versions.electron,
      chrome: process.versions.chrome
    };
    console.log(JSON.stringify(out, null, 2));
    app.exit(0);
  });
  ipcMain.on("fail", (_e, message) => {
    console.error("bench failed:", message);
    app.exit(1);
  });
  const query = new URLSearchParams({
    image: require("url").pathToFileURL(path.resolve(image)).href,
    root: require("url").pathToFileURL(root).href,
    delegate,
    seconds,
    fps
  });
  await win.loadFile(path.join(__dirname, "bench.html"), { search: query.toString() });
});
