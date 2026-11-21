// Point calibration, paced by the eyes instead of a clock. The target glides
// to each point, then parks until the tracker has captured enough frames
// there, so a slow tracker (10 fps on the owner's Mac, with stalls) can't run
// out of time and fail the fit, and a fast one doesn't make anyone wait. A
// point that collects nothing for maxParkMs is skipped rather than holding
// the run hostage. While the head pose blocks sampling the park clock stops.

export interface PointRunOptions {
  samplesPerPoint: number;
  glideMs: number;
  leadInMs: number;
  maxParkMs: number;
}

export interface PointRunFrame {
  // Target position in normalized screen space, or null once the run is done.
  pos: [number, number] | null;
  // True while parked: the only time frames are labelled with this point.
  parked: boolean;
  // How full the current point is, 0–1, for the ring around the target.
  pointProgress: number;
  // Whole-run progress, 0–1.
  progress: number;
  done: boolean;
}

export const CAPTURE_RUN: PointRunOptions = { samplesPerPoint: 6, glideMs: 450, leadInMs: 700, maxParkMs: 3500 };
export const VERIFY_RUN: PointRunOptions = { samplesPerPoint: 5, glideMs: 450, leadInMs: 300, maxParkMs: 3000 };

// Strong ease-out (cubic-bezier(0.23, 1, 0.32, 1) in the house curves):
// most of the travel happens early, so the eye lands with the target.
export function easeOutQuint(t: number): number {
  return 1 - Math.pow(1 - Math.min(1, Math.max(0, t)), 5);
}

export class PointRun {
  private index = 0;
  private phase: "lead" | "glide" | "park" = "lead";
  private phaseStart: number;
  private parkedMs = 0;
  private lastNow: number;
  private countAtPark = 0;

  constructor(
    readonly points: [number, number][],
    readonly options: PointRunOptions,
    now: number
  ) {
    this.phaseStart = now;
    this.lastNow = now;
  }

  // sampleCount is the tracker's running capture count for this run;
  // blocked pauses the park clock (head turned, eyes closed).
  step(now: number, sampleCount: number, blocked = false): PointRunFrame {
    const dt = Math.max(0, now - this.lastNow);
    this.lastNow = now;
    const total = this.points.length;
    if (this.index >= total) {
      return { pos: null, parked: false, pointProgress: 1, progress: 1, done: true };
    }
    const target = this.points[this.index];
    if (this.phase === "lead") {
      const parked = now - this.phaseStart >= this.options.leadInMs;
      if (parked) {
        this.park(now, sampleCount);
      }
      return { pos: target, parked, pointProgress: 0, progress: this.index / total, done: false };
    }
    if (this.phase === "glide") {
      const from = this.points[this.index - 1];
      const t = this.options.glideMs > 0 ? easeOutQuint((now - this.phaseStart) / this.options.glideMs) : 1;
      if (t >= 1) {
        this.park(now, sampleCount);
        return { pos: target, parked: true, pointProgress: 0, progress: this.index / total, done: false };
      }
      return {
        pos: [from[0] + (target[0] - from[0]) * t, from[1] + (target[1] - from[1]) * t],
        parked: false,
        pointProgress: 0,
        progress: this.index / total,
        done: false
      };
    }
    if (!blocked) {
      this.parkedMs += dt;
    }
    const pointProgress = Math.min(1, (sampleCount - this.countAtPark) / this.options.samplesPerPoint);
    if (pointProgress >= 1 || this.parkedMs >= this.options.maxParkMs) {
      this.index += 1;
      if (this.index >= total) {
        return { pos: null, parked: false, pointProgress: 1, progress: 1, done: true };
      }
      this.phase = "glide";
      this.phaseStart = now;
      return { pos: target, parked: false, pointProgress: 0, progress: this.index / total, done: false };
    }
    return { pos: target, parked: true, pointProgress, progress: (this.index + pointProgress) / total, done: false };
  }

  private park(now: number, sampleCount: number): void {
    this.phase = "park";
    this.phaseStart = now;
    this.parkedMs = 0;
    this.countAtPark = sampleCount;
  }
}
