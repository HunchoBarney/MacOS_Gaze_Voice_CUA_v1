import { useEffect, useState, useSyncExternalStore } from "react";
import { setSpeed, useSpeed, type Speed } from "./state";

type Entry = { el: HTMLVideoElement; hint: number; visible: boolean; lastSeek: number };
type Snapshot = { playing: boolean; duration: number };

const DRIFT = 1 / 15;
const length = ({ el, hint }: Entry) => (Number.isFinite(el.duration) && el.duration > 0 ? el.duration : hint);
const SEEK_BACKOFF_MS = 400;

// One transport for every clip on screen. Time comes from the wall clock, not from any one video,
// so a clip that stalls or loads late is pulled back in line instead of holding the others.
// Each video loops on its own length; the timeline is as long as the longest clip.
export class SyncClock {
  private entries = new Set<Entry>();
  private t0 = 0;
  private wall0 = 0;
  private rate = 1;
  private raf = 0;
  private listeners = new Set<() => void>();
  private frames = new Set<(time: number, duration: number) => void>();
  private snapshot: Snapshot = { playing: false, duration: 0 };
  fps = 60;

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getSnapshot = () => this.snapshot;

  get playing() {
    return this.snapshot.playing;
  }

  duration() {
    let longest = 0;
    for (const entry of this.entries) longest = Math.max(longest, length(entry));
    return longest;
  }

  time() {
    const raw = this.snapshot.playing ? this.t0 + ((performance.now() - this.wall0) / 1000) * this.rate : this.t0;
    const duration = this.duration();
    return duration > 0 ? raw % duration : raw;
  }

  onFrame(listener: (time: number, duration: number) => void) {
    this.frames.add(listener);
    listener(this.time(), this.duration());
    return () => {
      this.frames.delete(listener);
    };
  }

  register(el: HTMLVideoElement, hint = 0, fps?: number) {
    const entry: Entry = { el, hint, visible: false, lastSeek: 0 };
    if (fps) this.fps = fps;
    this.entries.add(entry);
    const refresh = () => {
      this.sync(entry, this.time(), true);
      this.notifyFrame();
    };
    el.addEventListener("loadedmetadata", refresh);
    el.addEventListener("canplay", refresh);
    return {
      setVisible: (visible: boolean) => {
        entry.visible = visible;
        if (!visible && !el.paused) el.pause();
        if (visible) this.sync(entry, this.time(), true);
      },
      dispose: () => {
        el.removeEventListener("loadedmetadata", refresh);
        el.removeEventListener("canplay", refresh);
        this.entries.delete(entry);
        this.notifyFrame();
      },
    };
  }

  play() {
    if (this.snapshot.playing) return;
    this.wall0 = performance.now();
    this.set({ playing: true });
    this.syncAll(true);
    this.loop();
  }

  pause() {
    if (!this.snapshot.playing) return;
    this.t0 = this.time();
    this.set({ playing: false });
    cancelAnimationFrame(this.raf);
    this.syncAll(true);
    this.notifyFrame();
  }

  toggle() {
    if (this.snapshot.playing) this.pause();
    else this.play();
  }

  seek(time: number) {
    const duration = this.duration();
    this.t0 = duration > 0 ? ((time % duration) + duration) % duration : Math.max(0, time);
    this.wall0 = performance.now();
    this.syncAll(true);
    this.notifyFrame();
  }

  step(frames: number) {
    this.pause();
    this.seek((Math.round(this.time() * this.fps) + frames) / this.fps);
  }

  restart() {
    this.seek(0);
    this.play();
  }

  setRate(rate: number) {
    if (rate === this.rate) return;
    this.t0 = this.time();
    this.wall0 = performance.now();
    this.rate = rate;
    this.syncAll(false);
  }

  destroy() {
    this.pause();
  }

  private loop() {
    cancelAnimationFrame(this.raf);
    const tick = () => {
      if (!this.snapshot.playing) return;
      this.syncAll(false);
      this.notifyFrame();
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  private syncAll(force: boolean) {
    const time = this.time();
    for (const entry of this.entries) this.sync(entry, time, force);
  }

  private sync(entry: Entry, time: number, force: boolean) {
    const { el } = entry;
    const duration = length(entry);
    if (!entry.visible || el.readyState < 1 || duration <= 0) return;
    const target = time % duration;
    const gap = Math.abs(el.currentTime - target);
    const drift = Math.min(gap, duration - gap);
    if (el.playbackRate !== this.rate) el.playbackRate = this.rate;
    const now = performance.now();
    if (this.snapshot.playing) {
      const canSeek = force || (!el.seeking && now - entry.lastSeek > SEEK_BACKOFF_MS);
      if (drift > DRIFT && canSeek) {
        el.currentTime = target;
        entry.lastSeek = now;
      }
      if (el.paused) void el.play().catch(() => undefined);
    } else {
      if (!el.paused) el.pause();
      if (drift > 0.25 / this.fps) el.currentTime = target;
    }
  }

  private notifyFrame() {
    const time = this.time();
    const duration = this.duration();
    this.frames.forEach((listener) => listener(time, duration));
    if (Math.abs(duration - this.snapshot.duration) > 0.001) this.set({ duration });
  }

  private set(change: Partial<Snapshot>) {
    this.snapshot = { ...this.snapshot, ...change };
    this.listeners.forEach((listener) => listener());
  }
}

export function useClock({ autoplay }: { autoplay: boolean }) {
  const [clock] = useState(() => new SyncClock());
  const speed = useSpeed();
  useEffect(() => clock.setRate(Number(speed)), [clock, speed]);
  useEffect(() => {
    if (autoplay && !matchMedia("(prefers-reduced-motion: reduce)").matches) clock.play();
    return () => clock.destroy();
  }, [clock]); // eslint-disable-line react-hooks/exhaustive-deps
  return clock;
}

export function useClockState(clock: SyncClock) {
  return useSyncExternalStore(clock.subscribe, clock.getSnapshot);
}

export function cycleSpeed(speed: Speed): Speed {
  return speed === "1" ? "0.5" : speed === "0.5" ? "0.25" : "1";
}

export { setSpeed };
