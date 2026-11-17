import { createRequire } from "node:module";
import WebSocket from "ws";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const { startExternalApiServer } = require("./externalApi.cjs");
const { GazeStateStore } = require("./externalStore.cjs");

// Regression guard for the snapshot compaction contract: a pursuit
// calibration file carries ~1200 labelled samples, an ~800-entry
// feature_samples pool, and rbf/feature_rbf center arrays sized to that
// pool. None of that may reach the snapshot — it is re-serialized on every
// ~20Hz /events update and re-cloned on every /snapshot poll. The wire
// shape is presence + counts; coordinates stay on disk, where the renderer
// re-reads them on load.
function heavyCalibrationFile() {
  const pair = [0.5, 0.5];
  const rbf = { centers: Array.from({ length: 1200 }, () => pair), weights: Array.from({ length: 1200 }, () => pair), sigma: 0.1 };
  return JSON.stringify({
    raw_projection: "featuremap-v3",
    affine: [
      [1, 0],
      [0, 1],
      [0, 0]
    ],
    rbf,
    feature_map: { coeffs: [[0.1, 0.2]], mean: [0], scale: [1] },
    feature_rbf: { ...rbf, sigma: 0.2 },
    samples: Array.from({ length: 1200 }, () => ({ raw: pair, target: pair })),
    feature_samples: Array.from({ length: 800 }, () => ({ feature: { point: pair }, target: pair })),
    verify_verdict: { median: 0.01, p90: 0.02, max: 0.05, samples: 9, regions: { center: 0.008 } },
    geometry: { eye_position_weight_x: 1, eye_position_weight_y: 0.25 }
  });
}

function heavyStore() {
  const store = new GazeStateStore({
    startedAt: "2026-06-21T00:00:00.000Z",
    now: () => "2026-06-21T00:00:01.000Z",
    readCalibrationFile: heavyCalibrationFile
  });
  store.initialize({
    runtime: "onnxweb",
    displayIndex: 0,
    displayBounds: { x: 0, y: 0, width: 1920, height: 1080 },
    webInference: { runtime: "onnxweb", calibrationFile: "/tmp/.gaze_calibration.json" }
  });
  return store;
}

function collectFrames(url, count) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const frames = [];
    socket.on("message", (data) => {
      frames.push(JSON.parse(data.toString()));
      if (frames.length >= count) {
        socket.close();
        resolve(frames);
      }
    });
    socket.once("error", reject);
  });
}

describe("snapshot compaction contract", () => {
  it("serves calibration sample pools as counts, never coordinate arrays", () => {
    const snapshot = heavyStore().getSnapshot();

    expect(snapshot.calibration.samples).toEqual({ count: 1200, loaded: true });
    expect(snapshot.calibration.feature_samples).toBe(800);
    expect(snapshot.calibration.feature_map).toBe(true);
    // rbf/feature_rbf summaries carry the extent, not the arrays.
    expect(snapshot.calibration.rbf).toEqual({ center_count: 1200, sigma: 0.1 });
    expect(snapshot.calibration.feature_rbf).toEqual({ center_count: 1200, sigma: 0.2 });

    const serialized = JSON.stringify(snapshot.calibration);
    // No coordinate arrays survived — the whole slice stays in the same
    // size class as a single status line regardless of pool depth.
    expect(serialized).not.toContain('"raw"');
    expect(serialized).not.toContain('"centers"');
    expect(serialized).not.toContain('"weights"');
    expect(serialized).not.toContain('"coeffs"');
    expect(serialized.length).toBeLessThan(2000);
  });

  it("omits the samples marker entirely when the file has no pool", () => {
    const store = new GazeStateStore({
      startedAt: "2026-06-21T00:00:00.000Z",
      now: () => "2026-06-21T00:00:01.000Z",
      readCalibrationFile: () =>
        JSON.stringify({ raw_projection: "unclipped-v1", affine: [[1, 0], [0, 1], [0, 0]] })
    });
    store.initialize({
      runtime: "onnxweb",
      displayBounds: { x: 0, y: 0, width: 1920, height: 1080 },
      webInference: { runtime: "onnxweb", calibrationFile: "/tmp/.gaze_calibration.json" }
    });
    const calibration = store.getSnapshot().calibration;
    expect(calibration.samples).toBeUndefined();
    expect(calibration.rbf).toBeUndefined();
    expect(calibration.feature_rbf).toBeUndefined();
  });
});

describe("update listener contract", () => {
  const gazeFrame = {
    type: "gaze",
    x_norm: 0.25,
    y_norm: 0.5,
    confidence: 0.9,
    distance_m: 0.7,
    yaw_deg: 3,
    pitch_deg: -2
  };

  it("delivers {type:update, changed, snapshot} synchronously per update", () => {
    const store = heavyStore();
    const events = [];
    // Mirror the WS send path: consume synchronously via JSON.stringify
    // inside the callback — the contract the live (uncloned) snapshot
    // requires of every listener.
    store.subscribe((event) => events.push(JSON.stringify(event)));

    const changed = store.updateFromBackendMessage(gazeFrame);

    expect(changed).toEqual(["gaze"]);
    expect(events).toHaveLength(1);
    const event = JSON.parse(events[0]);
    expect(event.type).toBe("update");
    expect(event.changed).toEqual(["gaze"]);
    expect(event.snapshot.gaze).toMatchObject({ x_norm: 0.25, y_norm: 0.5 });
    // The compacted calibration shape rides every update, same as /snapshot.
    expect(event.snapshot.calibration.samples).toEqual({ count: 1200, loaded: true });
  });

  it("keeps bookkeeping intact with zero listeners — notify early-exit skips nothing else", () => {
    let stamps = ["2026-06-21T00:00:00.000Z", "2026-06-21T00:00:02.000Z"];
    const store = new GazeStateStore({
      startedAt: "2026-06-21T00:00:00.000Z",
      now: () => stamps.shift() || "2026-06-21T00:00:02.000Z",
      readCalibrationFile: () => null
    });
    store.initialize({
      runtime: "onnxweb",
      displayBounds: { x: 0, y: 0, width: 1920, height: 1080 },
      webInference: { runtime: "onnxweb", calibrationFile: "/tmp/.gaze_calibration.json" }
    });

    // Nobody subscribed — the changed list and the stamps must still land.
    expect(store.updateFromBackendMessage(gazeFrame)).toEqual(["gaze"]);
    expect(store.updateSharedState({ paused: true })).toEqual(["paused"]);

    const snapshot = store.getSnapshot();
    expect(snapshot.gaze.x_norm).toBe(0.25);
    expect(snapshot.paused).toBe(true);
    expect(snapshot.gaze.updated_at).toBe("2026-06-21T00:00:02.000Z");
    expect(snapshot.updated_at).toBe("2026-06-21T00:00:02.000Z");
  });

  it("away heartbeat refreshes gaze.updated_at without a valid target", () => {
    const store = heavyStore();
    const changed = store.updateFromBackendMessage(gazeFrame);
    expect(changed).toEqual(["gaze"]);
    expect(store.getSnapshot().gaze.x_norm).toBe(0.25);

    // The away heartbeat is liveness, not a sample: no coordinates, marked
    // `away: true` — it must still count as a gaze update (the host's wedge
    // watch reads gaze.updated_at) while dropping the stale position so no
    // consumer can read it as live.
    const changedAway = store.updateFromBackendMessage({
      type: "gaze",
      away: true,
      held_reason: "no_face",
      confidence: 0
    });
    expect(changedAway).toEqual(["gaze"]);
    const gaze = store.getSnapshot().gaze;
    expect(gaze.away).toBe(true);
    expect(gaze.held_reason).toBe("no_face");
    expect(gaze.x_norm).toBeUndefined();
    expect(gaze.y_norm).toBeUndefined();
    expect(gaze.updated_at).toBeDefined();
  });

  it("a real gaze sample clears the away marker", () => {
    const store = heavyStore();
    store.updateFromBackendMessage({ type: "gaze", away: true, held_reason: "no_face", confidence: 0 });
    store.updateFromBackendMessage(gazeFrame);
    const gaze = store.getSnapshot().gaze;
    expect(gaze.away).toBeUndefined();
    expect(gaze.x_norm).toBe(0.25);
  });

  it("stops delivering after unsubscribe", () => {
    const store = heavyStore();
    const events = [];
    const unsubscribe = store.subscribe((event) => events.push(event.type));

    store.updateFromBackendMessage(gazeFrame);
    unsubscribe();
    store.updateFromBackendMessage(gazeFrame);
    store.updateSharedState({ paused: true });

    expect(events).toEqual(["update"]);
  });
});

describe("/events wire shape", () => {
  it("serves the compacted snapshot on connect and on update", async () => {
    const store = heavyStore();
    const api = startExternalApiServer({
      store,
      host: "127.0.0.1",
      port: 0,
      logger: { log: () => undefined, error: () => undefined }
    });
    try {
      await new Promise((resolve) => (api.server.listening ? resolve() : api.server.once("listening", resolve)));
      const { port } = api.server.address();
      const pending = collectFrames(`ws://127.0.0.1:${port}/events`, 2);
      // Connect handshake arrives first; the gaze update produces frame 2.
      await new Promise((resolve) => setTimeout(resolve, 50));
      store.updateFromBackendMessage({ type: "gaze", x_norm: 0.5, y_norm: 0.5, confidence: 0.9 });
      const [handshake, update] = await pending;

      expect(handshake.type).toBe("snapshot");
      expect(handshake.snapshot.calibration.samples).toEqual({ count: 1200, loaded: true });
      expect(update.type).toBe("update");
      expect(update.changed).toEqual(["gaze"]);
      expect(update.snapshot.gaze.x_norm).toBe(0.5);
      expect(update.snapshot.calibration.samples).toEqual({ count: 1200, loaded: true });
    } finally {
      api.close();
    }
  });
});
