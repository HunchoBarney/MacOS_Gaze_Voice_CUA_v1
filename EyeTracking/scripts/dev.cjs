const { spawn } = require("child_process");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const args = process.argv.slice(2);
const binSuffix = process.platform === "win32" ? ".cmd" : "";
const viteBin = path.join(repoRoot, "node_modules", ".bin", `vite${binSuffix}`);
const electronBin = process.env.GAZE_ELECTRON_BIN || path.join(repoRoot, "node_modules", ".bin", `electron${binSuffix}`);
const requestedPort = Number.parseInt(process.env.CONDUCTOR_PORT || "5173", 10);
const devServerPort = requestedPort > 0 && requestedPort <= 65535 ? requestedPort : 5173;
const devServerUrl = `http://127.0.0.1:${devServerPort}`;
const useShell = process.platform === "win32";

let vite = null;
// Module-scoped (not local to startElectron) so the signal handlers can
// reap it — the host kills this wrapper's pid, and an orphaned Electron
// holding the camera + port 5173 is the crash-loop this file exists to end.
let electron = null;
let electronStarted = false;
let shuttingDown = false;

function isPortAvailable(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => {
      server.close(() => resolve(true));
    });
    server.listen(port, "127.0.0.1");
  });
}

// GET whatever owns the port once. Our own leftover dev server serves
// index.html referencing /@vite/client; a foreign process squatting on the
// port does not. Both cases exit 1 — this only decides which story the
// error message tells.
function portServesVite() {
  return new Promise((resolve) => {
    const request = http.get(devServerUrl, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        body += chunk;
        if (body.length > 64 * 1024) {
          request.destroy();
        }
      });
      response.on("end", () => resolve(body.includes("/@vite/client")));
      response.on("error", () => resolve(false));
    });
    request.on("error", () => resolve(false));
    request.setTimeout(2000, () => {
      request.destroy();
      resolve(false);
    });
  });
}

function waitForVite(attempt = 0) {
  const request = http.get(devServerUrl, (response) => {
    response.resume();
    startElectron();
  });
  request.on("error", () => {
    if (attempt > 120) {
      console.error("Vite dev server did not start.");
      vite?.kill();
      process.exit(1);
      return;
    }
    setTimeout(() => waitForVite(attempt + 1), 250);
  });
}

function childIsRunning(child) {
  return Boolean(child) && child.exitCode === null && child.signalCode === null;
}

function startElectron() {
  if (electronStarted) {
    return;
  }
  electronStarted = true;
  const electronArgs = process.env.GAZE_ELECTRON_BIN ? [repoRoot, ...args] : [".", ...args];
  // Scrub inherited Electron switches: an ELECTRON_RUN_AS_NODE left in the
  // parent env (e.g. launched from a node-dispatching shell) makes the
  // binary boot as plain node — the tracker never opens and the failure
  // reads as a missing camera. start-prod.cjs does the same.
  const childEnv = { ...process.env, VITE_DEV_SERVER_URL: devServerUrl };
  delete childEnv.ELECTRON_RUN_AS_NODE;
  electron = spawn(electronBin, electronArgs, {
    cwd: repoRoot,
    stdio: "inherit",
    shell: useShell,
    env: childEnv
  });
  electron.on("error", (error) => {
    console.error(`Failed to start Electron: ${error.message}`);
    vite?.kill();
    process.exit(1);
  });
  electron.on("exit", (code, signal) => {
    vite?.kill();
    // shutdown() owns the exit code while a signal is in flight — otherwise
    // the reaped child would overwrite 130/143 with its own 143.
    if (shuttingDown) {
      return;
    }
    // Report signal deaths honestly — a SIGABRT crash-loop exiting as 0
    // reads as clean to whatever spawned us and loops forever.
    process.exit(code ?? (signal ? 128 + (os.constants.signals[signal] ?? 1) : 0));
  });
}

// Every termination signal lands on this wrapper (the host kills our pid;
// Ctrl-C hits the foreground process group), so each one must reap BOTH
// children. Electron gets ~2s to run before-quit teardown — calibration
// saves, API close — before SIGKILL. The hard 2.5s cap guarantees we exit
// even if the kill silently failed.
function shutdown(signal) {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  vite?.kill();
  if (childIsRunning(electron)) {
    electron.kill("SIGTERM");
    setTimeout(() => {
      if (childIsRunning(electron)) {
        electron.kill("SIGKILL");
      }
    }, 2000).unref();
  }
  const exitCode = 128 + (os.constants.signals[signal] ?? 1);
  if (!childIsRunning(electron)) {
    process.exit(exitCode);
    return;
  }
  electron.once("exit", () => process.exit(exitCode));
  setTimeout(() => process.exit(exitCode), 2500).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGHUP", () => shutdown("SIGHUP"));

async function main() {
  const available = await isPortAvailable(devServerPort);
  if (!available) {
    if (await portServesVite()) {
      console.error(
        `Port ${devServerPort} already serves a Vite dev server — a previous \`pnpm dev\` is probably still running. Stop it before restarting.`
      );
    } else {
      console.error(
        `Port ${devServerPort} is in use but ${devServerUrl} does not answer as a Vite dev server — a foreign process holds the port. Free it or set CONDUCTOR_PORT.`
      );
    }
    process.exit(1);
  }

  vite = spawn(viteBin, ["--host", "127.0.0.1", "--port", String(devServerPort), "--strictPort"], {
    cwd: repoRoot,
    stdio: "inherit",
    shell: useShell
  });

  vite.on("error", (error) => {
    console.error(`Failed to start Vite: ${error.message}`);
    process.exit(1);
  });

  vite.on("exit", (code) => {
    if (!electronStarted && !shuttingDown) {
      console.error(`Vite exited before Electron started: ${code}`);
      process.exit(code || 1);
    }
  });

  waitForVite();
}

main();
