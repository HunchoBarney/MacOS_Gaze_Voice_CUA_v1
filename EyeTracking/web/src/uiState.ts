export const GAZE_STALE_MS = 1500;

export function shouldRetryCalibrationCapture(status: string): boolean {
  return status === "unstable" || status === "no_sample" || status === "save_failed";
}

export function scheduleGazeExpiry(receivedAt: number, onExpired: () => void): () => void {
  const delay = Math.max(0, receivedAt + GAZE_STALE_MS - Date.now());
  const timeoutId = globalThis.setTimeout(onExpired, delay);
  return () => globalThis.clearTimeout(timeoutId);
}
