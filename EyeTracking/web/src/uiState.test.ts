import { afterEach, describe, expect, it, vi } from "vitest";
import { scheduleGazeExpiry, shouldRetryCalibrationCapture } from "./uiState";

afterEach(() => {
  vi.useRealTimers();
});

describe("calibration UI state", () => {
  it("retries the current capture when saving the calibration fails", () => {
    expect(shouldRetryCalibrationCapture("save_failed")).toBe(true);
    expect(shouldRetryCalibrationCapture("saved")).toBe(false);
  });
});

describe("gaze UI state", () => {
  it("expires a gaze sample after tracking stops", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-21T00:00:00.000Z"));
    const onExpired = vi.fn();

    const cancel = scheduleGazeExpiry(Date.now(), onExpired);
    vi.advanceTimersByTime(1499);
    expect(onExpired).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(onExpired).toHaveBeenCalledOnce();
    cancel();
  });
});
