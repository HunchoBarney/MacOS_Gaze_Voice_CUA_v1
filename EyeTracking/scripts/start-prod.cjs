// Production launch without pnpm — the host (Jarvis) spawns this
// directly, so nothing here may depend on the package manager being on
// PATH. `pnpm build` must have already produced dist/.
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const args = process.argv.slice(2);
const binSuffix = process.platform === "win32" ? ".cmd" : "";
const electronBin = path.join(repoRoot, "node_modules", ".bin", `electron${binSuffix}`);
const indexHtml = path.join(repoRoot, "dist", "index.html");

if (!fs.existsSync(indexHtml)) {
  console.error("dist/index.html is missing — run `pnpm build` first; production mode loads the bundled renderer.");
  process.exit(1);
}

let electron = null;
let shuttingDown = false;

function electronIsRunning() {
  return Boolean(electron) && electron.exitCode === null && electron.signalCode === null;
}

// Same process-tree ownership as dev.cjs: a signal lands on this wrapper's
// pid, so it must reap Electron itself or the orphan keeps the camera and
// the external API port. SIGTERM first so before-quit teardown runs,
// SIGKILL after ~2s, and the wrapper's exit code stays 128+signum.
function shutdown(signal) {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  if (electronIsRunning()) {
    electron.kill("SIGTERM");
    setTimeout(() => {
      if (electronIsRunning()) {
        electron.kill("SIGKILL");
      }
    }, 2000).unref();
  }
  const exitCode = 128 + (os.constants.signals[signal] ?? 1);
  if (!electronIsRunning()) {
    process.exit(exitCode);
    return;
  }
  electron.once("exit", () => process.exit(exitCode));
  setTimeout(() => process.exit(exitCode), 2500).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGHUP", () => shutdown("SIGHUP"));

// main.cjs treats the mere presence of VITE_DEV_SERVER_URL as dev mode —
// delete it rather than empty-string it. Same for ELECTRON_RUN_AS_NODE: a
// leaked value runs main.cjs under plain node and the app dies instantly.
const env = { ...process.env, NODE_ENV: "production" };
delete env.VITE_DEV_SERVER_URL;
delete env.ELECTRON_RUN_AS_NODE;
delete env.ELECTRON_OVERRIDE_DIST_PATH;

electron = spawn(electronBin, [".", ...args], {
  cwd: repoRoot,
  stdio: "inherit",
  shell: process.platform === "win32",
  env
});

electron.on("error", (error) => {
  console.error(`Failed to start Electron: ${error.message}`);
  process.exit(1);
});

electron.on("exit", (code, signal) => {
  if (shuttingDown) {
    return;
  }
  // A signal death is not exit 0 — SIGABRT crash-loops must stay visible.
  process.exit(code ?? (signal ? 128 + (os.constants.signals[signal] ?? 1) : 0));
});
