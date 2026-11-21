import { StrictMode, useEffect, useLayoutEffect, useRef, useState, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import "./base.css";
import { Desktop } from "./stage";
import { resetClock, scriptNow } from "./clock";
import type { Scenario } from "./script";
import { Island } from "./directions/Island";
import { EdgeLight } from "./directions/EdgeLight";
import { Constellation } from "./directions/Constellation";

export type DirectionProps = { scenario: Scenario };

const DIRECTIONS: { id: string; name: string; Component: ComponentType<DirectionProps> }[] = [
  { id: "A", name: "Island", Component: Island },
  { id: "B", name: "Edge light", Component: EdgeLight },
  { id: "C", name: "Constellation", Component: Constellation }
];

const params = new URLSearchParams(location.search);
const render = params.has("render");
const scenario: Scenario = params.get("scenario") === "fail" ? "fail" : "happy";
const requested = DIRECTIONS.findIndex((d) => d.id === params.get("dir") || String(DIRECTIONS.indexOf(d) + 1) === params.get("v"));

declare global {
  interface Window {
    __cal?: { now: () => number; mounted: boolean };
  }
}
window.__cal = { now: scriptNow, mounted: false };

function App() {
  const [current, setCurrent] = useState(requested >= 0 ? requested : 0);
  const [mount, setMount] = useState(0);
  const { Component } = DIRECTIONS[current];
  useEffect(() => {
    window.__cal!.mounted = true;
  }, []);
  const show = (i: number) => {
    resetClock();
    setCurrent(i);
    setMount((m) => m + 1);
    const url = new URL(location.href);
    url.searchParams.set("v", String(i + 1));
    url.searchParams.delete("dir");
    history.replaceState(null, "", url);
  };
  const replay = () => {
    resetClock();
    setMount((m) => m + 1);
  };
  return (
    <MotionConfig reducedMotion="user">
      <Desktop>
        <Component key={current + ":" + mount} scenario={scenario} />
      </Desktop>
      {!render && <Picker names={DIRECTIONS.map((d) => d.name)} current={current} onPick={show} onReplay={replay} />}
    </MotionConfig>
  );
}

// The prototype skill's picker (PICKER.md), as React: number keys and arrows
// switch, R replays; the variant swap itself is instant.
function Picker({ names, current, onPick, onReplay }: { names: string[]; current: number; onPick: (i: number) => void; onReplay: () => void }) {
  const nav = useRef<HTMLElement>(null);
  const highlight = useRef<HTMLSpanElement>(null);
  const items = useRef<(HTMLButtonElement | null)[]>([]);
  useLayoutEffect(() => {
    const el = items.current[current];
    if (!el || !highlight.current) return;
    highlight.current.style.width = el.offsetWidth + "px";
    highlight.current.style.transform = "translateX(" + el.offsetLeft + "px)";
  }, [current]);
  useEffect(() => {
    const id = requestAnimationFrame(() => requestAnimationFrame(() => nav.current?.setAttribute("data-ready", "")));
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const n = parseInt(e.key, 10);
      if (n >= 1 && n <= names.length) onPick(n - 1);
      else if (e.key === "ArrowRight") onPick((current + 1) % names.length);
      else if (e.key === "ArrowLeft") onPick((current - 1 + names.length) % names.length);
      else if (e.key === "r" || e.key === "R") onReplay();
    };
    addEventListener("keydown", onKey);
    return () => {
      cancelAnimationFrame(id);
      removeEventListener("keydown", onKey);
    };
  }, [current, names.length, onPick, onReplay]);
  return (
    <nav className="proto-picker" aria-label="Prototype variants" ref={nav}>
      <span className="proto-picker-highlight" aria-hidden="true" ref={highlight} />
      {names.map((name, i) => (
        <button
          key={name}
          ref={(el) => {
            items.current[i] = el;
          }}
          className="proto-picker-item"
          data-active={i === current ? "" : undefined}
          aria-current={i === current ? "true" : undefined}
          onClick={() => onPick(i)}
        >
          {name}
        </button>
      ))}
      <span className="proto-picker-divider" aria-hidden="true" />
      <button className="proto-picker-item proto-picker-replay" aria-label="Replay animation (R)" onClick={onReplay}>
        ↻
      </button>
    </nav>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
