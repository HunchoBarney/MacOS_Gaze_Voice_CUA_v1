import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const devScript = path.join(repoRoot, "scripts", "dev.cjs");

// dev.cjs hard-codes the vite binary to <repo>/node_modules/.bin/vite — there
// is no env override — so tests that need a "vite" to answer on the dev port
// inject this shim through NODE_OPTIONS: any spawn whose argv[0] mentions
// vite is swapped for a bare `node -e` http server bound to the requested
// --port. dev.cjs itself runs unmodified; Electron is faked via the
// supported GAZE_ELECTRON_BIN seam — no real vite, no real Electron, no
// camera.
const SPAWN_SHIM = `"use strict";
const cp = require("child_process");
const realSpawn = cp.spawn;
cp.spawn = function patchedSpawn(command, args, options) {
  if (String(command).includes("vite")) {
    const list = Array.isArray(args) ? args : [];
    const index = list.indexOf("--port");
    const port = index >= 0 ? Number(list[index + 1]) : 5173;
    const script =
      "require('http').createServer((req,res)=>{" +
      "res.setHeader('content-type','text/html');" +
      "res.end('<html>vite dev server</html>');" +
      "}).listen(" + port + ",'127.0.0.1')";
    return realSpawn.call(this, process.execPath, ["-e", script], options);
  }
  return realSpawn.apply(this, arguments);
};
`;

let workDir;
let shimPath;
let cleanElectron;
let failingElectron;
let suicideElectron;
let sleeperElectron;
let envDumpElectron;
let envDumpPath;
let envProbeElectron;
let envProbePath;

beforeAll(() => {
  workDir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-dev-test-"));
  shimPath = path.join(workDir, "spawn-shim.cjs");
  fs.writeFileSync(shimPath, SPAWN_SHIM);
  cleanElectron = path.join(workDir, "clean-electron.sh");
  fs.writeFileSync(cleanElectron, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  // Distinctive code — proves the wrapper propagates it, not just nonzero.
  failingElectron = path.join(workDir, "failing-electron.sh");
  fs.writeFileSync(failingElectron, "#!/bin/sh\nexit 7\n", { mode: 0o755 });
  // Dies of its own SIGTERM — the honest-signal path in the electron
  // "exit" handler must surface 128+15, not a fake-clean 0.
  suicideElectron = path.join(workDir, "suicide-electron.sh");
  fs.writeFileSync(suicideElectron, "#!/bin/sh\nkill -TERM $$\n", { mode: 0o755 });
  // Sleeps until reaped — the SIGTERM-to-wrapper path must terminate it.
  sleeperElectron = path.join(workDir, "sleeper-electron.sh");
  fs.writeFileSync(sleeperElectron, "#!/bin/sh\nexec sleep 300\n", { mode: 0o755 });
  // Records the dev-server URL the wrapper hands Electron.
  envDumpPath = path.join(workDir, "electron-env.txt");
  envDumpElectron = path.join(workDir, "env-dump-electron.sh");
  fs.writeFileSync(
    envDumpElectron,
    `#!/bin/sh\nprintf '%s' "$VITE_DEV_SERVER_URL" > "${envDumpPath}"\nexit 0\n`,
    { mode: 0o755 }
  );
  // Records whether ELECTRON_RUN_AS_NODE survived into the Electron env —
  // a leaked switch boots the binary as plain node and the tracker never
  // opens.
  envProbePath = path.join(workDir, "electron-probe.txt");
  envProbeElectron = path.join(workDir, "env-probe-electron.sh");
  fs.writeFileSync(
    envProbeElectron,
    `#!/bin/sh\nprintf '%s' "\${ELECTRON_RUN_AS_NODE-<unset>}" > "${envProbePath}"\nexit 0\n`,
    { mode: 0o755 }
  );
});

afterAll(() => {
  fs.rmSync(workDir, { recursive: true, force: true });
});

function startDev(env = {}) {
  const child = spawn(process.execPath, [devScript], {
    cwd: repoRoot,
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const done = new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
  return { child, done };
}

function occupyPort(body) {
  const server = http.createServer((_request, response) => {
    response.end(body);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

function freePort() {
  const probe = net.createServer();
  return new Promise((resolve, reject) => {
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

async function waitForHttp(url, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const response = await fetch(url);
      await response.arrayBuffer();
      return;
    } catch (error) {
      if (Date.now() > deadline) {
        throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
}

const shimEnv = () => ({ NODE_OPTIONS: `--require ${shimPath}` });

describe("scripts/dev.cjs port handling", () => {
  it("exits 1 when a foreign process holds the dev-server port", async () => {
    const { server, port } = await occupyPort("hello, not vite");
    try {
      const { done } = startDev({ CONDUCTOR_PORT: String(port) });
      const result = await done;
      expect(result.code).toBe(1);
      expect(result.stderr).toContain("does not answer as a Vite dev server");
      expect(result.stderr).toContain("a foreign process holds the port");
    } finally {
      server.close();
    }
  }, 20000);

  it("exits 1 naming a leftover pnpm dev when the port serves vite", async () => {
    const { server, port } = await occupyPort('<script type="module" src="/@vite/client"></script>');
    try {
      const { done } = startDev({ CONDUCTOR_PORT: String(port) });
      const result = await done;
      expect(result.code).toBe(1);
      expect(result.stderr).toContain("already serves a Vite dev server");
      expect(result.stderr).toContain("pnpm dev");
    } finally {
      server.close();
    }
  }, 20000);
});

describe("scripts/dev.cjs process lifecycle", () => {
  it("exits cleanly when electron exits 0", async () => {
    const port = await freePort();
    const { done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: cleanElectron
    });
    const result = await done;
    expect(result.stderr).not.toContain("Vite exited before Electron started");
    expect(result.code).toBe(0);
  }, 20000);

  it("propagates electron's nonzero exit code verbatim", async () => {
    const port = await freePort();
    const { done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: failingElectron
    });
    const result = await done;
    expect(result.code).toBe(7);
  }, 20000);

  it("reports electron signal deaths honestly — SIGTERM reads 143, not 0", async () => {
    const port = await freePort();
    const { done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: suicideElectron
    });
    const result = await done;
    expect(result.code).toBe(143);
  }, 20000);

  it("hands Electron the dev-server URL through VITE_DEV_SERVER_URL", async () => {
    const port = await freePort();
    const { done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: envDumpElectron
    });
    const result = await done;
    expect(result.code).toBe(0);
    expect(fs.readFileSync(envDumpPath, "utf8")).toBe(`http://127.0.0.1:${port}`);
  }, 20000);

  it("scrubs ELECTRON_RUN_AS_NODE out of the Electron environment", async () => {
    const port = await freePort();
    const { done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: envProbeElectron,
      ELECTRON_RUN_AS_NODE: "1"
    });
    const result = await done;
    expect(result.code).toBe(0);
    expect(fs.readFileSync(envProbePath, "utf8")).toBe("<unset>");
  }, 20000);

  it("SIGTERM to the wrapper reaps the tree and exits 143", async () => {
    const port = await freePort();
    const { child, done } = startDev({
      ...shimEnv(),
      CONDUCTOR_PORT: String(port),
      GAZE_ELECTRON_BIN: sleeperElectron
    });
    // Once the fake vite answers, the electron spawn lands on the same
    // tick — then the wrapper owns two live children to reap.
    await waitForHttp(`http://127.0.0.1:${port}`);
    child.kill("SIGTERM");
    const result = await done;
    expect(result.code).toBe(143);
  }, 20000);
});
