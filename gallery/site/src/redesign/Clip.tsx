import { useEffect, useId, useRef, type CSSProperties, type ReactNode } from "react";
import { ChevronLeftIcon, ChevronRightIcon, PauseIcon, PlayIcon } from "../components/Icons";
import { Segmented } from "../components/Segmented";
import { asset } from "../data";
import type { Scheme } from "../types";
import { cycleSpeed, useClockState, type SyncClock } from "./clock";
import { setSpeed, SPEED_LABEL, useSpeed, type Resolved } from "./state";

const seconds = (value: number) => value.toFixed(2);

// One clip or still in a fixed-ratio frame. The frame takes its size from the manifest before
// anything loads, so nothing shifts when the poster or video arrives. Videos stay unloaded
// (preload none, no src) until they come within a screen of the viewport, and pause off screen.
export function ClipView({
  resolved,
  clock,
  label,
  scheme,
  ratio,
  priority = false,
  children,
}: {
  resolved: Resolved | undefined;
  clock: SyncClock;
  label: string;
  scheme: Scheme;
  ratio?: number;
  priority?: boolean;
  children?: ReactNode;
}) {
  const media = resolved?.media;
  const aspect = ratio ?? (media ? media.width / media.height : 16 / 10);
  return (
    <div className="rd-frame" data-scheme={scheme} style={{ aspectRatio: String(aspect) } as CSSProperties}>
      {!media && <span className="rd-frame-empty">No render for this state</span>}
      {media?.kind === "still" && <img src={asset(media.src)} alt={label} width={media.width} height={media.height} loading={priority ? "eager" : "lazy"} decoding="async" />}
      {media?.kind === "clip" && <LazyVideo key={media.src} src={media.src} poster={media.poster} duration={media.duration} fps={media.fps} clock={clock} label={label} />}
      {resolved && (resolved.rmMissing || resolved.schemeMissing) && (
        <span className="rd-frame-notes">
          {resolved.schemeMissing && <span className="rd-frame-note">No {scheme} render · showing {scheme === "dark" ? "light" : "dark"}</span>}
          {resolved.rmMissing && <span className="rd-frame-note">No Reduce Motion render</span>}
        </span>
      )}
      {children}
    </div>
  );
}

function LazyVideo({ src, poster, duration, fps, clock, label }: { src: string; poster?: string; duration?: number; fps?: number; clock: SyncClock; label: string }) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let handle: ReturnType<SyncClock["register"]> | undefined;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && !handle) {
          el.preload = "auto";
          el.src = asset(src);
          handle = clock.register(el, duration ?? 0, fps);
        }
        handle?.setVisible(entry.isIntersecting);
      },
      { rootMargin: "50% 25%" },
    );
    observer.observe(el);
    return () => {
      observer.disconnect();
      handle?.dispose();
      el.pause();
      el.removeAttribute("src");
      el.load();
    };
  }, [clock, src, duration, fps]);
  return (
    <video
      ref={ref}
      poster={poster ? asset(poster) : undefined}
      muted
      playsInline
      loop
      preload="none"
      disableRemotePlayback
      aria-label={label}
      onClick={() => clock.toggle()}
    />
  );
}

export function Transport({ clock, variant = "inline", children }: { clock: SyncClock; variant?: "inline" | "dock"; children?: ReactNode }) {
  const { playing, duration } = useClockState(clock);
  const speed = useSpeed();
  const id = useId();
  const range = useRef<HTMLInputElement>(null);
  const time = useRef<HTMLSpanElement>(null);
  const resume = useRef(false);

  useEffect(
    () =>
      clock.onFrame((t, d) => {
        if (range.current) {
          range.current.value = String(t);
          range.current.style.setProperty("--progress", String(d > 0 ? Math.min(1, t / d) : 0));
        }
        if (time.current) time.current.textContent = seconds(t);
      }),
    [clock],
  );

  return (
    <div className="rd-transport" data-variant={variant}>
      <button type="button" className="rd-tbutton rd-play" onClick={() => clock.toggle()} aria-label={playing ? "Pause" : "Play"} aria-keyshortcuts="Space">
        {playing ? <PauseIcon /> : <PlayIcon />}
      </button>
      <button type="button" className="rd-tbutton rd-step" onClick={() => clock.step(-1)} aria-label="Previous frame" title="Previous frame (,)">
        <ChevronLeftIcon />
      </button>
      <button type="button" className="rd-tbutton rd-step" onClick={() => clock.step(1)} aria-label="Next frame" title="Next frame (.)">
        <ChevronRightIcon />
      </button>
      <input
        ref={range}
        className="scrub rd-scrub"
        type="range"
        min={0}
        max={duration || 1}
        step={1 / clock.fps}
        defaultValue={0}
        aria-label="Scrub"
        onPointerDown={() => {
          resume.current = clock.playing;
          clock.pause();
        }}
        onInput={(event) => clock.seek(Number(event.currentTarget.value))}
        onPointerUp={() => {
          if (resume.current) clock.play();
          resume.current = false;
        }}
      />
      <span className="rd-time num" aria-hidden="true">
        <span ref={time}>0.00</span>
        <span className="rd-time-total"> / {seconds(duration)}</span>
      </span>
      <Segmented
        id={"speed" + id}
        className="rd-speed-seg"
        label="Playback speed"
        size="sm"
        value={speed}
        onChange={setSpeed}
        options={[
          { value: "1", label: "1×", title: "Normal speed" },
          { value: "0.5", label: "½×", title: "Half speed" },
          { value: "0.25", label: "¼×", title: "Quarter speed" },
        ]}
      />
      <button type="button" className="rd-tbutton rd-speed-cycle num" onClick={() => setSpeed(cycleSpeed(speed))} aria-label={"Playback speed " + SPEED_LABEL[speed] + ", change"}>
        {SPEED_LABEL[speed]}
      </button>
      {children}
    </div>
  );
}
