import { afterEach, describe, expect, it, vi } from "vitest";
import { PresentedFrames } from "./presentedFrame";

afterEach(() => vi.unstubAllGlobals());

function camera() {
  let next: VideoFrameRequestCallback | undefined;
  let timestamp = 0;
  let closed = 0;
  const video = {
    requestVideoFrameCallback(fn: VideoFrameRequestCallback) { next = fn; return 1; },
    cancelVideoFrameCallback() { next = undefined; }
  } as unknown as HTMLVideoElement;
  vi.stubGlobal("VideoFrame", class {
    timestamp = timestamp;
    close() { closed++; }
  });
  const frames = new PresentedFrames(video);
  return {
    video, frames, setPixels(us: number) { timestamp = us; }, closed: () => closed,
    present(count: number, mediaUs: number, presentation: number, capture?: number) {
      next?.(10000, {
        presentedFrames: count, mediaTime: mediaUs / 1e6, presentationTime: presentation, captureTime: capture
      } as VideoFrameCallbackMetadata);
    }
  };
}

describe("camera frame provenance", () => {
  it("a frozen camera cannot become fresh from inference scheduler polls", () => {
    const cam = camera();
    expect(cam.frames.take().capturedAtMs).toBeUndefined();
    cam.setPixels(20037);
    cam.present(1, 20000, 102, 101);
    const first = cam.frames.take();
    expect(first.capturedAtMs).toBe(performance.timeOrigin + 101);
    expect(first.source).not.toBe(cam.video);
    first.close?.();
    expect(cam.closed()).toBe(1);
    for (let tick = 0; tick < 60; tick++) {
      expect(cam.frames.take()).toEqual({ source: cam.video });
    }
    cam.present(2, 20050, 103, 102);
    expect(cam.frames.take().capturedAtMs).toBeUndefined();
    cam.setPixels(40000);
    cam.present(3, 40000, 105, 104);
    expect(cam.frames.take().capturedAtMs).toBe(performance.timeOrigin + 104);
  });

  it("rejects mismatched pixels, regressing identity or source time, invalid clocks and stopped callbacks", () => {
    const cam = camera();
    cam.setPixels(31000);
    cam.present(4, 30000, 200, 200);
    expect(cam.frames.take().capturedAtMs).toBeUndefined();
    for (const [n, us, t] of [[3, 32000, 210], [5, 29000, 210], [5, 33000, 199], [6, 36000, NaN], [6, 36000, 10001]]) {
      cam.setPixels(us); cam.present(n, us, t, t);
      expect(cam.frames.take().capturedAtMs).toBeUndefined();
    }
    cam.setPixels(40000); cam.present(7, 40000, 220, 220);
    expect(cam.frames.take().capturedAtMs).toBe(performance.timeOrigin + 220);
    cam.frames.stop();
    cam.setPixels(50000); cam.present(8, 50000, 221, 221);
    expect(cam.frames.take()).toEqual({ source: cam.video });
  });

  it("recent presentation of buffered pixels never substitutes for unknown or old capture time", () => {
    const cam = camera();
    cam.setPixels(40000);
    cam.present(1, 40000, 9990);
    expect(cam.frames.take()).toEqual({ source: cam.video });
    cam.setPixels(80000);
    cam.present(2, 80000, 9995, 100);
    expect(cam.frames.take().capturedAtMs).toBe(performance.timeOrigin + 100);
  });

  it("keeps unproven video usable for display when browser provenance is unavailable", () => {
    const video = {} as HTMLVideoElement;
    const frames = new PresentedFrames(video);
    expect(frames.take()).toEqual({ source: video });
    frames.stop();
  });
});
