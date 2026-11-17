export const GAZE_STALE_MS = 1500;
export const PREVIEW_STALE_MS = 2000;

// Render-side motion constants. The spring is critically damped — it settles
// fast without overshoot, so a retargeting frame can't kick the dot past
// where the eye landed. Feed-forward lead is capped at ~2 frames: pursuit
// keeps pace, saccades (which arrive snapped, never predicted) can't coast.
export const DOT_EXTRAPOLATE_MAX_SEC = 0.033;
export const DOT_SMOOTH_TIME_SEC = 0.1;
export const DOT_DEADBAND_PX = 1.5;
// A retarget this large is a saccade — snap, don't chase. ‖Δ‖ in normalized
// screen units (0.08 ≈ 150px on a 1920-wide display); the upstream gaze_state
// flag is preferred when present, this is the geometric fallback.
export const DOT_SNAP_JUMP_NORM = 0.08;

export interface DotMotion {
  pos: [number, number];
  vel: [number, number];
}

// True when the incoming sample is a jump the spring should snap to rather
// than chase — saccade-marked by the stream, or a jump beyond the norm floor.
export function isSaccadeJump(
  state: string | undefined,
  prev: [number, number] | null,
  next: [number, number]
): boolean {
  if (state === "saccade") {
    return true;
  }
  if (!prev) {
    return false;
  }
  return Math.hypot(next[0] - prev[0], next[1] - prev[1]) > DOT_SNAP_JUMP_NORM;
}

// Capped feed-forward: shift the chase target along the measured velocity by
// the sample's age (wall-clock captured_at → includes pipeline latency),
// clamped to ~2 frames so stale frames can't coast the dot into overshoot.
export function leadTarget(
  target: [number, number],
  vel: [number, number],
  sinceUpdateSec: number
): [number, number] {
  const lead = Math.min(Math.max(sinceUpdateSec, 0), DOT_EXTRAPOLATE_MAX_SEC);
  return [target[0] + vel[0] * lead, target[1] + vel[1] * lead];
}

// Critically damped spring step (SmoothDamp without a max-speed cap — the
// display velocity stays bounded by construction). Unlike the old exponential
// chase, acceleration is continuous: retargeting produces an ease, not a kick.
// Parks inside the deadband once the residual AND the drift are both quiet —
// gating position alone would freeze the dot mid-flight whenever the residual
// dipped below the deadband.
export function advanceDotSpring(
  pos: [number, number],
  vel: [number, number],
  target: [number, number],
  dtSec: number,
  viewPx: [number, number] = [1920, 1080]
): DotMotion {
  const dt = Math.min(Math.max(dtSec, 0), 0.05);
  if (dt === 0) {
    return { pos, vel };
  }
  const omega = 2 / DOT_SMOOTH_TIME_SEC;
  const x = omega * dt;
  const exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
  const dx = pos[0] - target[0];
  const dy = pos[1] - target[1];
  const tx = (vel[0] + omega * dx) * dt;
  const ty = (vel[1] + omega * dy) * dt;
  const nvx = (vel[0] - omega * tx) * exp;
  const nvy = (vel[1] - omega * ty) * exp;
  const npx = target[0] + (dx + tx) * exp;
  const npy = target[1] + (dy + ty) * exp;
  // Deadband the residual to the target (not the frame step) and require the
  // spring to be quiet — parking on residual alone would freeze mid-flight.
  const rxPx = (target[0] - pos[0]) * viewPx[0];
  const ryPx = (target[1] - pos[1]) * viewPx[1];
  const vPx = Math.hypot(vel[0] * viewPx[0], vel[1] * viewPx[1]);
  if (Math.hypot(rxPx, ryPx) < DOT_DEADBAND_PX && vPx < 2) {
    return { pos, vel: [0, 0] };
  }
  return { pos: [npx, npy], vel: [nvx, nvy] };
}

// save_failed comes from commitPending on the pursuit/verify path — the only
// calibration flow left. The old point-capture statuses (unstable, no_sample)
// were emitted by the removed capture() path and can no longer arrive.
export function shouldRetryCalibrationCapture(status: string): boolean {
  return status === "save_failed";
}

export function scheduleGazeExpiry(receivedAt: number, onExpired: () => void): () => void {
  const delay = Math.max(0, receivedAt + GAZE_STALE_MS - Date.now());
  const timeoutId = globalThis.setTimeout(onExpired, delay);
  return () => globalThis.clearTimeout(timeoutId);
}

export function schedulePreviewExpiry(receivedAt: number, onExpired: () => void): () => void {
  const delay = Math.max(0, receivedAt + PREVIEW_STALE_MS - Date.now());
  const timeoutId = globalThis.setTimeout(onExpired, delay);
  return () => globalThis.clearTimeout(timeoutId);
}

// Head-pose gate for pursuit calibration: a tilted head shifts the
// eye→screen mapping the fit can't see (the model has no pose input), so
// capture and verify hold their sample stream while |yaw| or |pitch| sits
// beyond this limit. 12° sits above ordinary seated drift (~5-8° of
// micro-motion while fixating) and well short of the gross rotations the
// stream's head_turned flag catches — tight enough to keep bent-pose frames
// out of the fit, loose enough that a relaxed user isn't nagged.
export const HEAD_TILT_LIMIT_DEG = 12;
// The pose must read level for this long before sampling resumes —
// hysteresis so one briefly-level frame mid-nod can't reopen the gate.
export const TILT_CLEAR_MS = 300;

// True when either pose angle exceeds the limit. Missing or non-finite
// angles never block: absent telemetry means we can't know the pose, not
// that it's bad — a frame without head pose must not stall calibration.
export function headTilted(yawDeg?: number, pitchDeg?: number, opts?: { thresholdDeg?: number }): boolean {
  const limit = opts?.thresholdDeg ?? HEAD_TILT_LIMIT_DEG;
  return (
    (yawDeg !== undefined && Number.isFinite(yawDeg) && Math.abs(yawDeg) > limit) ||
    (pitchDeg !== undefined && Number.isFinite(pitchDeg) && Math.abs(pitchDeg) > limit)
  );
}
