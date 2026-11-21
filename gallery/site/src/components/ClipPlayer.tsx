import { useEffect, useRef, useState } from "react";
import { asset } from "../data";
import type { Clip } from "../types";
import { LoopIcon, PauseIcon, PlayIcon } from "./Icons";
import { Segmented } from "./Segmented";

const seconds = (value: number) => value.toFixed(2);

export function ClipPlayer({ clip, id }: { clip: Clip; id: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const range = useRef<HTMLInputElement>(null);
  const time = useRef<HTMLSpanElement>(null);
  const [playing, setPlaying] = useState(false);
  const [loop, setLoop] = useState(true);
  const [rate, setRate] = useState<"1" | "0.5" | "0.25">("1");
  const [duration, setDuration] = useState(clip.durationMs / 1000);

  function sync() {
    const element = video.current;
    if (!element || !range.current || !time.current) return;
    range.current.value = String(element.currentTime);
    range.current.style.setProperty("--progress", String(Math.min(1, element.currentTime / duration)));
    time.current.textContent = seconds(element.currentTime);
  }

  useEffect(() => {
    if (!playing) return;
    let frame = requestAnimationFrame(function tick() {
      sync();
      frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, [playing, duration]);

  useEffect(() => {
    if (video.current) video.current.playbackRate = Number(rate);
  }, [rate]);

  function toggle() {
    const element = video.current;
    if (!element) return;
    if (element.paused) {
      if (element.ended || element.currentTime >= duration) element.currentTime = 0;
      void element.play();
    } else element.pause();
  }

  return (
    <figure className="clip">
      <div className="clip-frame" data-scheme={clip.scheme}>
        <video
          ref={video}
          src={asset(clip.video)}
          poster={asset(clip.poster)}
          width={clip.width}
          height={clip.height}
          style={{ width: "min(100%, " + clip.width + "px)" }}
          muted
          playsInline
          preload="metadata"
          loop={loop}
          onClick={toggle}
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
          onEnded={() => setPlaying(false)}
          onLoadedMetadata={(event) => {
            const d = event.currentTarget.duration;
            setDuration(Number.isFinite(d) && d > 0 ? d : clip.durationMs / 1000);
            event.currentTarget.playbackRate = Number(rate);
            sync();
          }}
          onSeeked={sync}
          aria-label={clip.caption ?? "Motion clip"}
        />
      </div>
      <div className="clip-controls">
        <button type="button" className="icon-button" onClick={toggle} aria-label={playing ? "Pause" : "Play"}>
          {playing ? <PauseIcon /> : <PlayIcon />}
        </button>
        <input
          ref={range}
          className="scrub"
          type="range"
          min={0}
          max={duration}
          step={1 / 60}
          defaultValue={0}
          aria-label="Scrub"
          onInput={(event) => {
            const element = video.current;
            if (!element) return;
            element.pause();
            element.currentTime = Number(event.currentTarget.value);
            sync();
          }}
        />
        <span className="clip-time num">
          <span ref={time}>0.00</span> / {seconds(duration)} s
        </span>
        <button type="button" className="icon-button" aria-pressed={loop} aria-label="Loop" title="Loop" onClick={() => setLoop(!loop)}>
          <LoopIcon />
        </button>
        <Segmented
          id={"rate-" + id}
          label="Playback speed"
          size="sm"
          value={rate}
          onChange={setRate}
          options={[
            { value: "1", label: "1×", title: "Normal speed" },
            { value: "0.5", label: "½×", title: "Half speed" },
            { value: "0.25", label: "¼×", title: "Quarter speed" },
          ]}
        />
      </div>
      {clip.caption && <figcaption className="clip-caption">{clip.caption}</figcaption>}
    </figure>
  );
}
