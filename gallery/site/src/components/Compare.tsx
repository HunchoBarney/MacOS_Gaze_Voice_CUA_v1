import { useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import type { Scheme } from "../types";
import { Img } from "./Img";
import { Segmented } from "./Segmented";
import { pictureWidth, type Picture } from "./Stage";

type Side = { picture: Picture; label: string; alt: string; superseded?: boolean };

export function Compare({ before, after, scheme, id }: { before: Side; after: Side; scheme: Scheme; id: string }) {
  const [mode, setMode] = useState<"swipe" | "side">("swipe");
  const box = useRef<HTMLDivElement>(null);
  const top = useRef<HTMLDivElement>(null);
  const handle = useRef<HTMLDivElement>(null);
  const position = useRef(50);

  function set(percent: number) {
    const value = Math.min(100, Math.max(0, percent));
    position.current = value;
    if (top.current) top.current.style.clipPath = "inset(0 0 0 " + value + "%)";
    if (handle.current) {
      handle.current.style.left = value + "%";
      handle.current.setAttribute("aria-valuenow", String(Math.round(value)));
    }
  }

  function fromPointer(event: PointerEvent) {
    const rect = box.current?.getBoundingClientRect();
    if (rect) set(((event.clientX - rect.left) / rect.width) * 100);
  }

  function onKey(event: KeyboardEvent) {
    const step = event.shiftKey ? 10 : 2;
    const next = { ArrowLeft: position.current - step, ArrowRight: position.current + step, Home: 0, End: 100 }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    set(next);
  }

  const width = Math.max(before.picture.width / before.picture.scale, after.picture.width / after.picture.scale);
  const height = Math.max(before.picture.height / before.picture.scale, after.picture.height / after.picture.scale);
  const frame = { width: width * 2, height: height * 2, scale: 2 };
  const afterName = after.superseded ? "Superseded proposal" : "Proposed";

  return (
    <div className="compare">
      <div className="compare-bar">
        <p className="compare-title">
          <span>{before.label}</span>
          <span className="compare-arrow" aria-hidden="true">→</span>
          <span>{after.label}</span>
        </p>
        <Segmented
          id={"compare-" + id}
          label="Compare layout"
          size="sm"
          value={mode}
          onChange={setMode}
          options={[
            { value: "swipe", label: "Swipe" },
            { value: "side", label: "Side by side" },
          ]}
        />
      </div>
      {mode === "swipe" ? (
        <div className="stage compare-stage" data-backdrop={after.picture.backdrop ?? "transparent"} data-scheme={scheme}>
          <div
            ref={box}
            className="compare-box"
            style={{ ...pictureWidth(frame, "fit"), aspectRatio: width + " / " + height }}
            onPointerDown={(event) => {
              if (event.button !== 0) return;
              event.currentTarget.setPointerCapture(event.pointerId);
              fromPointer(event);
            }}
            onPointerMove={(event) => {
              if (event.currentTarget.hasPointerCapture(event.pointerId)) fromPointer(event);
            }}
          >
            <Img src={before.picture.image} width={before.picture.width} height={before.picture.height} alt={before.alt} className="compare-img" />
            <div ref={top} className="compare-top" style={{ clipPath: "inset(0 0 0 50%)" }}>
              <Img src={after.picture.image} width={after.picture.width} height={after.picture.height} alt={after.alt} className="compare-img" />
            </div>
            <span className="compare-tag" data-side="before">Current</span>
            <span className="compare-tag" data-side="after">
              {afterName}
            </span>
            <div
              ref={handle}
              className="compare-handle"
              style={{ left: "50%" }}
              role="slider"
              tabIndex={0}
              aria-label={"Reveal " + afterName.toLowerCase()}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={50}
              onKeyDown={onKey}
            >
              <span className="compare-knob" aria-hidden="true" />
            </div>
          </div>
        </div>
      ) : (
        <div className="compare-side">
          {[before, after].map((side, index) => (
            <figure key={index} className="compare-col">
              <div className="stage" data-backdrop={side.picture.backdrop ?? "transparent"} data-scheme={scheme}>
                <div className="stage-inner">
                  <Img src={side.picture.image} width={side.picture.width} height={side.picture.height} alt={side.alt} style={pictureWidth(side.picture, "fit")} className="stage-img" />
                </div>
              </div>
              <figcaption>
                <span className="kind-tag" data-kind={index === 0 ? "current" : after.superseded ? "superseded" : "proposed"}>
                  {index === 0 ? "Current" : afterName}
                </span>{" "}
                {side.label}
              </figcaption>
            </figure>
          ))}
        </div>
      )}
    </div>
  );
}
