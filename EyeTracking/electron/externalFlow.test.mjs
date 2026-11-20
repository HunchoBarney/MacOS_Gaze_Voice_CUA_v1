import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const { CONTROL_ACTIONS, startExternalApiServer } = require("./externalApi.cjs");
const { GazeStateStore, SCHEMA_VERSION, mergeSettings, parseSettingsPayload } = require("./externalStore.cjs");

// Real-flow coverage: externalStore.test.mjs exercises the request handler
// through createRequestHandler; these tests go through startExternalApiServer
// — the factory main.cjs's maybeStartExternalApi wires (main.cjs:409-426) —
// over real HTTP/WebSocket, plus the settings.json write protocol the
// set-settings IPC and tray menu share.

const silentLogger = { log: () => undefined, error: () => undefined };

function liveStore(readCalibrationFile = () => null) {
  // Real wall-clock stamps — /ready windows gaze.updated_at against
  // Date.now(), so a frozen now() would read as a wedged pipeline.
  return new GazeStateStore({
    now: () => new Date().toISOString(),
    readCalibrationFile
  });
}

// The boot payload main.cjs builds for store.initialize (main.cjs:880-900),
// trimmed to the fields the snapshot slices expose.
function initializeTracker(store, { calibrationFile = "/nonexistent/.gaze_calibration.json" } = {}) {
  store.initialize({
    runtime: "onnxweb",
    displayIndex: 0,
    requestedDisplayIndex: 0,
    displayCount: 1,
    displayBounds: { x: 0, y: 0, width: 1920, height: 1080 },
    invalidDisplay: false,
    webInference: {
      runtime: "onnxweb",
      camera: "0",
      cameraResolutionName: "VGA",
      cameraWidth: 640,
      cameraHeight: 480,
      cameraFov: 90,
      displaySizeInch: 24,
      calibrationFile,
      eyePositionWeightX: 1,
      eyePositionWeightY: 0.25
    }
  });
  return store;
}

// What the renderer reports once both ONNX sessions are up — a status
// message carries the model/provider fields mergeModelsFromStatus reads.
function reportModelsLoaded(store) {
  store.updateFromBackendMessage({
    type: "status",
    level: "info",
    message: "Models loaded",
    runtime: "onnxweb",
    detector: "retinaface",
    detector_model: "retinaface.onnx",
    detector_providers: ["CoreMLExecutionProvider"],
    gaze_providers: ["CPUExecutionProvider"]
  });
}

// The per-launch API token every request below carries, as Jarvis's
// clients do.
const TOKEN = "f".repeat(64);
const AUTH = { authorization: `Bearer ${TOKEN}` };

async function startApi(options) {
  const api = startExternalApiServer({
    host: "127.0.0.1",
    port: 0,
    logger: silentLogger,
    token: TOKEN,
    ...options
  });
  await new Promise((resolve, reject) => {
    if (api.server.listening) {
      resolve();
      return;
    }
    api.server.once("listening", resolve);
    api.server.once("error", reject);
  });
  const { port } = api.server.address();
  return { api, base: `http://127.0.0.1:${port}`, wsBase: `ws://127.0.0.1:${port}` };
}

async function request(base, pathname, { method = "GET", headers, body, rawBody } = {}) {
  const response = await fetch(`${base}${pathname}`, {
    method,
    headers: { ...AUTH, ...headers },
    body: rawBody !== undefined ? rawBody : body !== undefined ? JSON.stringify(body) : undefined
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: response.status, body: parsed };
}

const get = (base, pathname) => request(base, pathname);
const post = (base, pathname, body, headers) => request(base, pathname, { method: "POST", body, headers });

// Mirror of the settings write path in main.cjs — persistSettingsPatch
// (main.cjs:571-588) over writeJsonFileAtomic (main.cjs:1114-1133). main.cjs
// is not requireable (top-level electron imports, no module.exports), so the
// file protocol is reproduced verbatim: a promise-chain mutex serializes
// read→merge→write per settings file, each write lands via a sibling .tmp +
// rename, and the merged result publishes into the store's settings slice.
// The primitives it is built from — mergeSettings, parseSettingsPayload,
// store.updateSharedState — are the real exported ones. If main.cjs's
// private copy of this algorithm changes, this mirror must change with it.
function createSettingsWriter(settingsPath, store) {
  let settingsWriteQueue = Promise.resolve();
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

  async function readSettingsFile() {
    try {
      return parseSettingsPayload(await fs.promises.readFile(settingsPath, "utf8"));
    } catch {
      return {};
    }
  }

  // Unlike main.cjs's version, the returned promise is the pre-catch write —
  // tests want a failing write to surface here rather than via console.error;
  // the queue itself still self-heals through the leading .catch, matching
  // the production chain.
  function persistSettingsPatch(patch) {
    settingsWriteQueue = settingsWriteQueue
      .catch(() => {})
      .then(async () => {
        const merged = mergeSettings(await readSettingsFile(), patch);
        if (merged.version === undefined) {
          merged.version = 1;
        }
        await writeJsonFileAtomic(settingsPath, merged);
        store.updateSharedState({ settings: merged });
      });
    return settingsWriteQueue;
  }

  return { persistSettingsPatch, readSettingsFile };
}

// A connected /events client whose frames arrive as an ordered async queue.
function openEventsSocket(wsBase) {
  const socket = new WebSocket(`${wsBase}/events`, { headers: AUTH });
  const buffered = [];
  const waiters = [];
  socket.on("message", (data) => {
    const message = JSON.parse(data.toString());
    if (waiters.length > 0) {
      waiters.shift()(message);
    } else {
      buffered.push(message);
    }
  });
  const opened = new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("unexpected-response", (_request, response) => {
      reject(new Error(`upgrade rejected: ${response.statusCode}`));
    });
    socket.once("error", reject);
  });
  const next = () =>
    new Promise((resolve, reject) => {
      if (buffered.length > 0) {
        resolve(buffered.shift());
        return;
      }
      const timer = setTimeout(() => reject(new Error("timed out waiting for ws message")), 4000);
      waiters.push((message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  const closed = new Promise((resolve) => socket.once("close", resolve));
  return { socket, opened, next, closed };
}

describe("POST /control end-to-end", () => {
  it("delivers every non-lifecycle action to the injected onControl over a real socket", async () => {
    const calls = [];
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: (action, value) => calls.push([action, value])
    });
    try {
      for (const action of CONTROL_ACTIONS) {
        // quit never routes through onControl — it is the lifecycle action
        // handled API-side via onQuit (dedicated test below).
        if (action === "quit") {
          continue;
        }
        // The two actions whose values are validated at the wire get their
        // documented shapes; the rest take an opaque payload through.
        const value =
          action === "implicit_sample"
            ? { x_norm: 0.5, y_norm: 0.25 }
            : action === "set_paused"
              ? true
              : { scale: 1.25 };
        const result = await post(base, "/control", { action, value });
        expect(result).toEqual({ status: 200, body: { ok: true } });
        expect(calls.at(-1)).toEqual([action, value]);
      }
      expect(calls.map(([action]) => action)).toEqual(
        [...CONTROL_ACTIONS].filter((action) => action !== "quit")
      );
    } finally {
      api.close();
    }
  });

  it("answers 400 unknown_action for actions outside the enum — without touching onControl", async () => {
    const calls = [];
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: (action, value) => calls.push([action, value])
    });
    try {
      for (const body of [
        { action: "launch_missiles" },
        { action: 42 },
        { value: 1 },
        "pause_toggle",
        null
      ]) {
        await expect(post(base, "/control", body)).resolves.toEqual({
          status: 400,
          body: { error: "unknown_action" }
        });
      }
      expect(calls).toHaveLength(0);
    } finally {
      api.close();
    }
  });

  it("answers 400 for a non-JSON body and 413 once the body passes the 64KiB cap", async () => {
    const calls = [];
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: (action, value) => calls.push([action, value])
    });
    try {
      await expect(
        request(base, "/control", { method: "POST", rawBody: "{not json" })
      ).resolves.toEqual({ status: 400, body: { error: "invalid_json" } });

      // Just under the cap parses fine — the limit counts bytes received,
      // not the Content-Length header.
      const under = JSON.stringify({ action: "pause_toggle", pad: "x".repeat(64 * 1024 - 100) });
      expect(Buffer.byteLength(under)).toBeLessThanOrEqual(64 * 1024);
      await expect(
        request(base, "/control", { method: "POST", rawBody: under })
      ).resolves.toEqual({ status: 200, body: { ok: true } });
      expect(calls).toEqual([["pause_toggle", undefined]]);

      // Over the cap: the server must answer 413 payload_too_large, not RST
      // the socket mid-upload — the client has to see the JSON error.
      const over = "x".repeat(64 * 1024 + 1);
      await expect(
        request(base, "/control", { method: "POST", rawBody: over })
      ).resolves.toEqual({ status: 413, body: { error: "payload_too_large" } });
      expect(calls).toHaveLength(1);
    } finally {
      api.close();
    }
  });

  it("answers 403 for browser-origin posts before the body is even read", async () => {
    const calls = [];
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: (action, value) => calls.push([action, value])
    });
    try {
      // Any Origin header marks a browser context — even a syntactically
      // valid action with a valid body is refused.
      for (const origin of ["https://untrusted.example", "http://127.0.0.1:5173", "null"]) {
        await expect(
          post(base, "/control", { action: "pause_toggle" }, { origin })
        ).resolves.toEqual({ status: 403, body: { error: "forbidden" } });
      }
      expect(calls).toHaveLength(0);
    } finally {
      api.close();
    }
  });

  it("keeps /control POST-only and every read endpoint GET-only", async () => {
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: () => {}
    });
    try {
      for (const method of ["GET", "PUT", "DELETE"]) {
        const result = await request(base, "/control", { method });
        expect(result).toEqual({ status: 405, body: { error: "method_not_allowed" } });
      }
      for (const pathname of ["/health", "/ready", "/snapshot", "/snapshot/paused", "/missing"]) {
        await expect(post(base, pathname, { action: "pause_toggle" })).resolves.toEqual({
          status: 405,
          body: { error: "method_not_allowed" }
        });
      }
      await expect(get(base, "/missing")).resolves.toEqual({
        status: 404,
        body: { error: "not_found" }
      });
    } finally {
      api.close();
    }
  });

  it("quit acknowledges 202 and defers onQuit off the request path — onControl never sees it", async () => {
    const calls = [];
    let quitFired = false;
    let resolveQuit;
    const quitPromise = new Promise((resolve) => {
      resolveQuit = resolve;
    });
    const { api, base } = await startApi({
      store: initializeTracker(liveStore()),
      onControl: (action, value) => calls.push([action, value]),
      onQuit: () => {
        quitFired = true;
        resolveQuit();
      }
    });
    try {
      await expect(post(base, "/control", { action: "quit" })).resolves.toEqual({
        status: 202,
        body: { ok: true }
      });
      // The 202 reached the wire before teardown — onQuit fires on a later
      // tick, exactly as the API documents for app.quit().
      await quitPromise;
      expect(quitFired).toBe(true);
      expect(calls).toHaveLength(0);
    } finally {
      api.close();
    }
  });
});

describe("snapshot slices track live store updates", () => {
  it("every slice endpoint serves the latest store state", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-slices-"));
    const calibrationFile = path.join(dir, ".gaze_calibration.json");
    const store = initializeTracker(liveStore(), { calibrationFile });
    const { api, base } = await startApi({ store });
    try {
      // Freshly initialized: shared slices at their boot values.
      await expect(get(base, "/snapshot/paused")).resolves.toEqual({ status: 200, body: false });
      await expect(get(base, "/snapshot/status")).resolves.toEqual({ status: 200, body: null });
      await expect(get(base, "/snapshot/settings")).resolves.toEqual({ status: 200, body: null });

      // Drive the store the way the real pipeline does — backend messages
      // plus the renderer's shared-state reports.
      reportModelsLoaded(store);
      store.updateFromBackendMessage({ type: "gaze", x_norm: 0.25, y_norm: 0.75, confidence: 0.9 });
      store.updateFromBackendMessage({ type: "calibration", status: "saved", count: 5, path: calibrationFile });
      store.updateSharedState({
        paused: true,
        calibration_status: "loaded",
        settings: { dwell_lock: true }
      });

      await expect(get(base, "/snapshot/status")).resolves.toEqual({
        status: 200,
        body: { level: "info", message: "Models loaded", updated_at: expect.any(String) }
      });
      await expect(get(base, "/snapshot/paused")).resolves.toEqual({ status: 200, body: true });
      await expect(get(base, "/snapshot/calibration_status")).resolves.toEqual({
        status: 200,
        body: "loaded"
      });
      await expect(get(base, "/snapshot/settings")).resolves.toEqual({
        status: 200,
        body: { dwell_lock: true }
      });
      // The gaze slice carries normalized + display-pixel coordinates.
      const gaze = await get(base, "/snapshot/gaze");
      expect(gaze.status).toBe(200);
      expect(gaze.body).toMatchObject({ x_norm: 0.25, y_norm: 0.75, x_px: 480, y_px: 810 });
      const calibration = await get(base, "/snapshot/calibration");
      expect(calibration.status).toBe(200);
      expect(calibration.body).toMatchObject({
        path: calibrationFile,
        status: "saved",
        count: 5,
        saved_path: calibrationFile
      });
      // The full snapshot stays consistent with every slice in one read.
      const snapshot = await get(base, "/snapshot");
      expect(snapshot.status).toBe(200);
      expect(snapshot.body.schema_version).toBe(SCHEMA_VERSION);
      expect(snapshot.body.paused).toBe(true);
      expect(snapshot.body.gaze).toMatchObject({ x_norm: 0.25, y_norm: 0.75 });
      expect(snapshot.body.settings).toEqual({ dwell_lock: true });
    } finally {
      api.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("paths outside the slice allowlist 404 — including real snapshot keys that aren't slices", async () => {
    const store = initializeTracker(liveStore());
    const { api, base } = await startApi({ store });
    try {
      await expect(get(base, "/snapshot/bogus")).resolves.toEqual({
        status: 404,
        body: { error: "not_found" }
      });
      // These are real snapshot fields but not SNAPSHOT_SLICES members —
      // the allowlist, not the state shape, is the routing boundary.
      for (const key of ["preview", "schema_version", "started_at", "updated_at"]) {
        await expect(get(base, `/snapshot/${key}`)).resolves.toEqual({
          status: 404,
          body: { error: "not_found" }
        });
      }
      // The slice regex is lowercase-only — no case smuggling.
      await expect(get(base, "/snapshot/PAUSED")).resolves.toEqual({
        status: 404,
        body: { error: "not_found" }
      });
    } finally {
      api.close();
    }
  });
});

describe("settings.json persistence flow", () => {
  it("a set-settings merge lands atomically, seeds version, and publishes the settings slice", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-settings-"));
    const settingsPath = path.join(dir, "settings.json");
    const store = liveStore();
    const writer = createSettingsWriter(settingsPath, store);
    try {
      // First write on a missing file — the tray menu path.
      await writer.persistSettingsPatch({ dot_scale: 1.25, diagnostics: { preview: true } });
      expect(fs.existsSync(settingsPath)).toBe(true);
      expect(fs.existsSync(`${settingsPath}.tmp`)).toBe(false);
      const first = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
      expect(first).toEqual({ version: 1, dot_scale: 1.25, diagnostics: { preview: true } });
      expect(store.getSlice("settings")).toEqual(first);

      // A renderer set-settings merge: nested objects merge key-by-key,
      // siblings survive — preview:true must not be clobbered.
      await writer.persistSettingsPatch({ diagnostics: { status: true }, dwell_lock: true });
      const merged = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
      expect(merged).toEqual({
        version: 1,
        dot_scale: 1.25,
        dwell_lock: true,
        diagnostics: { preview: true, status: true }
      });
      expect(store.getSlice("settings")).toEqual(merged);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a crash between tmp write and rename leaves the last good file readable", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-crash-"));
    const settingsPath = path.join(dir, "settings.json");
    const store = liveStore();
    const writer = createSettingsWriter(settingsPath, store);
    try {
      await writer.persistSettingsPatch({ dot_scale: 1.0, version: 1 });

      // The exact state a SIGKILL between writeFile(tmp) and rename leaves:
      // an orphaned, possibly truncated sibling tmp; the target untouched.
      fs.writeFileSync(`${settingsPath}.tmp`, '{"dwell_lock":', "utf8");

      // Reads see the committed value — the tmp is never a read path.
      expect(await writer.readSettingsFile()).toEqual({ dot_scale: 1.0, version: 1 });
      expect(JSON.parse(fs.readFileSync(settingsPath, "utf8"))).toEqual({ dot_scale: 1.0, version: 1 });

      // The next write recovers cleanly — writeFile truncates the stale tmp
      // before rename, so no manual cleanup is needed.
      await writer.persistSettingsPatch({ gaze_dot_visible: true });
      expect(JSON.parse(fs.readFileSync(settingsPath, "utf8"))).toEqual({
        version: 1,
        dot_scale: 1.0,
        gaze_dot_visible: true
      });
      expect(fs.existsSync(`${settingsPath}.tmp`)).toBe(false);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a corrupt settings.json reads as empty and the next merge starts fresh", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-corrupt-"));
    const settingsPath = path.join(dir, "settings.json");
    const store = liveStore();
    const writer = createSettingsWriter(settingsPath, store);
    try {
      fs.writeFileSync(settingsPath, "{truncated mid-write", "utf8");
      // Corrupt is a normal state (truncated write on an older crash) —
      // reads get {}, the next write carries only its own patch + version.
      expect(await writer.readSettingsFile()).toEqual({});
      await writer.persistSettingsPatch({ dwell_lock: true });
      expect(JSON.parse(fs.readFileSync(settingsPath, "utf8"))).toEqual({
        version: 1,
        dwell_lock: true
      });
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("serializes concurrent writes — every patch lands, last wins, the file is never torn", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-concurrent-"));
    const settingsPath = path.join(dir, "settings.json");
    const store = liveStore();
    const writer = createSettingsWriter(settingsPath, store);
    try {
      const N = 25;
      // Mid-flight integrity watch: a torn write would leave unparseable
      // JSON at the target path. ENOENT is fine (first write not landed
      // yet); anything else is corruption.
      const tornReads = [];
      let watching = true;
      const watcher = (async () => {
        while (watching) {
          try {
            JSON.parse(await fs.promises.readFile(settingsPath, "utf8"));
          } catch (error) {
            if (!error || error.code !== "ENOENT") {
              tornReads.push(String(error));
            }
          }
          await new Promise((resolve) => setImmediate(resolve));
        }
      })();

      // Tray clicks and renderer set-settings share the one queue — fire
      // them all at once like a user scrubbing the menu.
      await Promise.all(
        Array.from({ length: N }, (_, i) =>
          writer.persistSettingsPatch({ [`key_${i}`]: i, shared_counter: i })
        )
      );
      watching = false;
      await watcher;

      expect(tornReads).toEqual([]);
      const final = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
      for (let i = 0; i < N; i += 1) {
        expect(final[`key_${i}`]).toBe(i);
      }
      // Serialized read-modify-write: call order is commit order, so the
      // last fired patch owns the shared key.
      expect(final.shared_counter).toBe(N - 1);
      expect(final.version).toBe(1);
      expect(store.getSlice("settings")).toEqual(final);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("WS /events real client", () => {
  it("sends the connect snapshot, then an update frame per store mutation — to every client", async () => {
    const store = initializeTracker(liveStore());
    const { api, wsBase } = await startApi({ store });
    const clientA = openEventsSocket(wsBase);
    const clientB = openEventsSocket(wsBase);
    try {
      await Promise.all([clientA.opened, clientB.opened]);

      // Both clients get the handshake snapshot first.
      for (const client of [clientA, clientB]) {
        const handshake = await client.next();
        expect(handshake.type).toBe("snapshot");
        expect(handshake.snapshot.schema_version).toBe(SCHEMA_VERSION);
        expect(handshake.snapshot.paused).toBe(false);
      }

      // One mutation, one update frame, every subscriber — this is the
      // host's wedge-watch feed.
      store.updateSharedState({ paused: true });
      for (const client of [clientA, clientB]) {
        const event = await client.next();
        expect(event.type).toBe("update");
        expect(event.changed).toEqual(["paused"]);
        expect(event.snapshot.paused).toBe(true);
      }

      store.updateFromBackendMessage({ type: "gaze", x_norm: 0.5, y_norm: 0.5, confidence: 0.9 });
      const gazeEvent = await clientA.next();
      expect(gazeEvent.type).toBe("update");
      expect(gazeEvent.changed).toEqual(["gaze"]);
      expect(gazeEvent.snapshot.gaze).toMatchObject({ x_norm: 0.5, y_norm: 0.5 });
    } finally {
      clientA.socket.close();
      clientB.socket.close();
      await Promise.all([clientA.closed, clientB.closed]);
      api.close();
    }
  });
});

describe("realistic session sequence", () => {
  it("boot → health → readiness → pause → resume → settings → restart keeps settings", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-flow-session-"));
    const settingsPath = path.join(dir, "settings.json");
    const calibrationFile = path.join(dir, ".gaze_calibration.json");
    const store = liveStore();
    const writer = createSettingsWriter(settingsPath, store);
    const calls = [];
    let firstBoot;
    const { api, base } = await startApi({
      store,
      onControl: (action, value) => calls.push([action, value])
    });
    try {
      // The host's probe order: liveness first, then readiness gating on
      // the pipeline actually producing.
      const health = await get(base, "/health");
      expect(health.status).toBe(200);
      expect(health.body).toMatchObject({ ok: true, schema_version: SCHEMA_VERSION });
      firstBoot = health.body.started_at;

      await expect(get(base, "/ready")).resolves.toEqual({
        status: 503,
        body: { ready: false, reason: "runtime_not_started" }
      });

      initializeTracker(store, { calibrationFile });
      await expect(get(base, "/ready")).resolves.toEqual({
        status: 503,
        body: { ready: false, reason: "models_not_loaded" }
      });

      reportModelsLoaded(store);
      await expect(get(base, "/ready")).resolves.toEqual({
        status: 503,
        body: { ready: false, reason: "no_recent_gaze" }
      });

      store.updateFromBackendMessage({ type: "gaze", x_norm: 0.5, y_norm: 0.5, confidence: 0.9 });
      await expect(get(base, "/ready")).resolves.toEqual({ status: 200, body: { ready: true } });

      // Host asks for a pause (menu-style toggle); the renderer applies it
      // and confirms via the set-paused/report-state path.
      await expect(post(base, "/control", { action: "pause_toggle" })).resolves.toEqual({
        status: 200,
        body: { ok: true }
      });
      expect(calls.at(-1)).toEqual(["pause_toggle", undefined]);
      store.updateSharedState({ paused: true });
      await expect(get(base, "/snapshot/paused")).resolves.toEqual({ status: 200, body: true });
      // Intentional silence still reads ready — the tracker isn't wedged.
      await expect(get(base, "/ready")).resolves.toEqual({ status: 200, body: { ready: true } });

      // Screen-lock style resume: the host posts the target state.
      await expect(post(base, "/control", { action: "set_paused", value: false })).resolves.toEqual({
        status: 200,
        body: { ok: true }
      });
      expect(calls.at(-1)).toEqual(["set_paused", false]);
      store.updateSharedState({ paused: false });
      await expect(get(base, "/snapshot/paused")).resolves.toEqual({ status: 200, body: false });

      // User flips settings mid-session; the slice reflects the write.
      await writer.persistSettingsPatch({ dwell_lock: true, diagnostics: { status: true } });
      await expect(get(base, "/snapshot/settings")).resolves.toEqual({
        status: 200,
        body: { version: 1, dwell_lock: true, diagnostics: { status: true } }
      });
      expect(calls).toEqual([
        ["pause_toggle", undefined],
        ["set_paused", false]
      ]);
    } finally {
      api.close();
    }

    // Restart-equivalent: a brand-new store + server against the same
    // settings.json — the boot seeding main.cjs does at 903-908.
    const restartedStore = liveStore();
    initializeTracker(restartedStore, { calibrationFile });
    restartedStore.updateSharedState({
      settings: parseSettingsPayload(fs.readFileSync(settingsPath, "utf8"))
    });
    const restarted = await startApi({ store: restartedStore });
    try {
      await expect(get(restarted.base, "/snapshot/settings")).resolves.toEqual({
        status: 200,
        body: { version: 1, dwell_lock: true, diagnostics: { status: true } }
      });
      const health = await get(restarted.base, "/health");
      expect(health.status).toBe(200);
      expect(health.body.ok).toBe(true);
      // A genuinely new process-side boot — not the old snapshot.
      expect(Date.parse(health.body.started_at)).toBeGreaterThanOrEqual(Date.parse(firstBoot));
    } finally {
      restarted.api.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
