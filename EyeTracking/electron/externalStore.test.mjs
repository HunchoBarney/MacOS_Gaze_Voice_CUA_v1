import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import WebSocket from "ws";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const { CONTROL_ACTIONS, createRequestHandler, startExternalApiServer } = require("./externalApi.cjs");
const { GazeStateStore, mergeSettings, parseSettingsPayload } = require("./externalStore.cjs");

function createStore() {
  return new GazeStateStore({
    startedAt: "2026-06-21T00:00:00.000Z",
    now: () => "2026-06-21T00:00:01.000Z",
    readCalibrationFile: () =>
      JSON.stringify({
        raw_projection: "unclipped-v1",
        affine: [
          [1, 0],
          [0, 1],
          [0, 0]
        ],
        source_bounds: {
          min: [0.1, 0.2],
          max: [0.8, 0.9],
          margin: 0.08
        },
        samples: [{ raw: [0.5, 0.5], target: [0.5, 0.5] }],
        validation: [{ raw: [0.3, 0.7], target: [0.31, 0.69], error: 0.014 }]
      })
  });
}

function initializeStore(store = createStore()) {
  store.initialize({
    runtime: "onnxweb",
    displayIndex: 1,
    requestedDisplayIndex: 1,
    displayCount: 2,
    displayBounds: { x: 100, y: 200, width: 1920, height: 1080 },
    invalidDisplay: false,
    cameraScreenX: 0.5,
    cameraScreenY: 0,
    webInference: {
      runtime: "onnxweb",
      camera: "0",
      cameraResolutionName: "VGA",
      cameraWidth: 640,
      cameraHeight: 480,
      cameraFov: 90,
      displaySizeInch: 31.5,
      calibrationFile: "/tmp/.gaze_calibration.json",
      eyePositionWeightX: 1,
      eyePositionWeightY: 0.25
    }
  });
  return store;
}

function requestJson(pathname, handler, options = {}) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(handler);
    server.listen(0, "127.0.0.1", async () => {
      try {
        const address = server.address();
        const response = await fetch(`http://127.0.0.1:${address.port}${pathname}`, {
          method: options.method || "GET",
          headers: options.headers,
          body: options.body === undefined ? undefined : JSON.stringify(options.body)
        });
        const body = await response.json();
        resolve({ status: response.status, body });
      } catch (error) {
        reject(error);
      } finally {
        server.close();
      }
    });
  });
}

function getJson(path, handler) {
  return requestJson(path, handler);
}

function waitForListening(server) {
  if (server.listening) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });
}

function websocketOutcome(url, options) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, options);
    socket.once("open", () => {
      socket.close();
      resolve({ type: "open" });
    });
    socket.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve({ type: "rejected", statusCode: response.statusCode });
    });
    socket.once("error", reject);
  });
}

describe("GazeStateStore", () => {
  it("does not present old clipped calibration as active", () => {
    const store = new GazeStateStore({
      startedAt: "2026-06-21T00:00:00.000Z",
      now: () => "2026-06-21T00:00:01.000Z",
      readCalibrationFile: () => JSON.stringify({ affine: [[1, 0], [0, 1], [0, 0]] })
    });
    const snapshot = initializeStore(store).getSnapshot();
    expect(snapshot.calibration.legacy_calibration).toBe(true);
    expect(snapshot.calibration.affine).toBeUndefined();
  });

  it("reads featuremap-v3 calibrations as current, exposing fit fields without raw bulk", () => {
    const store = new GazeStateStore({
      startedAt: "2026-06-21T00:00:00.000Z",
      now: () => "2026-06-21T00:00:01.000Z",
      readCalibrationFile: () =>
        JSON.stringify({
          raw_projection: "featuremap-v3",
          affine: [
            [1, 0],
            [0, 1],
            [0, 0]
          ],
          feature_map: { coeffs: [[0.1, 0.2]], mean: [0], scale: [1] },
          feature_samples: [
            { feature: { point: [0.5, 0.5] }, target: [0.5, 0.5] },
            { feature: { point: [0.2, 0.8] }, target: [0.2, 0.8] }
          ],
          verify_verdict: {
            median: 0.01,
            p90: 0.02,
            max: 0.05,
            samples: 9,
            regions: { center: 0.008, edge: 0.02 }
          },
          output_offset: [0.02, -0.01],
          geometry: { eye_position_weight_x: 1, eye_position_weight_y: 0.25 }
        })
    });
    const snapshot = initializeStore(store).getSnapshot();

    expect(snapshot.calibration.legacy_calibration).toBeUndefined();
    expect(snapshot.calibration.raw_projection).toBe("featuremap-v3");
    expect(snapshot.calibration.feature_map).toBe(true);
    expect(snapshot.calibration.feature_samples).toBe(2);
    expect(snapshot.calibration.verify_verdict).toMatchObject({ median: 0.01, samples: 9 });
    expect(snapshot.calibration.output_offset).toEqual([0.02, -0.01]);
    expect(snapshot.calibration.geometry).toMatchObject({ eye_position_weight_x: 1 });
    expect(snapshot.calibration.affine).toEqual([
      [1, 0],
      [0, 1],
      [0, 0]
    ]);
  });

  it("initializes display, camera, runtime, and calibration slices from config", () => {
    const snapshot = initializeStore().getSnapshot();

    expect(snapshot.runtime).toMatchObject({ name: "onnxweb" });
    expect(snapshot.runtime.backend).toBeUndefined();
    expect(snapshot.display).toMatchObject({
      display_index: 1,
      display_count: 2,
      bounds: { x: 100, y: 200, width: 1920, height: 1080 },
      display_size_inch: 31.5
    });
    expect(snapshot.camera).toMatchObject({
      camera: "0",
      camera_resolution_name: "VGA",
      camera_width: 640,
      camera_height: 480,
      camera_fov_deg: 90
    });
    expect(snapshot.calibration).toMatchObject({
      path: "/tmp/.gaze_calibration.json",
      raw_projection: "unclipped-v1",
      validation: [{ error: 0.014 }],
      affine: [
        [1, 0],
        [0, 1],
        [0, 0]
      ]
    });
  });

  it("updates gaze normalized and display pixel coordinates", () => {
    const store = initializeStore();

    store.updateFromBackendMessage({
      type: "gaze",
      x_norm: 0.25,
      y_norm: 0.5,
      raw_x_norm: 0.2,
      raw_y_norm: 0.45,
      confidence: 0.9,
      distance_m: 0.7,
      yaw_deg: 3,
      pitch_deg: -2,
      gaze_projection_mode: "binocular-screen",
      detect_inference_ms: 4.2,
      gaze_inference_ms: 12.5,
      inference_ms: 16.7
    });

    expect(store.getSnapshot().gaze).toMatchObject({
      x_norm: 0.25,
      y_norm: 0.5,
      raw_x_norm: 0.2,
      raw_y_norm: 0.45,
      x_px: 580,
      y_px: 740,
      confidence: 0.9,
      distance_m: 0.7,
      yaw_deg: 3,
      pitch_deg: -2,
      detect_inference_ms: 4.2,
      gaze_inference_ms: 12.5,
      inference_ms: 16.7
    });
  });

  it("updates status, camera, and model runtime fields from status messages", () => {
    const store = initializeStore();

    store.updateFromBackendMessage({
      type: "status",
      level: "info",
      message: "Models loaded",
      runtime: "onnxweb",
      detector: "retinaface",
      detector_model: "retinaface.onnx",
      detector_providers: ["CUDAExecutionProvider"],
      gaze_providers: ["CPUExecutionProvider"],
      camera_width: 1280,
      camera_height: 720,
      camera_fov_deg: 80,
      eye_position_weight_x: 0.8,
      eye_position_weight_y: 0.3
    });

    const snapshot = store.getSnapshot();
    expect(snapshot.status).toMatchObject({ level: "info", message: "Models loaded" });
    expect(snapshot.camera).toMatchObject({
      camera_width: 1280,
      camera_height: 720,
      camera_fov_deg: 80,
      eye_position_weight_x: 0.8,
      eye_position_weight_y: 0.3
    });
    expect(snapshot.models.detector).toMatchObject({
      detector: "retinaface",
      model: "retinaface.onnx",
      accelerator: "cuda",
      providers: ["CUDAExecutionProvider"]
    });
    expect(snapshot.models.gaze).toMatchObject({
      accelerator: "cpu",
      providers: ["CPUExecutionProvider"]
    });
  });

  it("updates calibration state and excludes preview image data", () => {
    const store = initializeStore();

    store.updateFromBackendMessage({ type: "calibration", status: "saved", count: 5, path: "/tmp/calibration.json" });
    store.updateFromBackendMessage({
      type: "preview",
      image: "data:image/jpeg;base64,large",
      head_detected: true,
      eye_count: 2,
      width_ratio: 1.5
    });

    const snapshot = store.getSnapshot();
    expect(snapshot.calibration).toMatchObject({
      path: "/tmp/calibration.json",
      status: "saved",
      count: 5,
      saved_path: "/tmp/calibration.json"
    });
    expect(snapshot.preview).toEqual({
      head_detected: true,
      eye_count: 2,
      width_ratio: 1.5,
      updated_at: "2026-06-21T00:00:01.000Z"
    });
    expect(snapshot.preview.image).toBeUndefined();
  });
});

describe("GazeStateStore shared state", () => {
  it("merges report-state slices and reports only changed keys", () => {
    const store = initializeStore();
    expect(
      store.updateSharedState({
        paused: true,
        calibration_status: "loaded",
        settings: { dot_scale: 1.25, dwell_lock: true }
      })
    ).toEqual(expect.arrayContaining(["paused", "calibration_status", "settings"]));

    const snapshot = store.getSnapshot();
    expect(snapshot.paused).toBe(true);
    expect(snapshot.calibration_status).toBe("loaded");
    expect(snapshot.settings).toEqual({ dot_scale: 1.25, dwell_lock: true });
  });

  it("leaves absent slices alone and suppresses no-op updates", () => {
    const store = initializeStore();
    store.updateSharedState({ paused: true });

    // A report naming only calibration_status must not clear paused.
    expect(store.updateSharedState({ calibration_status: "missing" })).toEqual(["calibration_status"]);
    expect(store.getSnapshot().paused).toBe(true);

    // Identical values emit nothing — report-state can repeat freely.
    expect(store.updateSharedState({ paused: true })).toEqual([]);
    expect(store.updateSharedState({ paused: false })).toEqual(["paused"]);
    expect(store.updateSharedState(null)).toEqual([]);
  });

  it("exposes shared-state slices through /snapshot/<name>", async () => {
    const store = initializeStore();
    store.updateSharedState({
      paused: true,
      calibration_status: "loaded",
      settings: { version: 1, diagnostics: { preview: true } }
    });
    const handler = createRequestHandler(store);

    await expect(getJson("/snapshot/paused", handler)).resolves.toMatchObject({ status: 200, body: true });
    await expect(getJson("/snapshot/calibration_status", handler)).resolves.toMatchObject({
      status: 200,
      body: "loaded"
    });
    await expect(getJson("/snapshot/settings", handler)).resolves.toMatchObject({
      status: 200,
      body: { version: 1, diagnostics: { preview: true } }
    });
  });
});

describe("settings helpers", () => {
  it("tolerates missing and corrupt settings payloads", () => {
    expect(parseSettingsPayload(null)).toEqual({});
    expect(parseSettingsPayload("")).toEqual({});
    expect(parseSettingsPayload("{not json")).toEqual({});
    expect(parseSettingsPayload("[1,2]")).toEqual({});
    // A missing file merges as {} — the first write carries only the patch.
    expect(mergeSettings(parseSettingsPayload(null), { dwell_lock: true })).toEqual({ dwell_lock: true });
  });

  it("round-trips read→merge→write without clobbering sibling keys", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gaze-settings-"));
    try {
      const settingsPath = path.join(dir, "settings.json");
      expect(fs.existsSync(settingsPath)).toBe(false);

      const first = mergeSettings({}, { dot_scale: 1.25, diagnostics: { preview: true } });
      fs.writeFileSync(settingsPath, JSON.stringify(first, null, 2));

      const second = mergeSettings(parseSettingsPayload(fs.readFileSync(settingsPath, "utf8")), {
        diagnostics: { status: true }
      });
      fs.writeFileSync(settingsPath, JSON.stringify(second, null, 2));

      expect(parseSettingsPayload(fs.readFileSync(settingsPath, "utf8"))).toEqual({
        dot_scale: 1.25,
        diagnostics: { preview: true, status: true }
      });
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("external API request handler", () => {
  it("serves health and snapshot JSON", async () => {
    const store = initializeStore();
    const handler = createRequestHandler(store);

    await expect(getJson("/health", handler)).resolves.toMatchObject({
      status: 200,
      body: { ok: true, schema_version: 1, started_at: "2026-06-21T00:00:00.000Z" }
    });
    await expect(getJson("/snapshot/display", handler)).resolves.toMatchObject({
      status: 200,
      body: {
        display_index: 1,
        bounds: { x: 100, y: 200, width: 1920, height: 1080 }
      }
    });
  });

  it("returns 404 for unknown paths", async () => {
    const handler = createRequestHandler(initializeStore());

    await expect(getJson("/missing", handler)).resolves.toMatchObject({
      status: 404,
      body: { error: "not_found" }
    });
  });
});

describe("external API control endpoint", () => {
  it("accepts every control action and forwards action + value", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    for (const action of CONTROL_ACTIONS) {
      if (action === "quit") {
        // quit never routes through onControl — it fires the injected
        // onQuit callback; covered by the dedicated quit test below.
        continue;
      }
      // implicit_sample and set_paused are the actions whose values are
      // validated — a bare scalar would 400, so they get their documented
      // shapes (a normalized point, a boolean).
      const value =
        action === "implicit_sample" ? { x_norm: 0.5, y_norm: 0.25 } : action === "set_paused" ? true : 1.25;
      await expect(
        requestJson("/control", handler, { method: "POST", body: { action, value } })
      ).resolves.toMatchObject({ status: 200, body: { ok: true } });
      expect(calls.at(-1)).toEqual([action, value]);
    }
    expect(calls).toHaveLength(CONTROL_ACTIONS.size - 1);
    // Coverage pin: a new action must join this loop deliberately, not slip
    // in unwired — 12 today (11 menu actions + quit, which routes to onQuit).
    expect(CONTROL_ACTIONS.size).toBe(12);
  });

  it("set_paused requires a boolean value — non-booleans are 400", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    for (const value of [undefined, null, 1, "true", { paused: true }]) {
      const body = value === undefined ? { action: "set_paused" } : { action: "set_paused", value };
      await expect(
        requestJson("/control", handler, { method: "POST", body })
      ).resolves.toMatchObject({ status: 400, body: { error: "invalid_value" } });
    }
    expect(calls).toHaveLength(0);

    await expect(
      requestJson("/control", handler, { method: "POST", body: { action: "set_paused", value: true } })
    ).resolves.toMatchObject({ status: 200, body: { ok: true } });
    await expect(
      requestJson("/control", handler, { method: "POST", body: { action: "set_paused", value: false } })
    ).resolves.toMatchObject({ status: 200, body: { ok: true } });
    expect(calls).toEqual([
      ["set_paused", true],
      ["set_paused", false]
    ]);
  });

  it("implicit_sample accepts a normalized point and forwards it verbatim", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    await expect(
      requestJson("/control", handler, {
        method: "POST",
        body: { action: "implicit_sample", value: { x_norm: 0.25, y_norm: 0.75 } }
      })
    ).resolves.toMatchObject({ status: 200, body: { ok: true } });
    expect(calls).toEqual([["implicit_sample", { x_norm: 0.25, y_norm: 0.75 }]]);

    // Boundary values are in range — the label layer clamps nothing because
    // the wire shape itself is already bounded.
    await expect(
      requestJson("/control", handler, {
        method: "POST",
        body: { action: "implicit_sample", value: { x_norm: 0, y_norm: 1 } }
      })
    ).resolves.toMatchObject({ status: 200 });
    expect(calls.at(-1)).toEqual(["implicit_sample", { x_norm: 0, y_norm: 1 }]);
  });

  it("implicit_sample rejects malformed, missing, out-of-range, and wrong-type values with 400", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    const bodies = [
      { action: "implicit_sample" }, // value absent
      { action: "implicit_sample", value: null },
      { action: "implicit_sample", value: 0.5 }, // bare scalar
      { action: "implicit_sample", value: [0.5, 0.5] }, // array, not an object point
      { action: "implicit_sample", value: { x_norm: 0.5 } }, // missing y_norm
      { action: "implicit_sample", value: { x_norm: "0.5", y_norm: 0.5 } }, // wrong type
      { action: "implicit_sample", value: { x_norm: null, y_norm: 0.5 } }, // non-finite on the wire
      { action: "implicit_sample", value: { x_norm: -0.01, y_norm: 0.5 } }, // out of range
      { action: "implicit_sample", value: { x_norm: 0.5, y_norm: 1.5 } }
    ];
    for (const body of bodies) {
      await expect(
        requestJson("/control", handler, { method: "POST", body })
      ).resolves.toMatchObject({ status: 400, body: { error: "invalid_value" } });
    }
    expect(calls).toHaveLength(0);
  });

  it("implicit_sample propagates a handler decline — 409 while inference is stopped", async () => {
    // The contract main.cjs relies on: with no live inference pipeline its
    // handler returns {status,error} and that answer goes on the wire
    // verbatim rather than a generic 200 or 500.
    const handler = createRequestHandler(initializeStore(), () => ({ status: 409, error: "tracking_inactive" }));
    await expect(
      requestJson("/control", handler, {
        method: "POST",
        body: { action: "implicit_sample", value: { x_norm: 0.5, y_norm: 0.5 } }
      })
    ).resolves.toMatchObject({ status: 409, body: { error: "tracking_inactive" } });
  });

  it("implicit_sample still maps a throwing handler to 500", async () => {
    const handler = createRequestHandler(initializeStore(), () => {
      throw new Error("boom");
    });
    await expect(
      requestJson("/control", handler, {
        method: "POST",
        body: { action: "implicit_sample", value: { x_norm: 0.2, y_norm: 0.4 } }
      })
    ).resolves.toMatchObject({ status: 500, body: { error: "control_failed" } });
  });

  it("quit answers 202 and defers the injected onQuit; 503 when unwired", async () => {
    // No onQuit wired → the API can't promise a teardown, so it declines.
    const handler = createRequestHandler(initializeStore(), () => {});
    await expect(
      requestJson("/control", handler, { method: "POST", body: { action: "quit" } })
    ).resolves.toMatchObject({ status: 503 });

    let quitFired = false;
    const handlerWithQuit = createRequestHandler(initializeStore(), () => {}, {
      onQuit: () => { quitFired = true; }
    });
    await expect(
      requestJson("/control", handlerWithQuit, { method: "POST", body: { action: "quit" } })
    ).resolves.toMatchObject({ status: 202, body: { ok: true } });
    await new Promise((resolve) => setImmediate(resolve));
    expect(quitFired).toBe(true);
  });

  it("rejects unknown actions and malformed bodies with 400", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    await expect(
      requestJson("/control", handler, { method: "POST", body: { action: "bogus" } })
    ).resolves.toMatchObject({ status: 400, body: { error: "unknown_action" } });
    await expect(
      requestJson("/control", handler, { method: "POST", body: { value: 1 } })
    ).resolves.toMatchObject({ status: 400, body: { error: "unknown_action" } });
    await expect(
      requestJson("/control", handler, { method: "POST", body: "not an object" })
    ).resolves.toMatchObject({ status: 400, body: { error: "unknown_action" } });
    expect(calls).toHaveLength(0);
  });

  it("keeps every endpoint method-scoped", async () => {
    const handler = createRequestHandler(initializeStore(), () => {});

    await expect(requestJson("/control", handler)).resolves.toMatchObject({
      status: 405,
      body: { error: "method_not_allowed" }
    });
    await expect(
      requestJson("/snapshot", handler, { method: "POST", body: { action: "pause_toggle" } })
    ).resolves.toMatchObject({ status: 405, body: { error: "method_not_allowed" } });
  });

  it("rejects browser-origin control posts like the WS upgrade does", async () => {
    const calls = [];
    const handler = createRequestHandler(initializeStore(), (action, value) => {
      calls.push([action, value]);
    });

    await expect(
      requestJson("/control", handler, {
        method: "POST",
        headers: { origin: "https://untrusted.example" },
        body: { action: "pause_toggle" }
      })
    ).resolves.toMatchObject({ status: 403, body: { error: "forbidden" } });
    expect(calls).toHaveLength(0);
  });

  it("answers 503 when no control callback is wired", async () => {
    const handler = createRequestHandler(initializeStore());

    await expect(
      requestJson("/control", handler, { method: "POST", body: { action: "pause_toggle" } })
    ).resolves.toMatchObject({ status: 503, body: { error: "control_unavailable" } });
  });
});

describe("external API WebSocket", () => {
  it("continues to accept originless native clients", async () => {
    const api = startExternalApiServer({
      store: initializeStore(),
      host: "127.0.0.1",
      port: 0,
      logger: { log: () => undefined, error: () => undefined }
    });

    try {
      await waitForListening(api.server);
      const address = api.server.address();
      await expect(websocketOutcome(`ws://127.0.0.1:${address.port}/events`)).resolves.toEqual({ type: "open" });
    } finally {
      api.close();
    }
  });

  it("rejects browser-originated upgrades before exposing a snapshot", async () => {
    const api = startExternalApiServer({
      store: initializeStore(),
      host: "127.0.0.1",
      port: 0,
      logger: { log: () => undefined, error: () => undefined }
    });

    try {
      await waitForListening(api.server);
      const address = api.server.address();
      for (const origin of ["https://untrusted.example", "null", "http://127.0.0.1:3000"]) {
        const outcome = await websocketOutcome(`ws://127.0.0.1:${address.port}/events`, { origin });
        expect(outcome).toEqual({ type: "rejected", statusCode: 403 });
      }
    } finally {
      api.close();
    }
  });
});

describe("external API /ready endpoint", () => {
  // /ready compares gaze.updated_at against the real clock (a ~3s
  // readiness window), so stores that must look "producing now" get a
  // real-time now(); offset stores land their stamps in the past.
  function liveStore(offsetMs = 0) {
    return initializeStore(
      new GazeStateStore({
        startedAt: "2026-06-21T00:00:00.000Z",
        now: () => new Date(Date.now() + offsetMs).toISOString()
      })
    );
  }

  function loadModels(store) {
    store.updateFromBackendMessage({
      type: "status",
      level: "info",
      message: "Models loaded",
      runtime: "onnxweb",
      accelerator: "webgpu",
      detector: "retinaface",
      detector_model: "retinaface.onnx",
      detector_providers: ["WebGPUExecutionProvider"],
      gaze_providers: ["WebGPUExecutionProvider"]
    });
  }

  it("answers 503 runtime_not_started before the pipeline initializes", async () => {
    const handler = createRequestHandler(createStore());
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 503,
      body: { ready: false, reason: "runtime_not_started" }
    });
  });

  it("answers 503 models_not_loaded once the runtime is up but models never reported", async () => {
    const handler = createRequestHandler(initializeStore());
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 503,
      body: { ready: false, reason: "models_not_loaded" }
    });
  });

  it("answers 503 status_error while the pipeline reports level error — it outranks a loaded pipeline", async () => {
    const store = liveStore();
    loadModels(store);
    store.updateFromBackendMessage({
      type: "gaze",
      x_norm: 0.5,
      y_norm: 0.5,
      confidence: 0.9,
      gaze_state: "fixation"
    });
    store.updateFromBackendMessage({
      type: "status",
      level: "error",
      message: "inference unrecoverable — restart tracking (OrtRun failed)"
    });
    const handler = createRequestHandler(store);
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 503,
      body: { ready: false, reason: "status_error" }
    });
  });

  it("answers 200 once models report loaded and a gaze frame lands inside the window", async () => {
    const store = liveStore();
    loadModels(store);
    store.updateFromBackendMessage({
      type: "gaze",
      x_norm: 0.5,
      y_norm: 0.5,
      confidence: 0.9,
      gaze_state: "fixation"
    });
    const handler = createRequestHandler(store);
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 200,
      body: { ready: true }
    });
  });

  it("answers 503 no_recent_gaze when the last frame is older than the readiness window", async () => {
    // Every stamp this store writes lands 10s in the past — outside the
    // 3s readiness window but with runtime + models present.
    const store = liveStore(-10_000);
    loadModels(store);
    store.updateFromBackendMessage({
      type: "gaze",
      x_norm: 0.5,
      y_norm: 0.5,
      confidence: 0.9
    });
    const handler = createRequestHandler(store);
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 503,
      body: { ready: false, reason: "no_recent_gaze" }
    });
  });

  it("answers 503 no_recent_gaze when tracking never produced a frame", async () => {
    const store = liveStore();
    loadModels(store);
    const handler = createRequestHandler(store);
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 503,
      body: { ready: false, reason: "no_recent_gaze" }
    });
  });

  it("answers 200 for a paused tracker — intentional silence is not a wedge", async () => {
    const store = liveStore(-10_000);
    loadModels(store);
    store.updateSharedState({ paused: true });
    const handler = createRequestHandler(store);
    await expect(getJson("/ready", handler)).resolves.toMatchObject({
      status: 200,
      body: { ready: true }
    });
  });
});
