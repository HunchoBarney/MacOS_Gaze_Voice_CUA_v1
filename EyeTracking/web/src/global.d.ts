export {};

declare global {
  interface Window {
    gazeBridge: {
      getConfig: () => Promise<RendererConfig>;
      readCalibration: (path: string) => Promise<{ ok: true; text: string | null } | { ok: false; error: string }>;
      writeCalibration: (
        path: string,
        payload: unknown
      ) => Promise<{ ok: true; path: string } | { ok: false; error: string }>;
      writeReport: (
        path: string,
        payload: unknown
      ) => Promise<{ ok: true; path: string } | { ok: false; error: string }>;
      ready: () => void;
      setOverlayRegions: (regions: OverlayRegion[]) => void;
      setModalInteractive: (interactive: boolean) => void;
      publishBackendMessage: (payload: BackendMessage) => void;
      onBackendMessage: (callback: (payload: BackendMessage) => void) => () => void;
      onRecalibrate: (callback: () => void) => () => void;
      setPaused: (paused: boolean) => void;
      getSettings: () => Promise<UserSettings>;
      setSettings: (patch: Partial<UserSettings>) => void;
      reportState: (state: SharedStateReport) => void;
    };
  }
}

export interface OverlayRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type CalibrationTier = "full" | "standard" | "quick";

export interface UserSettings {
  version?: number;
  dot_scale?: number;
  // Vision Pro-style default: no gaze cursor. The element-level feedback
  // (intent halo, dwell chips) carries the "where you're pointing" cue;
  // true re-enables the dot for users who want it.
  gaze_dot_visible?: boolean;
  dwell_lock?: boolean;
  show_camera_marker_on_start?: boolean;
  diagnostics?: {
    preview?: boolean;
    status?: boolean;
    inference_time?: boolean;
  };
}

export interface SharedStateReport {
  paused?: boolean;
  calibration_status?: string;
  settings?: UserSettings;
}

export interface RendererConfig {
  calibrate: boolean;
  accuracyTest: boolean;
  // --hit-test: the appendix protocol's step 3 (circular-target hit rate)
  // after the held-out accuracy grid.
  hitTest?: boolean;
  // --calibrate-if-missing: the host's first-enable path — start the full
  // calibration on its own when no usable calibration loads.
  calibrateIfMissing?: boolean;
  // --viewing-distance-cm: the tape-measured eye-to-screen distance the
  // accuracy protocol scores angles against (else the tracker's estimate).
  viewingDistanceCm?: number;
  calibrationTier: CalibrationTier;
  displayIndex: number;
  requestedDisplayIndex: number;
  displayCount: number;
  displayBounds: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  invalidDisplay: boolean;
  cameraScreenX: number;
  cameraScreenY: number;
  enableInferenceTime: boolean;
  debug?: boolean;
  showCameraMarker?: boolean;
  runtime: RuntimeName;
  webInference: WebInferenceConfig | null;
}

export type RuntimeName = "onnxweb";
export type GazeProjectionMode = "legacy" | "binocular-screen" | "binocular-convergence";
export type AcceleratorName = "webgpu" | "wasm";
export type WebAccelerator = AcceleratorName;
export type WebInferenceWorkerMode = "off" | "ort-proxy" | "dedicated";

export interface WebInferenceConfig {
  runtime: RuntimeName;
  webInferenceWorker: WebInferenceWorkerMode;
  webAccelerator: "auto" | "webgpu" | "wasm";
  detector: "mediapipe" | "retinaface" | "yolo";
  mediapipeWasmBaseUrl?: string;
  mediapipeDelegate?: "cpu" | "gpu";
  backend: string;
  camera: string;
  cameraResolutionName?: string;
  cameraWidth: number;
  cameraHeight: number;
  cameraFov: number;
  scoreThreshold: number;
  displaySizeInch: number;
  displayWidth: number;
  displayHeight: number;
  calibrationFile: string;
  detectorModel: string;
  lipMotionModel: string;
  detectorModelUrl: string;
  gazeModelUrl: string;
  lipMotionModelUrl: string;
  onnxWasmBaseUrl: string;
  appearanceModelUrl?: string;
  assetBaseUrl?: string;
  smoothingAlpha: number;
  smoothingAlphaY: number;
  calibrate: boolean;
  gazeFilter: "saccade" | "oneeuro" | "ema";
  filterMincutoff: number;
  filterBeta: number;
  filterDcutoff: number;
  disableIrisDistance: boolean;
  previewFps: number;
  gazeMaxFps: number;
  wasmThreads?: number;
  hidePreview: boolean;
  flipX: boolean;
  flipY: boolean;
  cameraScreenX: number;
  cameraScreenY: number;
  eyePositionWeightX: number;
  eyePositionWeightY: number;
  retinafaceHeadFaceRatio: number;
  gazeProjectionMode: GazeProjectionMode;
  enableLipMotion: boolean;
}

export type BackendMessage =
  | {
      type: "gaze";
      x_norm: number;
      y_norm: number;
      raw_x_norm?: number;
      raw_y_norm?: number;
      confidence: number;
      distance_m: number;
      iris_distance_m?: number;
      distance_source?: "iris" | "head";
      eye_open?: number;
      blink?: boolean;
      head_turned?: boolean;
      gaze_filter?: string;
      tracking_source?: "detector" | "iris";
      held_reason?: string;
      filter_velocity_deg_s?: number;
      gaze_state?: "fixation" | "saccade" | "dwell";
      head_face_width_ratio?: number;
      eye_position_weight_x?: number;
      eye_position_weight_y?: number;
      gaze_projection_mode?: GazeProjectionMode;
      detect_inference_ms?: number;
      gaze_inference_ms?: number;
      lip_motion_inference_ms?: number;
      inference_ms?: number;
      capture_ms?: number;
      preview_ms?: number;
      frame_interval_ms?: number;
      // Wall-clock (Date.now) at emit — comparable across worker/page realms
      // for capture-time velocity and true sample age, unlike performance.now.
      captured_at_ms?: number;
      processed_fps?: number;
      dropped_frames?: number;
      main_thread_long_tasks?: number;
      // Metric head pose vs the session straight-ahead (Kabsch mesh fit).
      // Absent when the fit degenerated — the head-tilt gate must see absent
      // as "no data" and not gate, never as a gaze-angle substitute.
      yaw_deg?: number;
      pitch_deg?: number;
      mouth_detected?: boolean;
      mouth_open?: boolean;
      mouth_open_probability?: number | null;
    }
  | {
      type: "gaze";
      // Liveness heartbeat while no face is visible — it exists only to
      // keep the store's gaze.updated_at fresh so the host's wedge watch
      // never mistakes a healthy-but-empty pipeline for a dead one. It is
      // deliberately NOT a gaze sample: no x_norm/y_norm are carried, the
      // store exposes `away: true`, and the UI must not read it as
      // presence, move the cursor, or re-arm the gaze-stale timer.
      away: true;
      held_reason: string;
      confidence?: number;
      captured_at_ms?: number;
    }
  | {
      type: "status";
      level: "info" | "warning" | "error";
      message: string;
      runtime?: RuntimeName;
      accelerator?: AcceleratorName;
      logged?: boolean;
      detector?: string;
      detector_model?: string;
      detector_providers?: string[];
      head_face_width_ratio?: number;
      camera_fov_deg?: number;
      camera_resolution_name?: string;
      camera_width?: number;
      camera_height?: number;
      camera_screen_x?: number;
      camera_screen_y?: number;
      eye_position_weight_x?: number;
      eye_position_weight_y?: number;
      gaze_projection_mode?: GazeProjectionMode;
      gaze_providers?: string[];
      lip_motion_enabled?: boolean;
      lip_motion_model?: string;
      lip_motion_providers?: string[];
    }
  | {
      type: "preview";
      image: string;
      head_detected: boolean;
      eye_count: number;
      width_ratio?: number | null;
    }
  | {
      type: "lip_click_effect";
      effect: "single" | "double";
      x?: number;
      y?: number;
    }
  | {
      type: "calibration";
      status: string;
      count?: number;
      path?: string;
      message?: string;
      verdict?: VerifyVerdict;
      geometry?: {
        eye_position_weight_x: number;
        eye_position_weight_y: number;
      } | null;
    }
  | {
      type: "cursor_idle";
      x_norm: number;
      y_norm: number;
    }
  | {
      type: "menu_action";
      action: string;
      value?: unknown;
    };

// Verify-sweep outcome: normalized-screen error stats for the pending fit,
// bucketed by target region (center / edge / corner) so edge regressions are
// visible instead of averaged away.
export interface VerifyVerdict {
  median: number;
  p90: number;
  max: number;
  samples: number;
  regions: {
    center?: number;
    edge?: number;
    corner?: number;
  };
}
