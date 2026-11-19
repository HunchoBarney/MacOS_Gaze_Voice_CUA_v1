const SCHEMA_VERSION = 1;

function defaultNow() {
  return new Date().toISOString();
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function integer(value) {
  const number = finiteNumber(value);
  return number === undefined ? undefined : Math.trunc(number);
}

function stringValue(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function compactObject(value) {
  const output = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      output[key] = item;
    }
  }
  return output;
}

function displayBounds(bounds) {
  if (!bounds || typeof bounds !== "object") {
    return undefined;
  }
  return compactObject({
    x: integer(bounds.x),
    y: integer(bounds.y),
    width: integer(bounds.width),
    height: integer(bounds.height)
  });
}

function validBounds(bounds) {
  return bounds && Number.isFinite(bounds.x) && Number.isFinite(bounds.y) && bounds.width > 0 && bounds.height > 0;
}

// Calibration schema generations the runtime can still load. Anything else
// (clipped legacy files, unknown future versions) is reported as legacy.
const KNOWN_RAW_PROJECTIONS = new Set(["unclipped-v1", "unclipped-v2", "featuremap-v3"]);

// rbf/feature_rbf corrections carry centers+weights arrays sized to the
// sample pool (up to ~1200 [x,y] pairs each) — the same wire-weight problem
// as the raw pools below. Surface the correction's extent (center count +
// sigma); the renderer re-reads the full coordinates from the file itself.
function summarizeRbf(value) {
  if (!value || typeof value !== "object" || !Array.isArray(value.centers)) {
    return undefined;
  }
  return compactObject({
    center_count: integer(value.centers.length),
    sigma: finiteNumber(value.sigma)
  });
}

function readCalibrationPayload(path, readCalibrationFile) {
  if (!path || typeof readCalibrationFile !== "function") {
    return {};
  }
  try {
    const text = readCalibrationFile(path);
    if (!text) {
      return {};
    }
    const payload = JSON.parse(text);
    if (!KNOWN_RAW_PROJECTIONS.has(payload.raw_projection)) {
      return { legacy_calibration: true };
    }
    const affine = Array.isArray(payload.affine) ? payload.affine : undefined;
    const rbf = summarizeRbf(payload.rbf);
    const geometry = payload.geometry && typeof payload.geometry === "object" ? payload.geometry : undefined;
    const sourceBounds = payload.source_bounds && typeof payload.source_bounds === "object" ? payload.source_bounds : undefined;
    // The raw sample pool is ~1200 labelled points — far too heavy to embed
    // in every snapshot and re-serialize on every ~20Hz WS update (the v3
    // feature_samples pool is already count-only for the same reason).
    // Surface presence + count only; no consumer reads the coordinates.
    const samples = Array.isArray(payload.samples)
      ? { count: payload.samples.length, loaded: true }
      : undefined;
    const validation = Array.isArray(payload.validation) ? payload.validation : undefined;
    // featuremap-v3 carries the refittable pool — the coeffs and full-feature
    // samples are far too large for the state snapshot, so surface presence
    // and counts instead of the arrays themselves.
    const featureMap = payload.feature_map && typeof payload.feature_map === "object" ? true : undefined;
    const featureRbf = summarizeRbf(payload.feature_rbf);
    const featureSamples = Array.isArray(payload.feature_samples) ? payload.feature_samples.length : undefined;
    const verifyVerdict = payload.verify_verdict && typeof payload.verify_verdict === "object" ? payload.verify_verdict : undefined;
    const outputOffset = Array.isArray(payload.output_offset) ? payload.output_offset : undefined;
    return compactObject({
      raw_projection: stringValue(payload.raw_projection),
      affine,
      rbf,
      feature_map: featureMap,
      feature_rbf: featureRbf,
      feature_samples: featureSamples,
      verify_verdict: verifyVerdict,
      output_offset: outputOffset,
      geometry,
      source_bounds: sourceBounds,
      samples,
      validation
    });
  } catch (error) {
    return {
      read_error: error instanceof Error ? error.message : String(error)
    };
  }
}

function createInitialSnapshot(startedAt) {
  return {
    schema_version: SCHEMA_VERSION,
    started_at: startedAt,
    updated_at: startedAt,
    runtime: null,
    display: null,
    camera: null,
    gaze: null,
    calibration: null,
    models: {
      detector: null,
      gaze: null
    },
    status: null,
    preview: null,
    paused: false,
    calibration_status: null,
    settings: null
  };
}

class GazeStateStore {
  constructor(options = {}) {
    this.now = options.now || defaultNow;
    this.readCalibrationFile = options.readCalibrationFile;
    // Freshness probe for the calibration payload cache — returns
    // {mtimeMs, size} or null when the path can't be stat'd. A 2Hz stream
    // of "pursuit_sampled" calibration messages must not re-read+re-parse
    // a file that only changes on commitPending.
    this.statCalibrationFile = options.statCalibrationFile;
    this.calibrationFileCache = null;
    this.lastCaptureMs = 0;
    const startedAt = options.startedAt || this.now();
    this.state = createInitialSnapshot(startedAt);
    this.listeners = new Set();
  }

  // Re-reads the calibration file only when its (path, mtime, size)
  // signature moved — identical bytes parse to the identical payload, so
  // an unchanged stat serves the cached object. No stat seam (tests) or
  // an unstat'able path re-reads every message, exactly as before.
  calibrationPayload(path) {
    let signature = null;
    if (path && typeof this.statCalibrationFile === "function") {
      try {
        const stat = this.statCalibrationFile(path);
        if (stat && Number.isFinite(stat.mtimeMs) && Number.isFinite(stat.size)) {
          signature = { mtimeMs: stat.mtimeMs, size: stat.size };
        }
      } catch {
        // A stat that can't answer can't vouch for freshness — re-read.
      }
    }
    const cache = this.calibrationFileCache;
    if (
      signature &&
      cache &&
      cache.path === path &&
      cache.mtimeMs === signature.mtimeMs &&
      cache.size === signature.size
    ) {
      return cache.payload;
    }
    const payload = readCalibrationPayload(path, this.readCalibrationFile);
    this.calibrationFileCache = signature ? { path, ...signature, payload } : null;
    return payload;
  }

  getSnapshot() {
    return clone(this.state);
  }

  getSlice(name) {
    if (!Object.prototype.hasOwnProperty.call(this.state, name)) {
      return undefined;
    }
    return clone(this.state[name]);
  }

  subscribe(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  initialize(config, options = {}) {
    const updatedAt = this.now();
    const webConfig = config?.webInference || null;
    const bounds = displayBounds(config?.displayBounds);
    const calibrationFile = stringValue(webConfig?.calibrationFile) || stringValue(options.calibrationFile);
    const displayWidth = integer(webConfig?.displayWidth) || bounds?.width;
    const displayHeight = integer(webConfig?.displayHeight) || bounds?.height;

    this.state.runtime = compactObject({
      name: stringValue(config?.runtime) || stringValue(webConfig?.runtime),
      accelerator: undefined,
      updated_at: updatedAt
    });
    this.state.display = compactObject({
      display_index: integer(config?.displayIndex),
      requested_display_index: integer(config?.requestedDisplayIndex),
      display_count: integer(config?.displayCount),
      bounds,
      invalid_display: Boolean(config?.invalidDisplay),
      display_size_inch: finiteNumber(webConfig?.displaySizeInch) ?? finiteNumber(options.displaySizeInch),
      display_width: displayWidth,
      display_height: displayHeight,
      updated_at: updatedAt
    });
    this.state.camera = compactObject({
      camera: stringValue(webConfig?.camera) || stringValue(options.camera),
      camera_resolution_name: stringValue(webConfig?.cameraResolutionName) || stringValue(options.cameraResolutionName),
      camera_width: integer(webConfig?.cameraWidth) ?? integer(options.cameraWidth),
      camera_height: integer(webConfig?.cameraHeight) ?? integer(options.cameraHeight),
      camera_fov_deg: finiteNumber(webConfig?.cameraFov) ?? finiteNumber(options.cameraFov),
      camera_screen_x: finiteNumber(config?.cameraScreenX) ?? finiteNumber(webConfig?.cameraScreenX),
      camera_screen_y: finiteNumber(config?.cameraScreenY) ?? finiteNumber(webConfig?.cameraScreenY),
      eye_position_weight_x: finiteNumber(webConfig?.eyePositionWeightX) ?? finiteNumber(options.eyePositionWeightX),
      eye_position_weight_y: finiteNumber(webConfig?.eyePositionWeightY) ?? finiteNumber(options.eyePositionWeightY),
      updated_at: updatedAt
    });
    this.state.calibration = compactObject({
      path: calibrationFile,
      ...this.calibrationPayload(calibrationFile),
      updated_at: updatedAt
    });
    this.state.updated_at = updatedAt;
    this.notify(["runtime", "display", "camera", "calibration"]);
  }

  updateFromBackendMessage(payload) {
    if (!payload || typeof payload !== "object" || typeof payload.type !== "string") {
      return [];
    }
    const updatedAt = this.now();
    const changed = new Set();

    if (payload.type === "gaze") {
      const xNorm = finiteNumber(payload.x_norm);
      const yNorm = finiteNumber(payload.y_norm);
      const receivedMs = Date.parse(updatedAt);
      const sourceMs = payload.captured_at_ms;
      const held = payload.away === true || payload.blink === true || payload.head_turned === true || Boolean(payload.held_reason);
      const proven = !this.state.paused && !held && Number.isFinite(payload.x_norm) && Number.isFinite(payload.y_norm) &&
        Number.isFinite(sourceMs) && sourceMs > this.lastCaptureMs && sourceMs < receivedMs + 1;
      if (proven) this.lastCaptureMs = sourceMs;
      else if (held && Number.isFinite(receivedMs)) this.lastCaptureMs = Math.max(this.lastCaptureMs, receivedMs);
      const bounds = this.state.display?.bounds;
      const pixels =
        xNorm !== undefined && yNorm !== undefined && validBounds(bounds)
          ? {
              x_px: bounds.x + xNorm * bounds.width,
              y_px: bounds.y + yNorm * bounds.height
            }
          : {};
      this.state.gaze = compactObject({
        // An away heartbeat carries no coords — the rebuild below drops the
        // last real position rather than leaving a stale-but-fresh target
        // that a consumer could read as live. `away` marks the slice as a
        // liveness beat: fresh updated_at, no valid gaze.
        away: payload.away === true ? true : undefined,
        captured_at_ms: proven ? sourceMs : undefined,
        x_norm: xNorm,
        y_norm: yNorm,
        raw_x_norm: finiteNumber(payload.raw_x_norm),
        raw_y_norm: finiteNumber(payload.raw_y_norm),
        ...pixels,
        confidence: finiteNumber(payload.confidence),
        distance_m: finiteNumber(payload.distance_m),
        iris_distance_m: finiteNumber(payload.iris_distance_m),
        distance_source: stringValue(payload.distance_source),
        eye_open: finiteNumber(payload.eye_open),
        blink: payload.blink === true ? true : undefined,
        head_turned: payload.head_turned === true ? true : undefined,
        gaze_filter: stringValue(payload.gaze_filter),
        tracking_source: stringValue(payload.tracking_source),
        held_reason: stringValue(payload.held_reason),
        filter_velocity_deg_s: finiteNumber(payload.filter_velocity_deg_s),
        gaze_state: stringValue(payload.gaze_state),
        capture_ms: finiteNumber(payload.capture_ms),
        preview_ms: finiteNumber(payload.preview_ms),
        processed_fps: finiteNumber(payload.processed_fps),
        frame_interval_ms: finiteNumber(payload.frame_interval_ms),
        head_face_width_ratio: finiteNumber(payload.head_face_width_ratio),
        eye_position_weight_x: finiteNumber(payload.eye_position_weight_x),
        eye_position_weight_y: finiteNumber(payload.eye_position_weight_y),
        gaze_projection_mode: stringValue(payload.gaze_projection_mode),
        detect_inference_ms: finiteNumber(payload.detect_inference_ms),
        gaze_inference_ms: finiteNumber(payload.gaze_inference_ms),
        inference_ms: finiteNumber(payload.inference_ms),
        yaw_deg: finiteNumber(payload.yaw_deg),
        pitch_deg: finiteNumber(payload.pitch_deg),
        updated_at: updatedAt
      });
      changed.add("gaze");
    } else if (payload.type === "status") {
      this.state.status = compactObject({
        level: stringValue(payload.level),
        message: stringValue(payload.message),
        updated_at: updatedAt
      });
      this.mergeRuntimeFromStatus(payload, updatedAt);
      this.mergeCameraFromStatus(payload, updatedAt);
      this.mergeModelsFromStatus(payload, updatedAt);
      changed.add("status");
      changed.add("runtime");
      if (this.state.camera) {
        changed.add("camera");
      }
      if (payload.detector_providers || payload.gaze_providers || payload.detector_model) {
        changed.add("models");
      }
    } else if (payload.type === "calibration") {
      const path = stringValue(payload.path) || this.state.calibration?.path;
      this.state.calibration = compactObject({
        ...(this.state.calibration || {}),
        path,
        status: stringValue(payload.status),
        count: integer(payload.count),
        saved_path: stringValue(payload.path),
        message: stringValue(payload.message),
        ...this.calibrationPayload(path),
        updated_at: updatedAt
      });
      changed.add("calibration");
    } else if (payload.type === "preview") {
      this.state.preview = compactObject({
        head_detected: Boolean(payload.head_detected),
        eye_count: integer(payload.eye_count),
        width_ratio: finiteNumber(payload.width_ratio),
        updated_at: updatedAt
      });
      changed.add("preview");
    }

    if (changed.size === 0) {
      return [];
    }
    this.state.updated_at = updatedAt;
    const changedList = Array.from(changed);
    this.notify(changedList);
    return changedList;
  }

  // Cross-process shared state — arrives via the renderer's report-state IPC
  // and the main-side set-paused/set-settings writers rather than as typed
  // backend messages. Only keys present in the report are touched, and only
  // slices whose value actually changed notify subscribers.
  updateSharedState(report) {
    if (!report || typeof report !== "object") {
      return [];
    }
    const updatedAt = this.now();
    const changed = new Set();

    if (report.paused !== undefined) {
      const paused = Boolean(report.paused);
      if (this.state.paused !== paused) {
        this.state.paused = paused;
        changed.add("paused");
        if (paused && this.state.gaze?.captured_at_ms !== undefined) {
          delete this.state.gaze.captured_at_ms;
          changed.add("gaze");
        }
        if (!paused) this.lastCaptureMs = Math.max(this.lastCaptureMs, Date.parse(updatedAt) + 1);
      }
    }
    if (report.calibration_status !== undefined) {
      const status =
        report.calibration_status === null ? null : (stringValue(report.calibration_status) ?? null);
      if (this.state.calibration_status !== status) {
        this.state.calibration_status = status;
        changed.add("calibration_status");
      }
    }
    if (report.settings !== undefined) {
      const settings =
        report.settings && typeof report.settings === "object" && !Array.isArray(report.settings)
          ? clone(report.settings)
          : null;
      if (JSON.stringify(this.state.settings) !== JSON.stringify(settings)) {
        this.state.settings = settings;
        changed.add("settings");
      }
    }

    if (changed.size === 0) {
      return [];
    }
    this.state.updated_at = updatedAt;
    const changedList = Array.from(changed);
    this.notify(changedList);
    return changedList;
  }

  mergeRuntimeFromStatus(payload, updatedAt) {
    this.state.runtime = compactObject({
      ...(this.state.runtime || {}),
      name: stringValue(payload.runtime) || this.state.runtime?.name,
      accelerator: stringValue(payload.accelerator) || this.state.runtime?.accelerator,
      updated_at: updatedAt
    });
  }

  mergeCameraFromStatus(payload, updatedAt) {
    const cameraUpdate = compactObject({
      camera_resolution_name: stringValue(payload.camera_resolution_name),
      camera_width: integer(payload.camera_width),
      camera_height: integer(payload.camera_height),
      camera_fov_deg: finiteNumber(payload.camera_fov_deg),
      camera_screen_x: finiteNumber(payload.camera_screen_x),
      camera_screen_y: finiteNumber(payload.camera_screen_y),
      eye_position_weight_x: finiteNumber(payload.eye_position_weight_x),
      eye_position_weight_y: finiteNumber(payload.eye_position_weight_y)
    });
    if (Object.keys(cameraUpdate).length === 0) {
      return;
    }
    this.state.camera = compactObject({
      ...(this.state.camera || {}),
      ...cameraUpdate,
      updated_at: updatedAt
    });
  }

  mergeModelsFromStatus(payload, updatedAt) {
    if (payload.detector_providers || payload.detector_model || payload.detector) {
      this.state.models.detector = compactObject({
        runtime: stringValue(payload.runtime) || this.state.runtime?.name,
        accelerator: stringValue(payload.accelerator) || providerToAccelerator(payload.detector_providers?.[0]),
        detector: stringValue(payload.detector),
        model: stringValue(payload.detector_model),
        providers: Array.isArray(payload.detector_providers) ? payload.detector_providers.map(String) : undefined,
        updated_at: updatedAt
      });
    }
    if (payload.gaze_providers) {
      this.state.models.gaze = compactObject({
        runtime: stringValue(payload.runtime) || this.state.runtime?.name,
        accelerator: stringValue(payload.accelerator) || providerToAccelerator(payload.gaze_providers?.[0]),
        providers: Array.isArray(payload.gaze_providers) ? payload.gaze_providers.map(String) : undefined,
        updated_at: updatedAt
      });
    }
  }

  notify(changed) {
    // Nobody listening — skip the event build entirely (this is the common
    // case whenever the external API isn't running).
    if (this.listeners.size === 0) {
      return;
    }
    // The event carries the live state object, not a deep clone: every
    // current listener is the WS send path, which runs JSON.stringify
    // synchronously inside this call, so the clone was dead work at ~20Hz.
    // Contract: listeners must consume the event synchronously and must not
    // retain or mutate it — the store keeps mutating `state` afterwards.
    const event = {
      type: "update",
      changed,
      snapshot: this.state
    };
    for (const listener of this.listeners) {
      listener(event);
    }
  }
}

function providerToAccelerator(provider) {
  if (!provider) {
    return undefined;
  }
  const normalized = String(provider).toLowerCase();
  if (normalized.includes("tensorrt")) {
    return "tensorrt";
  }
  if (normalized.includes("cuda")) {
    return "cuda";
  }
  if (normalized.includes("cpu")) {
    return "cpu";
  }
  if (normalized.includes("webgpu")) {
    return "webgpu";
  }
  if (normalized.includes("wasm")) {
    return "wasm";
  }
  return String(provider).replace(/ExecutionProvider$/u, "");
}

// settings.json merge semantics shared by the set-settings IPC, the tray
// menu, and POST /control writers: top-level keys overwrite, nested plain
// objects (diagnostics) merge key-by-key so one toggle can't clobber others.
function mergeSettings(base, patch) {
  const merged = { ...(base && typeof base === "object" && !Array.isArray(base) ? base : {}) };
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) {
    return merged;
  }
  for (const [key, value] of Object.entries(patch)) {
    const existing = merged[key];
    if (
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      existing &&
      typeof existing === "object" &&
      !Array.isArray(existing)
    ) {
      merged[key] = { ...existing, ...value };
    } else {
      merged[key] = value;
    }
  }
  return merged;
}

// Missing/corrupt settings.json is a normal state (first run, truncated
// write) — callers always get a plain object, never a throw.
function parseSettingsPayload(text) {
  if (!text) {
    return {};
  }
  try {
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

module.exports = {
  GazeStateStore,
  SCHEMA_VERSION,
  providerToAccelerator,
  mergeSettings,
  parseSettingsPayload
};
