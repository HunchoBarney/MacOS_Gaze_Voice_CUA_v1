import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { AcceleratorName, BackendMessage, CalibrationTier, OverlayRegion, RendererConfig, RuntimeName, UserSettings, VerifyVerdict } from "./global";
import { startWebRuntime, type WebRuntimeController } from "./inference/webRuntime";
import { regionOfTarget } from "./inference/core";
import {
  ACCURACY_GRID,
  buildHitTrials,
  heldOutReport,
  hitRateReport,
  HIT_RADII_DEG,
  HIT_TIMEOUT_MS,
  HIT_TRIALS_PER_RADIUS,
  median,
  mmPerPoint,
  shuffled,
  updateHitTrial,
  type Geometry,
  type HitTrial
} from "./accuracyProtocol";
import { logStatus } from "./logger";
import { advanceDotSpring, GAZE_STALE_MS, headTilted, isSaccadeJump, leadTarget, schedulePreviewExpiry, shouldRetryCalibrationCapture, TILT_CLEAR_MS } from "./uiState";
import "./styles.css";

// The away heartbeat variant is a liveness beat with no coordinates —
// GazeState only ever holds the sample-carrying member.
type GazeState = Exclude<Extract<BackendMessage, { type: "gaze" }>, { away: true }> & {
  receivedAt: number;
};

type PreviewState = Extract<BackendMessage, { type: "preview" }> & {
  receivedAt: number;
};

type ModelRuntimeState = {
  detector?: ModelRuntimeInfo;
  gaze?: ModelRuntimeInfo;
};

type ModelRuntimeInfo = {
  runtime: RuntimeName;
  accelerator: string;
};

type ClickEffectState = {
  id: number;
  effect: "single" | "double";
};

// The discrete facets of the gaze stream that are allowed to trigger React
// renders — everything per-frame about a sample lives in refs instead.
type GazePresence = {
  live: boolean; // a fresh frame is held — dot visibility + modal start gates
  ghost: boolean; // blink or head_turned — the dot drops to a faint ghost
  held: boolean; // held_reason — dwell-lock hold, mid-opacity
  dwell: boolean; // gaze_state === "dwell" — the dwell ring class
};
const GAZE_ABSENT: GazePresence = { live: false, ghost: false, held: false, dwell: false };

type DiagnosticsSettings = NonNullable<UserSettings["diagnostics"]>;

// Pursuit calibration (Pfeuffer et al., UIST'13): a dot sweeps a serpentine
// path and the tracker samples continuously — hundreds of labelled points in
// ~20s instead of 13 stare-and-hold captures, with a dwell at each turn so
// the eye can settle at the edges where accuracy matters most.
// Calibration protocol (Tobii's own sequence): the target *glides* to a
// point, parks, shrinks to pull the eye to its center, collects while parked,
// then glides on. Users saccade to the parked dot — nobody chases a moving
// dot. Tiered depth: "full" is the 4×4 grid that reaches the corners the old
// perimeter ring never trained; "quick" is corners+center — the patch for
// weak regions without redoing everything.
const CALIBRATION_TIERS: Record<CalibrationTier, [number, number][]> = {
  // 4×4 serpentine — 16 grid nodes at the real corners/edges the accuracy
  // test hits (0.08/0.92), plus center bookends.
  full: [
    [0.5, 0.5],
    [0.08, 0.08], [0.36, 0.08], [0.64, 0.08], [0.92, 0.08],
    [0.92, 0.36], [0.64, 0.36], [0.36, 0.36], [0.08, 0.36],
    [0.08, 0.64], [0.36, 0.64], [0.64, 0.64], [0.92, 0.64],
    [0.92, 0.92], [0.64, 0.92], [0.36, 0.92], [0.08, 0.92],
    [0.5, 0.5]
  ],
  // 3×3 — corners + edge mids + center.
  standard: [
    [0.5, 0.5],
    [0.09, 0.09], [0.5, 0.09], [0.91, 0.09],
    [0.91, 0.5], [0.91, 0.91], [0.5, 0.91],
    [0.09, 0.91], [0.09, 0.5],
    [0.5, 0.5]
  ],
  // Corners + center — the fast top-up for weak regions.
  quick: [
    [0.5, 0.5],
    [0.08, 0.08], [0.92, 0.08], [0.92, 0.92], [0.08, 0.92],
    [0.5, 0.5]
  ]
};
// Parked pacing: ~0.5s glide between points (Tobii: the animation must not be
// too fast or the eye never settles), then 900ms parked — 300ms to rest the
// eye on it, then the ring contracts and dense samples collect. Features pair
// every frame, so each point yields ~10 labels — dense data without chasing.
const PURSUIT_SPEED = 0.7;
const PURSUIT_DWELL_MS = 900;
const PURSUIT_LEAD_IN_MS = 1400;

// Verification: same park-and-check UX at points the capture never used, so
// the gate measures held-out error honestly instead of in-sample fit.
const VERIFY_WAYPOINTS: [number, number][] = [
  [0.5, 0.5],
  [0.32, 0.3], [0.68, 0.3],
  [0.68, 0.7], [0.32, 0.7],
  [0.5, 0.5]
];
const VERIFY_SPEED = 0.7;
const VERIFY_DWELL_MS = 700;
const VERIFY_LEAD_IN_MS = 700;

// Accuracy test (--accuracy-test): after calibration, the JARA-27 protocol
// v1 held-out grid — 16 targets in random order, 1.5 s each, scoring only
// what lands after the first 0.5 s on frames not flagged blink/held.
// --hit-test appends protocol step 3 (circular-target hit rate). Both run as
// one modal: steps past the grid are hit trials.
const ACCURACY_DWELL_MS = 1500;
const ACCURACY_SETTLE_MS = 500;
const HIT_STEPS = HIT_RADII_DEG.length * HIT_TRIALS_PER_RADIUS;

type AccuracyStep = { kind: "grid"; target: [number, number] } | { kind: "hit"; trial: HitTrial };

// Result/warning messages get this long on the status line before the ~15Hz
// gaze stream is allowed to reassert "tracking" over them.
const STATUS_HOLD_MS = 4000;

// The diagnostics panes are the only render consumers of the per-frame gaze
// numbers — they republish on this cadence instead of at stream rate.
const DIAG_THROTTLE_MS = 500;

// First-run card dismissal persists across renderer reloads: the scrim
// replays only while calibration is genuinely missing AND unanswered.
const ONBOARDING_DISMISSED_KEY = "jev.onboardingDismissed";

function readOnboardingDismissed(): boolean {
  try {
    return window.localStorage.getItem(ONBOARDING_DISMISSED_KEY) === "1";
  } catch {
    return false;
  }
}

interface AccuracyBucket {
  target: [number, number];
  collectFrom: number;
  errors: number[];
  points: [number, number][];
  distances: number[];
  inference: number[];
  intervals: number[];
}

function percentile(sorted: number[], q: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];
}

function buildPursuitTimeline(
  waypoints: [number, number][],
  speed: number,
  dwellMs: number,
  leadInMs: number
): {
  duration: number;
  at: (ms: number) => { pos: [number, number] | null; dwelling: boolean; next: [number, number] | null };
} {
  const segments: Array<{ start: number; end: number; dwellEnd: number; from: [number, number]; to: [number, number] }> = [];
  let t = leadInMs;
  for (let i = 0; i < waypoints.length - 1; i += 1) {
    const from = waypoints[i];
    const to = waypoints[i + 1];
    const travel = (Math.hypot(to[0] - from[0], to[1] - from[1]) / speed) * 1000;
    segments.push({ start: t, end: t + travel, dwellEnd: t + travel + dwellMs, from, to });
    t += travel + dwellMs;
  }
  const duration = t;
  const at = (ms: number): { pos: [number, number] | null; dwelling: boolean; next: [number, number] | null } => {
    const done = { pos: null, dwelling: false, next: null };
    if (ms >= duration) {
      return done;
    }
    for (let i = 0; i < segments.length; i += 1) {
      const s = segments[i];
      const upcoming = segments[i + 1]?.to ?? null;
      if (ms < s.start) {
        // Parked at this leg's origin; `next` shows where it goes next.
        return { pos: s.from, dwelling: true, next: s.to };
      }
      if (ms <= s.end) {
        const k = (ms - s.start) / (s.end - s.start);
        // Smoothstep glide: soft acceleration into the park, never a dart.
        const e = k * k * (3 - 2 * k);
        return { pos: [s.from[0] + (s.to[0] - s.from[0]) * e, s.from[1] + (s.to[1] - s.from[1]) * e], dwelling: false, next: upcoming };
      }
      if (ms < s.dwellEnd) {
        return { pos: s.to, dwelling: true, next: upcoming };
      }
    }
    return { pos: waypoints[waypoints.length - 1], dwelling: true, next: null };
  };
  return { duration, at };
}

function providerToAccelerator(provider: string | undefined): string {
  if (!provider) {
    return "unknown";
  }
  const normalized = provider.toLowerCase();
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
  return provider.replace(/ExecutionProvider$/u, "");
}

function statusRuntime(payload: Extract<BackendMessage, { type: "status" }>, config: RendererConfig | null): RuntimeName {
  return payload.runtime ?? config?.runtime ?? "onnxweb";
}

function statusAccelerator(
  payload: Extract<BackendMessage, { type: "status" }>,
  providers: string[] | undefined
): AcceleratorName | string {
  return payload.accelerator ?? providerToAccelerator(providers?.[0]);
}

function formatMs(value: number | undefined): string | null {
  return value !== undefined && Number.isFinite(value) ? `${value.toFixed(1)}ms` : null;
}

function formatInferenceTime(value: number | undefined): string | null {
  return value !== undefined && Number.isFinite(value) ? `${value.toFixed(2)} ms` : null;
}

// Render-side velocity: finite difference between gaze frames on the CAPTURE
// cadence (frame_interval_ms / captured_at_ms), not IPC arrival — transport
// jitter otherwise reads as motion. Saccade-marked or large-jump frames snap
// the dot instead of touching the EMA: the eye already arrived, and saccadic
// suppression makes the teleport invisible. Returns true when it snapped.
// Runs inside the gaze message handler; the rAF loop only reads the refs.
function updateGazeMotion(
  targetRef: { current: [number, number] | null },
  targetAtRef: { current: number },
  velRef: { current: [number, number] },
  xNorm: number,
  yNorm: number,
  meta: { gazeState?: string; frameIntervalMs?: number; capturedAtMs?: number } = {}
): boolean {
  const next: [number, number] = [xNorm, yNorm];
  if (!Number.isFinite(next[0]) || !Number.isFinite(next[1])) {
    // A non-finite frame would poison the velocity EMA permanently (NaN
    // fails every comparison, so the clamp can never clear it) — drop it.
    velRef.current = [0, 0];
    return false;
  }
  const prev = targetRef.current;
  // targetAt carries wall-clock capture time — Date.now() is shared between
  // the worker and page realms, performance.now() is not.
  const capturedAt = Number.isFinite(meta.capturedAtMs) ? (meta.capturedAtMs as number) : Date.now();
  if (isSaccadeJump(meta.gazeState, prev, next)) {
    velRef.current = [0, 0];
    targetRef.current = next;
    targetAtRef.current = capturedAt;
    return true;
  }
  const prevAt = targetAtRef.current;
  if (prev && prevAt > 0) {
    const dt = meta.frameIntervalMs && meta.frameIntervalMs > 0
      ? Math.min(1, meta.frameIntervalMs / 1000)
      : Math.max(0.001, (capturedAt - prevAt) / 1000);
    let vx = velRef.current[0] + 0.5 * ((next[0] - prev[0]) / dt - velRef.current[0]);
    let vy = velRef.current[1] + 0.5 * ((next[1] - prev[1]) / dt - velRef.current[1]);
    const speed = Math.hypot(vx, vy);
    if (speed > 4) {
      vx *= 4 / speed;
      vy *= 4 / speed;
    }
    velRef.current = [vx, vy];
  }
  targetRef.current = next;
  targetAtRef.current = capturedAt;
  return false;
}

function App() {
  const [config, setConfig] = useState<RendererConfig | null>(null);
  // The ~20Hz gaze stream lives in refs (gazeRef + the motion refs below);
  // React state only carries the discrete presence transitions that gate
  // visibility, plus a ~500ms-throttled copy for the diagnostics panes.
  const [gazePresence, setGazePresence] = useState<GazePresence>(GAZE_ABSENT);
  const [gazeDiag, setGazeDiag] = useState<GazeState | null>(null);
  const [status, setStatus] = useState("starting");
  const [statusLevel, setStatusLevel] = useState<"info" | "warning" | "error">("info");
  const [preview, setPreview] = useState<PreviewState | null>(null);
  const [modelRuntime, setModelRuntime] = useState<ModelRuntimeState>({});
  const [calibrationCountdown, setCalibrationCountdown] = useState<number | null>(null);
  const [calibrationNotice, setCalibrationNotice] = useState<string | null>(null);
  const [calibrationDone, setCalibrationDone] = useState(false);
  const [driftNotice, setDriftNotice] = useState<string | null>(null);
  const [pursuitActive, setPursuitActive] = useState(false);
  const [calibrationTier, setCalibrationTier] = useState<CalibrationTier>("full");
  const [pursuitPhase, setPursuitPhase] = useState<"capture" | "verify">("capture");
  const [pursuitPos, setPursuitPos] = useState<[number, number] | null>(null);
  const [pursuitDwell, setPursuitDwell] = useState(false);
  const [pursuitNext, setPursuitNext] = useState<[number, number] | null>(null);
  const [pursuitProgress, setPursuitProgress] = useState(0);
  const [pursuitRun, setPursuitRun] = useState(0);
  // Pose-hold hint for the pursuit modal — flipped by tick() on transitions
  // only, so the ~60Hz loop doesn't render-spam while the gate is steady.
  const [pursuitPoseHold, setPursuitPoseHold] = useState(false);
  const [accuracyIndex, setAccuracyIndex] = useState<number | null>(null);
  const accuracyCollectRef = useRef<AccuracyBucket | null>(null);
  const accuracyBucketsRef = useRef<AccuracyBucket[]>([]);
  const accuracyStartedRef = useRef(false);
  const accuracyPlanRef = useRef<AccuracyStep[]>([]);
  const hitStateRef = useRef<{ onset: number; insideSince: number | null } | null>(null);
  const hitGeometryRef = useRef<Geometry | null>(null);
  const finalizeAccuracyTestRef = useRef<() => void>(() => undefined);
  // Protocol step 1: wall time from countdown to save, and whether the
  // verify gate passed on the first capture.
  const calibrationStartedAtRef = useRef<number | null>(null);
  const calibrationRunRef = useRef<{ wall_ms: number; first_try_pass: boolean } | null>(null);
  // --calibrate-if-missing: the host's first enable starts calibration itself
  // instead of showing the invitation card.
  const [autoCalibrate, setAutoCalibrate] = useState(false);
  // A Settings-initiated accuracy check: runs grid + hit test like
  // --accuracy-test --hit-test, after its own calibration.
  const [accuracyCheck, setAccuracyCheck] = useState(false);
  const [accuracyMeasureOnly, setAccuracyMeasureOnly] = useState(false);
  const accuracyMeasureOnlyRef = useRef(false);
  // Latest learning progress from the worker — the measure-only report
  // records what map it scored.
  const learningRef = useRef<{ count?: number; learned_median?: number; learned_labels?: number; prior_active?: boolean; settled?: boolean } | null>(null);
  const learningReportAtRef = useRef(0);
  const accuracyCheckRef = useRef(false);
  const autoCalibrateRef = useRef(false);
  autoCalibrateRef.current = autoCalibrate;
  const lastDriftTriggerRef = useRef(0);
  const calibrationActiveRef = useRef(false);
  const accuracyIndexRef = useRef<number | null>(null);
  const [clickEffect, setClickEffect] = useState<ClickEffectState | null>(null);
  const cameraMarkerRef = useRef<HTMLDivElement>(null);
  const gazeDotRef = useRef<HTMLDivElement>(null);
  // Per-frame gaze pipeline — latest sample, presence mirror for transition
  // diffing, the single stale-watchdog timer, the diagnostics throttle stamp,
  // and the dot's target/velocity/display refs the rAF loop reads.
  const gazeRef = useRef<GazeState | null>(null);
  const gazePresenceRef = useRef<GazePresence>(GAZE_ABSENT);
  const gazeStaleTimerRef = useRef(0);
  const diagThrottleRef = useRef(0);
  const gazeTargetRef = useRef<[number, number] | null>(null);
  const gazeTargetAtRef = useRef(0);
  const gazeVelRef = useRef<[number, number]>([0, 0]);
  // Spring velocity — the dot's own motion state, separate from the target
  // velocity estimate in gazeVelRef (which only feeds the capped lead).
  const gazeSpringVelRef = useRef<[number, number]>([0, 0]);
  const gazeDisplayRef = useRef<[number, number] | null>(null);
  const calibrationCountdownRef = useRef<HTMLDivElement>(null);
  const calibrationTargetRef = useRef<HTMLDivElement>(null);
  const calibrationNoticeRef = useRef<HTMLDivElement>(null);
  const driftNoticeRef = useRef<HTMLDivElement>(null);
  const accuracyProgressRef = useRef<HTMLDivElement>(null);
  const calibrationStartedRef = useRef(false);
  const inferenceTimeRef = useRef<HTMLDivElement>(null);
  const previewRef = useRef<HTMLElement>(null);
  const statusRef = useRef<HTMLElement>(null);
  const webRuntimeRef = useRef<WebRuntimeController | null>(null);
  const webRuntimeStartingRef = useRef(false);
  const configRef = useRef<RendererConfig | null>(null);
  const lastVerdictRef = useRef<VerifyVerdict | null>(null);
  // Cancel latch: set by the X button/Escape so the pursuit cleanup aborts
  // (silently) instead of ending (fit+commit) a run the user already left,
  // and the rejected_fit handler doesn't reopen the modal behind them.
  const calibrationCancelledRef = useRef(false);
  // tick() closes each pursuit phase itself; the cleanup checks this so it
  // doesn't call pursuitEnd a second time (duplicate finishVerify/commitPending).
  const pursuitEndedRef = useRef(false);
  // True only while the mounted pursuit effect actually opened a worker run —
  // a stale cleanup must not end/abort a run owned by a newer instance.
  const pursuitBegunRef = useRef(false);
  // Set when the countdown finished before the web runtime landed (model
  // build can outlast it by seconds) — the modal holds on a "starting up"
  // notice and the runtime promise kicks the pursuit effect back in.
  const pursuitAwaitingRuntimeRef = useRef(false);
  // A rejected_fit inside the tick marks the run settled — retry queued or
  // modal closed at the limit — so the loop must not march into verify.
  const pursuitRejectedRef = useRef(false);
  // Retry copy queued by rejected_fit for the run it's about to restart — the
  // effect's default notice would overwrite it in the same commit otherwise.
  const pursuitRetryNoticeRef = useRef<string | null>(null);
  // Pose gate: each tilted gaze frame pushes this wall-clock deadline out by
  // TILT_CLEAR_MS. While Date.now() is inside it, the pursuit tick stops
  // forwarding pursuit_target — the worker's freshness window closes and
  // those frames never become fit or verify samples. The mirror ref lets
  // tick() flip the hint state on transitions only.
  const poseBlockedUntilRef = useRef(0);
  const pursuitPoseHoldRef = useRef(false);
  // Consecutive rejected_fit retries — bounded so a fit that keeps failing the
  // gate can't reopen the modal forever.
  const rejectedFitRetriesRef = useRef(0);
  // Gaze frames would re-stamp "tracking" over result/error text within ~30ms;
  // held messages keep the status line until this timestamp.
  const statusHoldUntilRef = useRef(0);
  // Presence: paused freezes the dot as a ghost; onboarding is the first-run
  // card shown when no calibration file exists yet.
  const [paused, setPaused] = useState(false);
  const pausedRef = useRef(false);
  const [onboarding, setOnboarding] = useState(false);
  const onboardingRef = useRef(false);
  // Lazily seeded from localStorage so a renderer reload doesn't replay the
  // scrim after the user already dismissed it (or finished calibrating).
  const onboardingDismissedRef = useRef<boolean | null>(null);
  if (onboardingDismissedRef.current === null) {
    onboardingDismissedRef.current = readOnboardingDismissed();
  }
  const [calibratedFlash, setCalibratedFlash] = useState(false);
  // Camera marker: a ~5s orientation hint, then it fades unless pinned on.
  const [markerVisible, setMarkerVisible] = useState(true);
  const markerTimerRef = useRef(0);
  const markerShownRef = useRef(true);
  // Persisted presence settings + diagnostics toggles (settings live in the
  // main process; refs mirror them so stable handlers read the latest).
  const [diagnostics, setDiagnostics] = useState<DiagnosticsSettings>({});
  const diagnosticsRef = useRef<DiagnosticsSettings>({});
  const settingsRef = useRef<UserSettings>({});
  // Gaze-cursor visibility — default hidden (Vision Pro style: the
  // element's own highlight, not a floating dot, says where you point).
  // Modals already suppress the render; this is the normal-tracking gate.
  const [dotVisible, setDotVisible] = useState(false);
  const dotVisibleRef = useRef(false);
  // Keys the user changed locally before getSettings resolved — the
  // persisted read must not overwrite a just-applied toggle.
  const settingsDirtyKeysRef = useRef<Set<string>>(new Set());
  const calibrationStatusRef = useRef<string | null>(null);
  const hintTimerRef = useRef(0);

  useEffect(() => {
    configRef.current = config;
  }, [config]);

  const showStatus = useCallback((message: string, level: "info" | "warning" | "error") => {
    statusHoldUntilRef.current = Date.now() + STATUS_HOLD_MS;
    setStatus(message);
    setStatusLevel(level);
  }, []);

  // Single entry for user-invoked calibration — the menu action and the
  // first-run card all funnel through the countdown → pursuit path.
  const applyPausedState = useCallback((next: boolean) => {
    pausedRef.current = next;
    setPaused(next);
    webRuntimeRef.current?.setPaused?.(next);
    window.gazeBridge.setPaused?.(next);
    window.gazeBridge.reportState?.({ paused: next });
  }, []);

  // Answering the card — or finishing a calibration — persists the dismissal
  // so a renderer reload doesn't replay the scrim over a live session.
  const dismissOnboarding = useCallback(() => {
    onboardingDismissedRef.current = true;
    onboardingRef.current = false;
    setOnboarding(false);
    try {
      window.localStorage.setItem(ONBOARDING_DISMISSED_KEY, "1");
    } catch {
      // Storage can be unavailable — the ref still covers this session.
    }
  }, []);

  // The single stale watchdog — every gaze frame re-arms it, so it fires only
  // when the stream stops. Mirrors the old setGaze(null) cascade (presence
  // off, motion refs dropped, diagnostics hidden) as one discrete render.
  const handleGazeStale = useCallback(() => {
    gazeStaleTimerRef.current = 0;
    gazeRef.current = null;
    gazeTargetRef.current = null;
    gazeTargetAtRef.current = 0;
    gazeVelRef.current = [0, 0];
    gazeSpringVelRef.current = [0, 0];
    if (!pausedRef.current) {
      // Paused keeps the frozen ghost's position — it is still displayed.
      gazeDisplayRef.current = null;
    }
    if (gazePresenceRef.current !== GAZE_ABSENT) {
      gazePresenceRef.current = GAZE_ABSENT;
      setGazePresence(GAZE_ABSENT);
    }
    setGazeDiag(null);
  }, []);

  const beginCalibration = useCallback((tier: CalibrationTier) => {
    if (calibrationActiveRef.current || accuracyIndexRef.current !== null) {
      return;
    }
    // A paused worker would drop every pursuit frame into a guaranteed
    // rejected fit — intent to calibrate is intent to track, so unpause.
    if (pausedRef.current) {
      applyPausedState(false);
    }
    // Mirrored synchronously — the passive effect below lands a commit late,
    // and menu_action guards read these refs between renders.
    calibrationActiveRef.current = true;
    // A user-invoked run also satisfies the --calibrate auto-start — without
    // this the first live gaze frame would queue a second countdown over (or
    // behind) this one, swapping the tier mid-flight.
    calibrationStartedRef.current = true;
    lastDriftTriggerRef.current = Date.now();
    setDriftNotice(null);
    onboardingRef.current = false;
    setOnboarding(false);
    setCalibrationDone(false);
    // Fresh user-invoked run — clear the cancel/end/retry latches.
    calibrationCancelledRef.current = false;
    pursuitEndedRef.current = false;
    rejectedFitRetriesRef.current = 0;
    setCalibrationTier(tier);
    setCalibrationNotice("calibrating — just look at the dot when it stops");
    calibrationStartedAtRef.current = Date.now();
    setCalibrationCountdown(3);
  }, [applyPausedState]);

  const flashCameraMarker = useCallback(() => {
    window.clearTimeout(markerTimerRef.current);
    setMarkerVisible(true);
    markerTimerRef.current = window.setTimeout(() => setMarkerVisible(false), 5000);
  }, []);

  // Brief top-of-screen hint — same pill as the drift warning, but it clears
  // itself (and never clears a newer warning that replaced it).
  const flashHint = useCallback((message: string) => {
    window.clearTimeout(hintTimerRef.current);
    setDriftNotice(message);
    hintTimerRef.current = window.setTimeout(() => {
      setDriftNotice((current) => (current === message ? null : current));
    }, 4000);
  }, []);

  const persistSettings = useCallback((patch: Partial<UserSettings>) => {
    Object.keys(patch).forEach((key) => settingsDirtyKeysRef.current.add(key));
    settingsRef.current = { ...settingsRef.current, ...patch };
    window.gazeBridge.setSettings?.(patch);
    window.gazeBridge.reportState?.({ settings: settingsRef.current });
  }, []);

  const applyDiagnostics = useCallback((patch: Partial<DiagnosticsSettings>) => {
    const next = { ...diagnosticsRef.current, ...patch };
    diagnosticsRef.current = next;
    setDiagnostics(next);
    settingsDirtyKeysRef.current.add("diagnostics");
    if (patch.preview !== undefined) {
      webRuntimeRef.current?.setPreviewEnabled(patch.preview);
    }
    settingsRef.current = { ...settingsRef.current, diagnostics: next };
    window.gazeBridge.setSettings?.({ diagnostics: next });
    window.gazeBridge.reportState?.({ settings: settingsRef.current });
  }, []);

  const handleBackendMessage = useCallback((payload: BackendMessage) => {
    if (payload.type === "gaze") {
      if ("away" in payload) {
        // Liveness heartbeat, not a sample — it exists to keep the store's
        // gaze.updated_at fresh (publishBackendMessage above already did)
        // so the host's wedge watch can't read a healthy-but-empty pipeline
        // as dead. It carries no coordinates: no gazeRef, no motion, no
        // presence flip, and crucially NO stale-timer re-arm — the dot must
        // still expire on GAZE_STALE_MS while nobody's in front.
        return;
      }
      const receivedAt = Date.now();
      const sample: GazeState = { ...payload, receivedAt };
      gazeRef.current = sample;
      const snapped = updateGazeMotion(gazeTargetRef, gazeTargetAtRef, gazeVelRef, payload.x_norm, payload.y_norm, {
        gazeState: payload.gaze_state,
        frameIntervalMs: payload.frame_interval_ms,
        capturedAtMs: payload.captured_at_ms
      });
      if (snapped) {
        // Saccade: the eye already landed — teleport under suppression,
        // kill both velocities so nothing coasts or chases across the jump.
        gazeDisplayRef.current = [payload.x_norm, payload.y_norm];
        gazeSpringVelRef.current = [0, 0];
      }
      // Exactly one pending expiry: whichever frame arrives last leaves the
      // timer that flips presence off GAZE_STALE_MS after the stream stops.
      window.clearTimeout(gazeStaleTimerRef.current);
      gazeStaleTimerRef.current = window.setTimeout(handleGazeStale, GAZE_STALE_MS);
      const prev = gazePresenceRef.current;
      if (!prev.live && !pausedRef.current) {
        // A resuming stream snaps the dot to the new target instead of easing
        // over from wherever it faded — same as the old null→fresh path.
        gazeDisplayRef.current = null;
        gazeSpringVelRef.current = [0, 0];
      }
      // Presence-facet transitions are the only per-frame renders left;
      // identical facets skip the setState entirely.
      const next: GazePresence = {
        live: true,
        ghost: payload.blink === true || payload.head_turned === true,
        held: Boolean(payload.held_reason),
        dwell: payload.gaze_state === "dwell"
      };
      if (prev.live !== next.live || prev.ghost !== next.ghost || prev.held !== next.held || prev.dwell !== next.dwell) {
        gazePresenceRef.current = next;
        setGazePresence(next);
      }
      // Diagnostics text is the only render consumer of per-frame numbers —
      // throttled to ~2Hz, and skipped entirely while the panes are off.
      const diagnosticsOn =
        (diagnosticsRef.current.status ?? Boolean(configRef.current?.debug)) ||
        (diagnosticsRef.current.inference_time ?? Boolean(configRef.current?.enableInferenceTime));
      if (diagnosticsOn && receivedAt - diagThrottleRef.current >= DIAG_THROTTLE_MS) {
        diagThrottleRef.current = receivedAt;
        setGazeDiag(sample);
      }
      // "tracking" is transient — it must not overwrite a held result/error.
      if (receivedAt >= statusHoldUntilRef.current) {
        setStatus("tracking");
        setStatusLevel("info");
      }
      // Pose-gate bookkeeping: this handler is the only place per-frame
      // yaw/pitch lands. Tilted frames push the hold deadline out — the
      // pursuit tick reads it to pause sample forwarding until the pose has
      // read level for TILT_CLEAR_MS. Absent angles never push it, so
      // missing telemetry can't stall the run.
      if (headTilted(payload.yaw_deg, payload.pitch_deg)) {
        poseBlockedUntilRef.current = receivedAt + TILT_CLEAR_MS;
      }
      // Accuracy-test collection in display points, plus perf counters.
      // Blink, held and head-turned frames are the protocol's discards.
      const bounds = configRef.current?.displayBounds;
      const w = bounds?.width ?? window.innerWidth;
      const h = bounds?.height ?? window.innerHeight;
      const usable = !payload.blink && !payload.held_reason && !payload.head_turned;
      const bucket = accuracyCollectRef.current;
      if (bucket && receivedAt >= bucket.collectFrom && usable) {
        bucket.errors.push(Math.hypot((payload.x_norm - bucket.target[0]) * w, (payload.y_norm - bucket.target[1]) * h));
        bucket.points.push([payload.x_norm * w, payload.y_norm * h]);
        if (Number.isFinite(payload.distance_m)) bucket.distances.push(payload.distance_m);
        if (payload.inference_ms !== undefined) bucket.inference.push(payload.inference_ms);
        if (payload.frame_interval_ms !== undefined) bucket.intervals.push(payload.frame_interval_ms);
      }
      const step = accuracyIndexRef.current !== null ? accuracyPlanRef.current[accuracyIndexRef.current] : undefined;
      const hitState = hitStateRef.current;
      const hitGeometry = hitGeometryRef.current;
      if (step?.kind === "hit" && hitState && hitGeometry && step.trial.hit === null) {
        const gazePt: [number, number] | null = usable ? [payload.x_norm * w, payload.y_norm * h] : null;
        if (updateHitTrial(step.trial, hitState, gazePt, hitGeometry, receivedAt)) {
          const next = accuracyIndexRef.current! + 1;
          setAccuracyIndex(next < accuracyPlanRef.current.length ? next : null);
          if (next >= accuracyPlanRef.current.length) {
            finalizeAccuracyTestRef.current();
          }
        }
      }
    } else if (payload.type === "status") {
      if (!payload.logged) {
        logStatus(payload);
      }
      showStatus(payload.message, payload.level);
      // Drift alarm from the worker: implicit labels keep landing in one
      // consistent direction off the map — the camera/laptop moved. Warn the
      // user instead of hijacking the screen; they trigger the quick
      // recalibration from the menu or by voice when they choose.
      if (
        payload.message === "drift_detected" &&
        Date.now() - lastDriftTriggerRef.current > 120_000 &&
        !calibrationActiveRef.current &&
        accuracyIndexRef.current === null
      ) {
        lastDriftTriggerRef.current = Date.now();
        setDriftNotice("Tracking feels off? Say “recalibrate” for a 10-second retune");
      }
      if (payload.detector_providers || payload.gaze_providers) {
        setModelRuntime((current) => ({
          detector: payload.detector_providers
            ? {
                runtime: statusRuntime(payload, configRef.current),
                accelerator: statusAccelerator(payload, payload.detector_providers)
              }
            : current.detector,
          gaze: payload.gaze_providers
            ? {
                runtime: statusRuntime(payload, configRef.current),
                accelerator: statusAccelerator(payload, payload.gaze_providers)
              }
            : current.gaze
        }));
      }
    } else if (payload.type === "preview") {
      setPreview({ ...payload, receivedAt: Date.now() });
    } else if (payload.type === "lip_click_effect") {
      setClickEffect((current) => ({
        id: (current?.id ?? 0) + 1,
        effect: payload.effect
      }));
    } else if (payload.type === "calibration") {
      // Keep the host's shared-state snapshot current — reported once per
      // status value so pursuit_sampled progress doesn't spam IPC. A geometry
      // retune is not a calibration state; under --learn-if-missing a missing
      // calibration is the learning state, and a settled learned map reads as
      // loaded.
      const learnMissing = payload.status === "missing" && configRef.current?.learnIfMissing === true;
      const reported =
        payload.status === "geometry"
          ? null
          : learnMissing || (payload.status === "learning" && !payload.settled)
            ? "learning"
            : payload.status === "learning"
              ? "loaded"
              : payload.status;
      if (reported !== null && calibrationStatusRef.current !== reported) {
        calibrationStatusRef.current = reported;
        window.gazeBridge.reportState?.({ calibration_status: reported });
      }
      if (payload.status === "learning") {
        // The running out-of-sample label error is the host's gaze spread
        // while no calibration or accuracy run is newer (GazeErrorBand reads
        // the newest report). Same √(w·h) points convention as the
        // calibration report; written at most every 10 s.
        learningRef.current = {
          count: payload.count,
          learned_median: payload.learned_median,
          learned_labels: payload.learned_labels,
          prior_active: payload.prior_active,
          settled: payload.settled
        };
        if (payload.learned_median !== undefined && Date.now() - learningReportAtRef.current >= 10_000) {
          learningReportAtRef.current = Date.now();
          const bounds = configRef.current?.displayBounds;
          const scale = Math.sqrt((bounds?.width ?? window.innerWidth) * (bounds?.height ?? window.innerHeight));
          void window.gazeBridge
            .writeReport("learning_report.json", {
              kind: "implicit",
              created_at: new Date().toISOString(),
              detector: configRef.current?.webInference?.detector,
              median_pt: payload.learned_median * scale,
              labels: payload.learned_labels,
              personal_samples: payload.count,
              prior_active: payload.prior_active,
              settled: payload.settled
            })
            .catch((error) => console.error("Learning report write failed", error));
        }
        return;
      }
      if (payload.status === "missing" && !learnMissing) {
        // First run: no calibration on disk — invite, don't hijack. Under the
        // host's --calibrate-if-missing (first enable) it starts directly; a
        // "not now" from an earlier run still holds.
        if (!calibrationActiveRef.current && accuracyIndexRef.current === null && !onboardingDismissedRef.current) {
          if (configRef.current?.calibrateIfMissing) {
            setAutoCalibrate(true);
          } else {
            onboardingRef.current = true;
            setOnboarding(true);
          }
        }
      } else if (payload.status === "loaded" || payload.status === "invalid") {
        onboardingRef.current = false;
        setOnboarding(false);
        if (payload.status === "invalid") {
          flashHint("Say “recalibrate” any time to calibrate");
        }
      }
      if (payload.status === "pursuit_sampled" && payload.count !== undefined) {
        // Routine progress stays info — the amber is reserved for real failures.
        showStatus(`calibration: following — ${payload.count} samples`, "info");
      } else {
        // Routine outcomes aren't warnings — amber is for states needing
        // action (missing/invalid/rejected/save_failed).
        const routine = payload.status === "saved" || payload.status === "loaded" || payload.status === "geometry";
        showStatus(
          `calibration: ${payload.status}${payload.count !== undefined ? ` ${payload.count} samples` : ""}${payload.message ? ` — ${payload.message}` : ""}`,
          routine ? "info" : "warning"
        );
      }
      if (payload.status === "saved") {
        if (calibrationStartedAtRef.current !== null) {
          calibrationRunRef.current = {
            wall_ms: Date.now() - calibrationStartedAtRef.current,
            first_try_pass: rejectedFitRetriesRef.current === 0
          };
          calibrationStartedAtRef.current = null;
        }
        // The verify pass's held-out error, in display points, is the
        // host's measured gaze spread until an accuracy test supersedes it
        // (GazeErrorBand reads whichever report is newer). Verify errors are
        // normalized, so √(w·h) converts them without an axis bias.
        const verdict = payload.verdict ?? lastVerdictRef.current;
        if (verdict) {
          const bounds = configRef.current?.displayBounds;
          const scale = Math.sqrt((bounds?.width ?? window.innerWidth) * (bounds?.height ?? window.innerHeight));
          void window.gazeBridge
            .writeReport("calibration_report.json", {
              kind: "calibration",
              created_at: new Date().toISOString(),
              detector: configRef.current?.webInference?.detector,
              verdict,
              median_pt: verdict.median * scale,
              p90_pt: verdict.p90 * scale,
              calibration_run: calibrationRunRef.current
            })
            .catch((error) => console.error("Calibration report write failed", error));
        }
        rejectedFitRetriesRef.current = 0;
        // The accuracy run shows its own report flow — no confetti on top.
        if (!configRef.current?.accuracyTest && !configRef.current?.hitTest && !accuracyCheckRef.current) {
          setCalibratedFlash(true);
        }
        dismissOnboarding();
        setCalibrationDone(true);
        setCalibrationCountdown(null);
        setCalibrationNotice(null);
        setDriftNotice(null);
        setPursuitActive(false);
        setPursuitPos(null);
      } else if (payload.status === "rejected_fit") {
        // A reject that lands after the user cancelled must not reopen the modal.
        if (!calibrationCancelledRef.current) {
          // Marks the phase's run as settled for the pursuit tick — it can
          // emit synchronously inside pursuitEnd() on the in-page runtimes.
          pursuitRejectedRef.current = true;
          if (rejectedFitRetriesRef.current >= 2) {
            // Bounded retry — a fit that keeps failing the gate would otherwise
            // loop the modal forever; show the reason and stand down.
            setCalibrationNotice(payload.message ?? "Calibration did not validate — say “recalibrate” to try again");
            setPursuitActive(false);
            setPursuitPos(null);
          } else {
            rejectedFitRetriesRef.current += 1;
            // The notice is queued on a ref: the restarted effect writes its
            // own notice in the same commit and would stomp a setState here.
            pursuitRetryNoticeRef.current = payload.message ?? "That didn't take — one more pass";
            setPursuitActive(true);
            setPursuitRun((value) => value + 1);
          }
        }
      } else if (shouldRetryCalibrationCapture(payload.status)) {
        setCalibrationNotice(payload.message ?? "Could not save calibration");
      }
      if (payload.verdict) {
        lastVerdictRef.current = payload.verdict;
      }
    } else if (payload.type === "cursor_idle") {
      // Implicit calibration label (COMETIC/WebGazer): a cursor rest, a click,
      // a voice-named pick or the text caret — a free ground-truth pair the
      // worker weighs by kind.
      webRuntimeRef.current?.implicitSample(payload.x_norm, payload.y_norm, payload.kind);
    } else if (payload.type === "menu_action") {
      if (payload.action === "pause_toggle") {
        // Presence is a user toggle — never flip it mid-modal.
        if (calibrationActiveRef.current || accuracyIndexRef.current !== null || onboardingRef.current) {
          return;
        }
        applyPausedState(!pausedRef.current);
      } else if (payload.action === "set_paused") {
        // Host-driven target state (screen-lock parking) — deterministic,
        // not a toggle, so a double-lock or a queued redelivery can't flip
        // the flag. A mid-modal arrival still applies: lock-pausing a
        // calibration screen is correct, and resume replays nothing.
        applyPausedState(payload.value === true);
      } else if (payload.action === "recalibrate") {
        // Menu entry — the quick top-up.
        beginCalibration("quick");
      } else if (payload.action === "accuracy_check") {
        // Settings → "Check eye-tracking accuracy": a full calibration, then
        // the held-out grid and the hit test, without any launch flags.
        // { measure_only: true } skips the calibration and scores whatever
        // map is live — how good invisible calibration has become.
        if (calibrationActiveRef.current || accuracyIndexRef.current !== null) {
          return;
        }
        const measureOnly = (payload.value as { measure_only?: unknown } | undefined)?.measure_only === true;
        accuracyStartedRef.current = false;
        accuracyCheckRef.current = true;
        accuracyMeasureOnlyRef.current = measureOnly;
        setAccuracyMeasureOnly(measureOnly);
        setAccuracyCheck(true);
        if (!measureOnly) {
          beginCalibration("full");
        }
      } else if (payload.action === "dot_scale") {
        const scale =
          typeof payload.value === "number" && Number.isFinite(payload.value)
            ? Math.min(3, Math.max(0.5, payload.value))
            : null;
        if (scale !== null) {
          // On :root so the dot's key-remount (click effects) keeps it.
          document.documentElement.style.setProperty("--dot-scale", String(scale));
          persistSettings({ dot_scale: scale });
        }
      } else if (payload.action === "gaze_dot") {
        const show = payload.value === undefined
          ? !dotVisibleRef.current
          : Boolean(payload.value);
        dotVisibleRef.current = show;
        setDotVisible(show);
        persistSettings({ gaze_dot_visible: show });
      } else if (payload.action === "dwell_lock") {
        const lock = payload.value === undefined ? !settingsRef.current.dwell_lock : Boolean(payload.value);
        webRuntimeRef.current?.setFilterOptions?.({ dwellLock: lock });
        persistSettings({ dwell_lock: lock });
      } else if (payload.action === "preview_toggle") {
        applyDiagnostics({ preview: payload.value === undefined ? !diagnosticsRef.current.preview : Boolean(payload.value) });
      } else if (payload.action === "status_toggle") {
        applyDiagnostics({ status: payload.value === undefined ? !diagnosticsRef.current.status : Boolean(payload.value) });
      } else if (payload.action === "inference_time_toggle") {
        applyDiagnostics({ inference_time: payload.value === undefined ? !diagnosticsRef.current.inference_time : Boolean(payload.value) });
      } else if (payload.action === "show_marker") {
        flashCameraMarker();
      }
    }
  }, [showStatus, beginCalibration, applyPausedState, flashCameraMarker, flashHint, persistSettings, applyDiagnostics, handleGazeStale, dismissOnboarding]);

  const handleRendererRuntimeMessage = useCallback(
    (payload: BackendMessage) => {
      window.gazeBridge.publishBackendMessage(payload);
      handleBackendMessage(payload);
    },
    [handleBackendMessage]
  );

  useEffect(() => {
    window.gazeBridge
      .getConfig()
      .then(setConfig)
      .catch((error) => {
        // A rejected invoke must surface — without it the overlay boots
        // blank and silent, and the tracker claims a state it isn't in.
        console.error("Failed to load renderer config", error);
        handleRendererRuntimeMessage({
          type: "status",
          level: "error",
          message: `Renderer config failed to load: ${error instanceof Error ? error.message : String(error)}`
        });
      });
    const unsubscribe = window.gazeBridge.onBackendMessage(handleBackendMessage);
    window.gazeBridge.ready();
    return unsubscribe;
  }, [handleBackendMessage, handleRendererRuntimeMessage]);

  useEffect(() => {
    if (!config?.webInference || webRuntimeRef.current || webRuntimeStartingRef.current) {
      return;
    }
    let cancelled = false;
    webRuntimeStartingRef.current = true;
    startWebRuntime(config.webInference, handleRendererRuntimeMessage)
      .then((runtime) => {
        webRuntimeStartingRef.current = false;
        if (cancelled) {
          runtime.stop();
          return;
        }
        webRuntimeRef.current = runtime;
        // Re-apply presence/settings resolved while the runtime was starting.
        runtime.setPaused(pausedRef.current);
        if (diagnosticsRef.current.preview !== undefined) {
          runtime.setPreviewEnabled(diagnosticsRef.current.preview);
        }
        if (settingsRef.current.dwell_lock !== undefined) {
          runtime.setFilterOptions({ dwellLock: settingsRef.current.dwell_lock });
        }
        // A pursuit run that stalled waiting on this controller re-enters the
        // effect now — the modal stayed up on the "starting up" notice.
        if (pursuitAwaitingRuntimeRef.current) {
          pursuitAwaitingRuntimeRef.current = false;
          setPursuitRun((value) => value + 1);
        }
      })
      .catch((error) => {
        webRuntimeStartingRef.current = false;
        console.error("Failed to start web runtime", error);
        handleRendererRuntimeMessage({
          type: "status",
          level: "error",
          message: error instanceof Error ? error.message : String(error),
          runtime: config.webInference?.runtime
        });
        if (!cancelled && pursuitAwaitingRuntimeRef.current) {
          // The wait is hopeless — close the modal instead of leaving the
          // scrim up on a "starting up" notice that will never resolve.
          pursuitAwaitingRuntimeRef.current = false;
          setPursuitActive(false);
          setPursuitPos(null);
          setCalibrationNotice("Tracking failed to start — say “recalibrate” to try again");
        }
      });
    return () => {
      cancelled = true;
      webRuntimeStartingRef.current = false;
      webRuntimeRef.current?.stop();
      webRuntimeRef.current = null;
    };
  }, [config?.webInference, handleRendererRuntimeMessage]);

  // Restore persisted presence settings once config has arrived (the runtime
  // may still be starting — setFilterOptions applies whenever it lands is not
  // guaranteed, so dwell_lock re-applies below if a runtime already exists).
  useEffect(() => {
    if (!config) {
      return;
    }
    const pending = window.gazeBridge.getSettings?.();
    if (!pending) {
      return;
    }
    let disposed = false;
    pending
      .then((settings) => {
        if (disposed || !settings) {
          return;
        }
        // Local-wins merge: a toggle flipped while this read was in flight
        // outranks the stale persisted value.
        const merged: UserSettings = { ...settings };
        for (const key of settingsDirtyKeysRef.current) {
          const value = settingsRef.current[key as keyof UserSettings];
          if (value !== undefined) {
            (merged as Record<string, unknown>)[key] = value;
          }
        }
        settingsRef.current = { ...settingsRef.current, ...merged };
        if (typeof merged.dot_scale === "number" && Number.isFinite(merged.dot_scale)) {
          document.documentElement.style.setProperty("--dot-scale", String(Math.min(3, Math.max(0.5, merged.dot_scale))));
        }
        if (merged.gaze_dot_visible !== undefined) {
          const show = merged.gaze_dot_visible === true;
          dotVisibleRef.current = show;
          setDotVisible(show);
        }
        if (merged.dwell_lock !== undefined) {
          webRuntimeRef.current?.setFilterOptions?.({ dwellLock: merged.dwell_lock });
        }
        if (merged.show_camera_marker_on_start === false) {
          window.clearTimeout(markerTimerRef.current);
          setMarkerVisible(false);
        }
        if (merged.diagnostics) {
          const next = { ...diagnosticsRef.current, ...merged.diagnostics };
          diagnosticsRef.current = next;
          setDiagnostics(next);
        }
        window.gazeBridge.reportState?.({
          settings: settingsRef.current,
          ...(calibrationStatusRef.current ? { calibration_status: calibrationStatusRef.current } : {})
        });
      })
      .catch(() => {
        // The settings store is a host nicety — never block tracking on it.
      });
    return () => {
      disposed = true;
    };
  }, [config]);

  // Startup camera hint: ~5s of "camera is here", then it fades away.
  useEffect(() => {
    markerTimerRef.current = window.setTimeout(() => setMarkerVisible(false), 5000);
    return () => window.clearTimeout(markerTimerRef.current);
  }, []);

  // "Calibrated" is a moment, not a state — self-dismissing flash.
  useEffect(() => {
    if (!calibratedFlash) {
      return;
    }
    const timer = window.setTimeout(() => setCalibratedFlash(false), 1600);
    return () => window.clearTimeout(timer);
  }, [calibratedFlash]);

  useEffect(() => {
    if (!(config?.calibrate || autoCalibrate) || calibrationDone || calibrationStartedRef.current) {
      return;
    }
    if (!gazePresence.live) {
      return;
    }
    calibrationStartedRef.current = true;
    // A real run beginning takes the screen — the first-run card must not
    // linger over the countdown.
    onboardingRef.current = false;
    setOnboarding(false);
    // New run, clean latches — a leftover cancel/end/retry flag from a previous
    // run must not leak into this one's cleanup.
    calibrationCancelledRef.current = false;
    pursuitEndedRef.current = false;
    rejectedFitRetriesRef.current = 0;
    setCalibrationTier(config?.calibrationTier ?? "full");
    setCalibrationNotice("calibrating — just look at the dot when it stops");
    calibrationStartedAtRef.current = Date.now();
    setCalibrationCountdown(3);
  }, [config?.calibrate, config?.calibrationTier, autoCalibrate, calibrationDone, gazePresence.live]);

  // The Recalibrate menu action (tray, Jarvis menu, POST /control) is the user-invoked
  // recalibration path — also what the drift notice points at. It's the
  // top-up: corners+center quick pass, not the full tour.
  useEffect(() => {
    return window.gazeBridge.onRecalibrate(() => beginCalibration("quick"));
  }, [beginCalibration]);

  useEffect(() => {
    if (calibrationCountdown === null || calibrationDone) {
      return;
    }
    const countdownTimer = window.setTimeout(() => {
      if (calibrationCountdown > 1) {
        setCalibrationCountdown(calibrationCountdown - 1);
      } else {
        setCalibrationCountdown(null);
        setPursuitActive(true);
      }
    }, 1000);
    return () => window.clearTimeout(countdownTimer);
  }, [calibrationCountdown, calibrationDone]);

  useEffect(() => {
    if (!pursuitActive) {
      return;
    }
    const runtime = webRuntimeRef.current;
    if (!runtime) {
      if (!webRuntimeStartingRef.current) {
        // No start in flight — either webInference is off or the boot already
        // failed, so nobody is coming. Close the modal on the honest dead end
        // instead of holding the scrim on a wait that can never resolve.
        setPursuitActive(false);
        setPursuitPos(null);
        setCalibrationNotice("Tracking isn't running — say “recalibrate” after it starts");
        return;
      }
      // Model build/warm-up can outlast the countdown — hold the modal and
      // re-enter when the controller lands (or fails) instead of stranding
      // the user on a "starting up" notice that never resolves.
      pursuitAwaitingRuntimeRef.current = true;
      setCalibrationNotice("Tracking is starting up…");
      return;
    }
    pursuitAwaitingRuntimeRef.current = false;
    // A new run starts with clean latches — a stale cancel/end flag from the
    // previous run must not turn this run's cleanup into an abort or no-op.
    calibrationCancelledRef.current = false;
    pursuitEndedRef.current = false;
    pursuitRejectedRef.current = false;
    pursuitBegunRef.current = true;
    const captureTimeline = buildPursuitTimeline(CALIBRATION_TIERS[calibrationTier], PURSUIT_SPEED, PURSUIT_DWELL_MS, PURSUIT_LEAD_IN_MS);
    const verifyTimeline = buildPursuitTimeline(VERIFY_WAYPOINTS, VERIFY_SPEED, VERIFY_DWELL_MS, VERIFY_LEAD_IN_MS);
    let phase: "capture" | "verify" = "capture";
    let phaseStart = performance.now();
    setPursuitPhase("capture");
    setCalibrationNotice(pursuitRetryNoticeRef.current ?? "look at the dot — no need to chase it");
    pursuitRetryNoticeRef.current = null;
    runtime.pursuitBegin("capture");
    let raf = 0;
    const tick = (now: number) => {
      const timeline = phase === "capture" ? captureTimeline : verifyTimeline;
      const sample = timeline.at(now - phaseStart);
      if (sample.pos === null) {
        setPursuitDwell(false);
        setPursuitNext(null);
        if (phase === "capture") {
          // finishPursuit can emit rejected_fit synchronously inside this
          // call — the flag marks the run as settled (a retry owns the screen
          // now, or the retry limit closed the modal), so the loop must not
          // march into a verify leg whose outcome is already decided.
          runtime.pursuitEnd();
          pursuitEndedRef.current = true;
          const superseded = pursuitRejectedRef.current;
          pursuitRejectedRef.current = false;
          if (!superseded && !calibrationCancelledRef.current) {
            phase = "verify";
            phaseStart = now;
            setPursuitPhase("verify");
            setCalibrationNotice("almost done — look at each dot as it stops");
            runtime.pursuitBegin("verify");
            // The verify phase is now the in-flight run — it owns the end flag.
            pursuitEndedRef.current = false;
            raf = window.requestAnimationFrame(tick);
          }
          return;
        }
        // finishVerify can reject synchronously inside pursuitEnd — the modal
        // must come down BEFORE the call so the reject's retry/notice updates
        // land last instead of being swallowed by this teardown's batch.
        setPursuitActive(false);
        setPursuitPos(null);
        setCalibrationNotice(null);
        runtime.pursuitEnd();
        pursuitEndedRef.current = true;
        return;
      }
      const elapsed = now - phaseStart;
      const share = phase === "capture" ? 0.75 : 0.25;
      const base = phase === "capture" ? 0 : 0.75;
      setPursuitProgress(Math.min(1, base + (elapsed / timeline.duration) * share));
      setPursuitPos(sample.pos);
      setPursuitDwell(sample.dwelling);
      setPursuitNext(sample.dwelling ? null : sample.next);
      // Pose gate: a tilted head bends the eye→screen map the fit can't see,
      // so while the hold deadline is live the target stream pauses — the
      // worker stops sampling ~250ms after the last forwarded message and
      // those frames never count toward the fit or the verify tally. The
      // dot's own motion is untouched: we gate label collection, not the
      // animation.
      const poseBlocked = Date.now() < poseBlockedUntilRef.current;
      if (poseBlocked !== pursuitPoseHoldRef.current) {
        pursuitPoseHoldRef.current = poseBlocked;
        setPursuitPoseHold(poseBlocked);
      }
      // Only collect while parked: during the glide the user is saccading to
      // the target, so those frames are noise, not labels (Tobii likewise
      // collects only after the eye settles on the shrunken point).
      if (sample.dwelling && !poseBlocked) {
        runtime.pursuitTarget(sample.pos[0], sample.pos[1]);
      }
      raf = window.requestAnimationFrame(tick);
    };
    raf = window.requestAnimationFrame(tick);
    return () => {
      window.cancelAnimationFrame(raf);
      if (!pursuitBegunRef.current) {
        // This instance never opened a worker run — there is nothing to close.
        return;
      }
      pursuitBegunRef.current = false;
      if (calibrationCancelledRef.current) {
        // Cancel exits silently — no fit, no verify verdict, no write.
        runtime.pursuitAbort();
      } else if (!pursuitEndedRef.current) {
        // tick() already ended a finished run; ending again would double-fire
        // finishVerify and race commitPending.
        runtime.pursuitEnd();
      }
      setPursuitDwell(false);
      setPursuitPos(null);
      setPursuitNext(null);
      setPursuitProgress(0);
      pursuitPoseHoldRef.current = false;
      setPursuitPoseHold(false);
    };
  }, [pursuitActive, pursuitRun, calibrationTier]);

  // Display points, physical scale and viewing distance for angular scoring:
  // the tape distance when the run was given one, else the tracker's own.
  const protocolGeometry = useCallback((distances: number[]): Geometry => {
    const current = configRef.current;
    const widthPt = current?.displayBounds?.width ?? window.innerWidth;
    const heightPt = current?.displayBounds?.height ?? window.innerHeight;
    const tapeCm = current?.viewingDistanceCm;
    return {
      widthPt,
      heightPt,
      mmPerPt: mmPerPoint(current?.webInference?.displaySizeInch ?? 13.3, widthPt, heightPt),
      distanceM: tapeCm && tapeCm > 0 ? tapeCm / 100 : median(distances) ?? 0.6
    };
  }, []);

  const appendHitTrials = useCallback(() => {
    if (!configRef.current?.hitTest && !accuracyCheckRef.current) {
      return;
    }
    const geometry = protocolGeometry(accuracyBucketsRef.current.flatMap((b) => b.distances));
    hitGeometryRef.current = geometry;
    accuracyPlanRef.current.push(...buildHitTrials(geometry).map((trial): AccuracyStep => ({ kind: "hit", trial })));
  }, [protocolGeometry]);

  // Accuracy test start: after calibration when both flags are set, otherwise
  // once tracking is live. The test measures whatever map is loaded.
  useEffect(() => {
    const runGrid = Boolean(config?.accuracyTest || accuracyCheck);
    const runHit = Boolean(config?.hitTest || accuracyCheck);
    if (!config || !(runGrid || runHit) || accuracyStartedRef.current) {
      return;
    }
    if ((config.calibrate || autoCalibrate || (accuracyCheck && !accuracyMeasureOnly)) && !calibrationDone) {
      return;
    }
    if (!gazePresence.live || calibrationCountdown !== null || pursuitActive) {
      return;
    }
    accuracyStartedRef.current = true;
    accuracyIndexRef.current = 0;
    accuracyBucketsRef.current = [];
    hitGeometryRef.current = null;
    // Hit trials are sized from the grid's measured distance, so they're
    // appended when the grid finishes (or right away for --hit-test alone).
    accuracyPlanRef.current = runGrid ? shuffled(ACCURACY_GRID).map((target): AccuracyStep => ({ kind: "grid", target })) : [];
    if (!runGrid) {
      appendHitTrials();
    }
    // The test owns the screen — a first-run card still up must not linger
    // over the modal (same teardown the calibration paths do).
    onboardingRef.current = false;
    setOnboarding(false);
    setAccuracyIndex(0);
    showStatus("accuracy test — stare at each dot", "info");
  }, [config, autoCalibrate, accuracyCheck, accuracyMeasureOnly, calibrationDone, gazePresence.live, calibrationCountdown, pursuitActive, showStatus, appendHitTrials]);

  const finalizeAccuracyTest = useCallback(() => {
    const measureOnly = accuracyMeasureOnlyRef.current;
    accuracyCheckRef.current = false;
    accuracyMeasureOnlyRef.current = false;
    setAccuracyCheck(false);
    setAccuracyMeasureOnly(false);
    const buckets = accuracyBucketsRef.current;
    const display = configRef.current?.displayBounds;
    const geometry = hitGeometryRef.current ?? protocolGeometry(buckets.flatMap((b) => b.distances));
    const hitTrials = accuracyPlanRef.current.flatMap((step) => (step.kind === "hit" ? [step.trial] : []));
    const summarize = (values: number[]) => {
      const sorted = values.slice().sort((a, b) => a - b);
      return sorted.length
        ? {
            samples: sorted.length,
            median: percentile(sorted, 0.5),
            p90: percentile(sorted, 0.9),
            p95: percentile(sorted, 0.95),
            max: sorted[sorted.length - 1]
          }
        : { samples: 0, median: null, p90: null, p95: null, max: null };
    };
    const allErrors = buckets.flatMap((b) => b.errors);
    const allInference = buckets.flatMap((b) => b.inference);
    const allIntervals = buckets.flatMap((b) => b.intervals);
    const regions: Record<string, ReturnType<typeof summarize>> = {};
    for (const region of ["center", "edge", "corner"] as const) {
      regions[region] = summarize(buckets.filter((b) => regionOfTarget(b.target) === region).flatMap((b) => b.errors));
    }
    const report = {
      kind: "accuracy-test",
      protocol: "jara27-gaze-v1",
      created_at: new Date().toISOString(),
      display: display ? { width: display.width, height: display.height } : null,
      runtime: configRef.current?.runtime,
      detector: configRef.current?.webInference?.detector,
      geometry: {
        mm_per_pt: geometry.mmPerPt,
        display_size_inch: configRef.current?.webInference?.displaySizeInch,
        distance_m: geometry.distanceM,
        distance_source: configRef.current?.viewingDistanceCm ? "tape" : "tracker",
        tracker_distance_median_m: median(buckets.flatMap((b) => b.distances))
      },
      measure_only: measureOnly,
      // Measure-only scores the live map, so an earlier calibration's run
      // and verdict don't describe it; the learning state does.
      calibration_run: measureOnly ? null : calibrationRunRef.current,
      calibration_verdict: measureOnly ? null : lastVerdictRef.current,
      learning: learningRef.current,
      held_out: buckets.length
        ? heldOutReport(
            buckets.map((b) => ({ target: b.target, samplesPt: b.points })),
            geometry
          )
        : null,
      hit_test: hitTrials.length ? hitRateReport(hitTrials) : null,
      error_px: {
        overall: summarize(allErrors),
        regions,
        per_point: buckets.map((b) => ({ target: b.target, ...summarize(b.errors) }))
      },
      perf: {
        inference_ms: summarize(allInference),
        frame_interval_ms: summarize(allIntervals)
      }
    };
    console.info("Accuracy report", JSON.stringify(report));
    void window.gazeBridge
      .writeReport("accuracy_report.json", report)
      .then((result) => {
        showStatus(result.ok ? `accuracy test saved: ${result.path}` : `accuracy report failed: ${result.error}`, result.ok ? "info" : "warning");
      })
      .catch((error) => {
        // An invoke rejection would otherwise be an unhandled promise —
        // surface it through the same status line the save answer uses.
        console.error("Accuracy report write failed", error);
        showStatus("accuracy report failed to write", "warning");
      });
  }, [showStatus, protocolGeometry]);

  useEffect(() => {
    finalizeAccuracyTestRef.current = finalizeAccuracyTest;
  }, [finalizeAccuracyTest]);

  // Grid steps: a settle window, then raw per-frame collection. Hit steps:
  // the gaze handler scores each frame and advances early on a hit; this
  // timer only closes a miss at the 2 s limit.
  useEffect(() => {
    if (accuracyIndex === null) {
      return;
    }
    const step = accuracyPlanRef.current[accuracyIndex];
    if (step === undefined) {
      return;
    }
    const advance = () => {
      accuracyCollectRef.current = null;
      const isLastGrid = step.kind === "grid" && accuracyPlanRef.current[accuracyIndex + 1] === undefined;
      if (isLastGrid) {
        appendHitTrials();
      }
      if (accuracyIndex + 1 < accuracyPlanRef.current.length) {
        setAccuracyIndex(accuracyIndex + 1);
      } else {
        setAccuracyIndex(null);
        finalizeAccuracyTest();
      }
    };
    if (step.kind === "hit") {
      hitStateRef.current = { onset: Date.now(), insideSince: null };
      const timer = window.setTimeout(() => {
        if (step.trial.hit === null) {
          step.trial.hit = false;
          advance();
        }
      }, HIT_TIMEOUT_MS + 50);
      return () => {
        window.clearTimeout(timer);
        hitStateRef.current = null;
      };
    }
    const bucket: AccuracyBucket = {
      target: step.target,
      collectFrom: Date.now() + ACCURACY_SETTLE_MS,
      errors: [],
      points: [],
      distances: [],
      inference: [],
      intervals: []
    };
    accuracyCollectRef.current = bucket;
    accuracyBucketsRef.current.push(bucket);
    const timer = window.setTimeout(advance, ACCURACY_DWELL_MS);
    return () => {
      window.clearTimeout(timer);
      accuracyCollectRef.current = null;
    };
  }, [accuracyIndex, finalizeAccuracyTest, appendHitTrials]);

  // Gaze staleness is driven by the single watchdog armed per frame in the
  // message handler — this just returns it on unmount.
  useEffect(() => () => window.clearTimeout(gazeStaleTimerRef.current), []);

  // Same expiry for the preview strip: when frames stop (camera stall, worker
  // restart) the last frame must not linger as a frozen image.
  useEffect(() => {
    if (!preview) {
      return;
    }
    const sample = preview;
    return schedulePreviewExpiry(sample.receivedAt, () => {
      setPreview((current) => (current === sample ? null : current));
    });
  }, [preview]);

  // The 60fps dot loop runs only while a live unpaused stream has motion to
  // animate — a hidden (stale/absent) or paused-ghost dot is static, seeded
  // by the render-time transform below. Re-arms on the next live frame.
  useEffect(() => {
    if (paused || !gazePresence.live) {
      gazeDotRef.current?.classList.remove("fast");
      return;
    }
    let raf = 0;
    let last = performance.now();
    const tick = (now: number) => {
      raf = requestAnimationFrame(tick);
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      const el = gazeDotRef.current;
      const target = gazeTargetRef.current;
      if (!el || (!target && !pausedRef.current)) {
        gazeDisplayRef.current = null;
        return;
      }
      let pos = gazeDisplayRef.current;
      if (!pos) {
        if (!target) {
          return;
        }
        pos = [target[0], target[1]];
        gazeDisplayRef.current = pos;
      } else if (!pausedRef.current && target) {
        // Paused = static ghost: no prediction, no motion — just the frame.
        // sinceUpdate is sample age on the wall clock (captured_at_ms) — it
        // includes pipeline latency, so the lead compensates transport too.
        const sinceUpdate = Math.max(0, (Date.now() - gazeTargetAtRef.current) / 1000);
        const motion = advanceDotSpring(pos, gazeSpringVelRef.current, leadTarget(target, gazeVelRef.current, sinceUpdate), dt, [window.innerWidth, window.innerHeight]);
        pos = motion.pos;
        gazeDisplayRef.current = motion.pos;
        gazeSpringVelRef.current = motion.vel;
      }
      el.style.transform = `translate(${pos[0] * window.innerWidth}px, ${pos[1] * window.innerHeight}px) scale(calc(var(--dot-scale, 1) * var(--dot-fast, 1)))`;
      const speed = pausedRef.current ? 0 : Math.hypot(gazeVelRef.current[0], gazeVelRef.current[1]);
      el.classList.toggle("fast", speed > 1.5);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      // A stopped loop can't untoggle the class — never let "fast" freeze on.
      gazeDotRef.current?.classList.remove("fast");
    };
  }, [paused, gazePresence.live]);

  // Discrete presences, not a confidence dial: gone / ghosted while blinking
  // or head-turned / held / tracking — and a frozen ghost while paused.
  // Computed at render (not memoized) so a click-effect remount seeds the
  // freshest ref-held position, same freshness the per-frame state gave it.
  const dotStyle = (() => {
    const pos = gazeDisplayRef.current ?? gazeTargetRef.current;
    const style: { opacity: number; transform?: string } = (() => {
      if (paused) {
        return { opacity: pos ? 0.2 : 0 };
      }
      if (!gazePresence.live) {
        return { opacity: 0 };
      }
      if (gazePresence.ghost) {
        return { opacity: 0.18 };
      }
      if (gazePresence.held) {
        return { opacity: 0.4 };
      }
      return { opacity: 1 };
    })();
    // The click-effect key remounts the dot; seed the last smoothed position
    // so the fresh element never paints a frame at translate(0,0) before the
    // rAF loop writes its transform.
    if (pos) {
      style.transform = `translate(${pos[0] * window.innerWidth}px, ${pos[1] * window.innerHeight}px) scale(calc(var(--dot-scale, 1) * var(--dot-fast, 1)))`;
    }
    return style;
  })();

  useEffect(() => {
    if (!clickEffect) {
      return;
    }
    const timeout = window.setTimeout(() => {
      setClickEffect((current) => (current?.id === clickEffect.id ? null : current));
    }, clickEffect.effect === "double" ? 1240 : 840);
    return () => window.clearTimeout(timeout);
  }, [clickEffect]);

  const calibrationActive = calibrationCountdown !== null || pursuitActive;
  const accuracyStep = accuracyIndex !== null ? accuracyPlanRef.current[accuracyIndex] : undefined;
  const accuracyStepTotal =
    (config?.accuracyTest || accuracyCheck ? ACCURACY_GRID.length : 0) + (config?.hitTest || accuracyCheck ? HIT_STEPS : 0);
  const modalActive = calibrationActive || accuracyIndex !== null;
  const markerShown = markerVisible || calibrationCountdown !== null || Boolean(config?.showCameraMarker);

  // Mirrored for the stable message handlers, which read modal state between
  // renders without re-subscribing.
  useEffect(() => {
    calibrationActiveRef.current = calibrationActive;
    accuracyIndexRef.current = accuracyIndex;
    onboardingRef.current = onboarding;
    markerShownRef.current = markerShown;
  }, [calibrationActive, accuracyIndex, onboarding, markerShown]);

  // Modal phases take over the screen — switch off click-through so their
  // exit button receives clicks, and give Escape the same way out. The
  // first-run card is interactive too, so it joins this gate.
  useEffect(() => {
    window.gazeBridge.setModalInteractive(modalActive || onboarding);
    return () => {
      // Unmounting mid-modal must not leave the window click-blocking.
      window.gazeBridge.setModalInteractive(false);
    };
  }, [modalActive, onboarding]);

  const cancelCalibration = useCallback(() => {
    // Latch read by the pursuit cleanup (→ silent abort) and the rejected_fit
    // handler (→ no re-open) so a cancel really cancels.
    calibrationCancelledRef.current = true;
    rejectedFitRetriesRef.current = 0;
    // A wait queued on the runtime starting (or a retry's queued copy) must
    // not leak into whatever the user does next.
    pursuitAwaitingRuntimeRef.current = false;
    pursuitRetryNoticeRef.current = null;
    // Latch stays SET (not cleared): the start-effect guard is `!started`, so
    // clearing it would auto-restart a cancelled test on the next gaze frame.
    accuracyStartedRef.current = true;
    accuracyBucketsRef.current = [];
    accuracyCollectRef.current = null;
    accuracyPlanRef.current = [];
    hitStateRef.current = null;
    accuracyCheckRef.current = false;
    setAccuracyCheck(false);
    accuracyMeasureOnlyRef.current = false;
    setAccuracyMeasureOnly(false);
    lastVerdictRef.current = null;
    // Escaping a first-enable auto run is a "not now" that sticks.
    if (autoCalibrateRef.current) {
      dismissOnboarding();
    }
    setCalibrationCountdown(null);
    setPursuitActive(false);
    setPursuitPhase("capture");
    setPursuitPos(null);
    setPursuitNext(null);
    setPursuitDwell(false);
    setPursuitProgress(0);
    setCalibrationNotice(null);
    setDriftNotice(null);
    setCalibrationDone(true);
    setAccuracyIndex(null);
    // A manual exit counts as "not now" — hold off drift-triggered recalibration
    // for the full cooldown instead of reopening the modal seconds later.
    lastDriftTriggerRef.current = Date.now();
    statusHoldUntilRef.current = 0;
    setStatus("tracking");
    setStatusLevel("info");
  }, [dismissOnboarding]);

  useEffect(() => {
    if (!calibrationActive && accuracyIndex === null && !onboarding) {
      return;
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      if (calibrationActive || accuracyIndex !== null) {
        cancelCalibration();
      } else {
        // The first-run card is a modal too — Escape answers "not now".
        dismissOnboarding();
        flashHint("Say “recalibrate” any time to calibrate");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [calibrationActive, accuracyIndex, onboarding, cancelCalibration, dismissOnboarding, flashHint]);
  const inferenceTimeText = (diagnostics.inference_time ?? config?.enableInferenceTime) ? formatInferenceTime(gazeDiag?.inference_ms) : null;

  // Latest-closure region collector: the interval/resize effect below is
  // stable ([]-deps) and always calls the newest closure — otherwise every
  // ~15Hz gaze frame would tear down and rebuild the timer and listener.
  const collectRegionsRef = useRef<() => void>(() => {});
  useEffect(() => {
    collectRegionsRef.current = () => {
      const regions: OverlayRegion[] = [];
      const addElement = (element: HTMLElement | null, padding: number) => {
        if (!element) {
          return;
        }
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) {
          return;
        }
        regions.push({
          x: rect.left - padding,
          y: rect.top - padding,
          width: rect.width + padding * 2,
          height: rect.height + padding * 2
        });
      };
      // A faded marker must not keep its click-hole — skip it entirely.
      if (markerShownRef.current) {
        addElement(cameraMarkerRef.current, 18);
      }
      // Modal phases own the whole screen (scrim) — declare it so
      // shape-overlay mode on win/linux renders the dark field too.
      if (modalActive || onboarding) {
        regions.push({ x: 0, y: 0, width: window.innerWidth, height: window.innerHeight });
      }
      const gazeSample = gazeRef.current;
      if (!modalActive && gazeSample && Date.now() - gazeSample.receivedAt <= GAZE_STALE_MS) {
        addElement(gazeDotRef.current, 56);
      }
      addElement(calibrationCountdownRef.current, 32);
      addElement(calibrationTargetRef.current, 18);
      addElement(calibrationNoticeRef.current, 18);
      addElement(driftNoticeRef.current, 18);
      addElement(accuracyProgressRef.current, 12);
      addElement(inferenceTimeRef.current, 18);
      addElement(previewRef.current, 24);
      if (!modalActive) {
        addElement(statusRef.current, 18);
      }
      window.gazeBridge.setOverlayRegions(regions);
    };
  });

  useEffect(() => {
    const collect = () => collectRegionsRef.current();
    collect();
    const intervalId = window.setInterval(collect, 250);
    window.addEventListener("resize", collect);
    return () => {
      window.clearInterval(intervalId);
      window.removeEventListener("resize", collect);
    };
  }, []);

  return (
    <main className="overlay">
      {(modalActive || onboarding) && <div className="calibration-scrim" />}
      {onboarding && (
        <div className="onboarding-card" role="dialog" aria-label="Calibrate eye tracking">
          <div className="onboarding-title">Tune the tracker to your eyes</div>
          <p>Follow the dot for about 20 seconds — it only needs to happen once.</p>
          <div className="onboarding-actions">
            <button
              type="button"
              className="primary"
              onClick={() => {
                dismissOnboarding();
                beginCalibration("standard");
              }}
            >
              Calibrate
            </button>
            <button
              type="button"
              onClick={() => {
                dismissOnboarding();
                flashHint("Say “recalibrate” any time to calibrate");
              }}
            >
              Not now
            </button>
          </div>
        </div>
      )}
      {calibratedFlash && (
        <div className="calibrated-card" role="status">
          <span className="calibrated-check">✓</span>
          Calibrated
        </div>
      )}
      {modalActive && (
        <div className="calibration-progress">
          <i
            style={{
              transform: `scaleX(${pursuitActive ? pursuitProgress : accuracyIndex !== null ? (accuracyIndex + 1) / accuracyStepTotal : 0})`
            }}
          />
        </div>
      )}
      {modalActive && (
        <button
          type="button"
          className="calibration-exit"
          aria-label={accuracyIndex !== null ? "Exit accuracy test" : "Exit calibration"}
          onClick={cancelCalibration}
        >
          ×
        </button>
      )}
      {/* Modal phases keep only the scrim, exit button, progress rail, target,
          countdown and notices — everything else would occlude targets. The
          camera marker is the exception: it stays up through the countdown so
          the user knows where to face before the pursuit starts. */}
      {(!modalActive || calibrationCountdown !== null) && (
        <div
          ref={cameraMarkerRef}
          className={`camera-marker${markerShown ? "" : " faded"}`}
          aria-label="camera position marker"
          style={{
            transform: `translate(${(config?.cameraScreenX ?? 0.5) * window.innerWidth}px, ${(config?.cameraScreenY ?? 0) * window.innerHeight}px)`
          }}
        >
          <div className="camera-arrow-shape" />
          <div className="camera-label">Camera position</div>
        </div>
      )}
      {!modalActive && dotVisible && (
        <div
          key={clickEffect?.id ?? 0}
          ref={gazeDotRef}
          className={`gaze-dot${clickEffect ? ` ${clickEffect.effect}-click-effect` : ""}${gazePresence.dwell && !paused ? " dwell" : ""}`}
          style={dotStyle}
        >
          {clickEffect && <span className="gaze-click-label">{clickEffect.effect === "double" ? "Double" : "Single"}</span>}
        </div>
      )}
      {calibrationCountdown !== null && (
        <div ref={calibrationCountdownRef} className="calibration-countdown">
          <span key={calibrationCountdown}>{calibrationCountdown}</span>
        </div>
      )}
      {pursuitNext && (
        <div
          className="pursuit-ghost"
          style={{
            transform: `translate(${pursuitNext[0] * window.innerWidth}px, ${pursuitNext[1] * window.innerHeight}px)`
          }}
        />
      )}
      {pursuitPos && (
        <div
          ref={calibrationTargetRef}
          className={`pursuit-target${pursuitDwell ? " dwell" : ""}${pursuitPhase === "verify" ? " verify" : ""}`}
          style={{
            transform: `translate(${pursuitPos[0] * window.innerWidth}px, ${pursuitPos[1] * window.innerHeight}px)`
          }}
        >
          <div className="pursuit-ring" />
          <div className="pursuit-dot" />
        </div>
      )}
      {accuracyIndex !== null && accuracyStep?.kind === "grid" && (
        <>
          <div
            ref={calibrationTargetRef}
            className="calibration-target accuracy"
            style={{
              transform: `translate(${accuracyStep.target[0] * window.innerWidth}px, ${accuracyStep.target[1] * window.innerHeight}px)`
            }}
          >
            <div />
          </div>
          <div ref={accuracyProgressRef} className="accuracy-progress">
            Look at each dot · {accuracyIndex + 1}/{accuracyStepTotal}
          </div>
        </>
      )}
      {accuracyIndex !== null && accuracyStep?.kind === "hit" && (
        <>
          <div
            ref={calibrationTargetRef}
            className="hit-target"
            style={{
              width: `${accuracyStep.trial.radiusPt * 2}px`,
              height: `${accuracyStep.trial.radiusPt * 2}px`,
              transform: `translate(${accuracyStep.trial.target[0] * window.innerWidth - accuracyStep.trial.radiusPt}px, ${
                accuracyStep.trial.target[1] * window.innerHeight - accuracyStep.trial.radiusPt
              }px)`
            }}
          />
          <div ref={accuracyProgressRef} className="accuracy-progress">
            Look inside each circle · {accuracyIndex + 1}/{accuracyStepTotal}
          </div>
        </>
      )}
      {/* Not gated on calibrationActive: save_failed/reject-limit notices are
          set after the modal closes and must still be visible. */}
      {calibrationNotice && (
        <div ref={calibrationNoticeRef} className="calibration-notice">{calibrationNotice}</div>
      )}
      {/* Pose hold: sampling (not the dot) is paused while the head reads
          tilted — a quiet top pill, not a warning. The modal scrim already
          owns the whole-screen overlay region, so no click-hole to declare. */}
      {pursuitActive && pursuitPoseHold && (
        <div className="pose-hint">hold your head still — keep following the dot</div>
      )}
      {!modalActive && driftNotice && (
        <div ref={driftNoticeRef} className="drift-notice">{driftNotice}</div>
      )}
      {inferenceTimeText && !modalActive && (
        <div ref={inferenceTimeRef} className="inference-time">
          {inferenceTimeText}
        </div>
      )}
      {preview && !modalActive && diagnostics.preview !== false && (
        <aside ref={previewRef} className="preview">
          <img src={preview.image} alt="camera detection preview" />
          <div className={preview.head_detected && preview.eye_count >= 2 ? "ok" : "warn"}>
            Head {preview.head_detected ? "OK" : "NO"} / Eyes {preview.eye_count}
          </div>
        </aside>
      )}
      {!modalActive && (diagnostics.status ?? Boolean(config?.debug)) && (
        <section ref={statusRef} className={`status ${statusLevel}`}>
          <div>{status}</div>
          {gazeDiag && (
            <div>
              d {gazeDiag.distance_m.toFixed(2)}m{gazeDiag.distance_source ? ` (${gazeDiag.distance_source})` : ""}
              {gazeDiag.yaw_deg !== undefined && gazeDiag.pitch_deg !== undefined
                ? ` / yaw ${gazeDiag.yaw_deg.toFixed(1)} / pitch ${gazeDiag.pitch_deg.toFixed(1)}`
                : " / head pose n/a"}
            </div>
          )}
          {gazeDiag?.blink && <div>Eyes closed</div>}
          {gazeDiag?.head_turned && <div>Head turned</div>}
          {gazeDiag?.head_face_width_ratio && (
            <div>
              Head/Face {gazeDiag.head_face_width_ratio.toFixed(3)}x
            </div>
          )}
          {gazeDiag?.eye_position_weight_y !== undefined && (
            <div>
              Eye pos weight x {gazeDiag.eye_position_weight_x?.toFixed(2)} / y {gazeDiag.eye_position_weight_y.toFixed(2)}
            </div>
          )}
          {gazeDiag?.gaze_projection_mode && <div>Projection {gazeDiag.gaze_projection_mode}</div>}
          {formatMs(gazeDiag?.inference_ms) && (
            <div>
              Infer {formatMs(gazeDiag?.inference_ms)} / det {formatMs(gazeDiag?.detect_inference_ms) ?? "-"} / gaze{" "}
              {formatMs(gazeDiag?.gaze_inference_ms) ?? "-"}
            </div>
          )}
          {modelRuntime.detector && (
            <div>
              Detector {modelRuntime.detector.runtime} / {modelRuntime.detector.accelerator}
            </div>
          )}
          {modelRuntime.gaze && (
            <div>
              Gaze {modelRuntime.gaze.runtime} / {modelRuntime.gaze.accelerator}
            </div>
          )}
          {config && (
            <div>
              display {config.displayIndex + 1}/{config.displayCount}
            </div>
          )}
        </section>
      )}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
