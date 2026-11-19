const maxMediaTimeRoundingUs = 100;

export class PresentedFrames {
  private callback?: number;
  private count = 0;
  private mediaUs = -1;
  private lastFrameUs = -1;
  private capturedMs = -Infinity;
  private available = false;
  private stopped = false;

  constructor(private video: HTMLVideoElement) {
    if (typeof video.requestVideoFrameCallback === "function" && typeof VideoFrame === "function") {
      this.callback = video.requestVideoFrameCallback(this.presented);
    }
  }

  private presented = (now: number, metadata: VideoFrameCallbackMetadata) => {
    if (this.stopped) return;
    this.available = false;
    const mediaUs = Math.round(metadata.mediaTime * 1e6);
    const sourceMs = metadata.captureTime;
    if (Number.isSafeInteger(metadata.presentedFrames) && metadata.presentedFrames > this.count &&
        Number.isSafeInteger(mediaUs) && mediaUs > this.mediaUs &&
        sourceMs !== undefined && Number.isFinite(sourceMs) && sourceMs >= 0 && sourceMs <= now && sourceMs > this.capturedMs) {
      this.count = metadata.presentedFrames;
      this.mediaUs = mediaUs;
      this.capturedMs = sourceMs;
      this.available = true;
    }
    this.callback = this.video.requestVideoFrameCallback(this.presented);
  };

  take(): { source: VideoFrame | HTMLVideoElement; capturedAtMs?: number; close?: () => void } {
    if (this.available) {
      this.available = false;
      try {
        const frame = new VideoFrame(this.video);
        const matches = Number.isSafeInteger(frame.timestamp) && frame.timestamp > this.lastFrameUs &&
          Math.abs(frame.timestamp - this.mediaUs) <= maxMediaTimeRoundingUs;
        if (matches) this.lastFrameUs = frame.timestamp;
        return {
          source: frame,
          capturedAtMs: matches ? performance.timeOrigin + this.capturedMs : undefined,
          close: () => frame.close()
        };
      } catch {
        return { source: this.video };
      }
    }
    return { source: this.video };
  }

  stop() {
    this.stopped = true;
    this.available = false;
    if (this.callback !== undefined) this.video.cancelVideoFrameCallback(this.callback);
  }
}
