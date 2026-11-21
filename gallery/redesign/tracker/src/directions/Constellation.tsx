import { useEffect } from "react";
import { AnimatePresence, animate, motion, useMotionValue, useReducedMotion, useTransform, type MotionValue } from "motion/react";
import { ThinkingOrb } from "thinking-orbs";
import { useScript } from "../clock";
import { POINTS, VERIFY, WEAK, T } from "../script";
import { usePursuit, type Pursuit } from "../pursuit";
import { StopControl, useDark, useViewport } from "../stage";
import type { DirectionProps } from "../main";
import "./constellation.css";

// C · Constellation. Spatial and playful: the whole job is on screen from the
// first frame as nine faint stars. Each one you look at lights and joins the
// constellation; a failure shows where on the screen it struggled.

const EASE = [0.23, 1, 0.32, 1] as const;
type S = ReturnType<typeof useScript>;

export function Constellation({ scenario }: DirectionProps) {
  const s = useScript(scenario);
  const reduce = !!useReducedMotion();
  const dark = useDark();
  const { w, h } = useViewport();
  const pursuit = usePursuit(s, [w / 2, 18.5], 0.42);
  const shown = s.phase !== "done";
  const folded = s.phase === "check" || s.phase === "success";
  const tracking = ["look", "ready", "capture", "verify", "check"].includes(s.phase);

  return (
    <div className="con" data-dark={dark || undefined}>
      <motion.div className="con-veil" initial={{ opacity: 0 }} animate={{ opacity: shown ? 1 : 0 }} transition={{ duration: shown ? 0.4 : 0.6, ease: "easeOut", delay: shown ? 0 : 0.25 }} />
      <motion.div
        className="con-sky"
        initial={false}
        animate={folded ? (reduce ? { opacity: 0 } : { opacity: 0, scale: 0.04 }) : { opacity: shown ? 1 : 0, scale: 1 }}
        transition={folded ? { duration: 0.5, ease: [0.55, 0, 1, 0.45] } : { type: "spring", visualDuration: 0.5, bounce: 0.15 }}
      >
        <Sky s={s} w={w} h={h} reduce={reduce} />
      </motion.div>
      <CameraGuide s={s} w={w} h={h} reduce={reduce} />
      <Marker s={s} pursuit={pursuit} />
      <Centre s={s} dark={dark} reduce={reduce} w={w} h={h} />
      <Words s={s} />
      <StopControl visible={tracking} material="auto" />
    </div>
  );
}

// The stars, the lines between them and the verify pass's test stars.
function Sky({ s, w, h, reduce }: { s: S; w: number; h: number; reduce: boolean }) {
  const lit = s.phase === "capture" ? s.k : ["verify", "check", "success", "failure"].includes(s.phase) ? 9 : 0;
  const px = (p: [number, number]) => [p[0] * w, p[1] * h] as const;
  const camera: [number, number] = [w / 2, 18.5];
  const lines: { from: readonly [number, number]; to: readonly [number, number]; weak: boolean }[] = [];
  if (["ready", "capture", "verify", "check", "success", "failure"].includes(s.phase) && s.attempt === 1) lines.push({ from: camera, to: px(POINTS[0]), weak: false });
  const drawn = s.phase === "capture" ? s.k : lit === 9 ? 8 : 0;
  for (let i = 1; i <= drawn; i += 1) lines.push({ from: px(POINTS[i - 1]), to: px(POINTS[i]), weak: s.phase === "failure" && WEAK.includes(i) });
  const quiet = s.phase === "verify" || s.phase === "check";
  return (
    <svg className="con-svg" width={w} height={h} aria-hidden="true">
      <motion.g initial={false} animate={{ opacity: quiet ? 0.3 : 1 }} transition={{ duration: 0.35 }}>
        {lines.map((l, i) => (
          <motion.line
            key={i}
            x1={l.from[0]}
            y1={l.from[1]}
            x2={l.to[0]}
            y2={l.to[1]}
            className="con-line"
            data-weak={l.weak || undefined}
            initial={reduce ? { opacity: 0 } : { pathLength: 0 }}
            animate={reduce ? { opacity: 1 } : { pathLength: 1 }}
            transition={reduce ? { duration: 0.25 } : { type: "spring", visualDuration: 0.42, bounce: 0 }}
          />
        ))}
      </motion.g>
      {POINTS.map((p, i) => {
        const [x, y] = px(p);
        const weak = s.phase === "failure" && WEAK.includes(i);
        const done = !weak && i < lit;
        const order = Math.hypot(p[0] - 0.5, (p[1] - 0.5) * 0.65);
        return (
          <g key={i} transform={"translate(" + x + " " + y + ")"}>
            <motion.circle
              r={14}
              className="con-halo"
              initial={false}
              animate={{ opacity: done ? 1 : 0, scale: done || reduce ? 1 : 0.4 }}
              transition={{ duration: 0.4, ease: EASE }}
            />
            <motion.circle
              className="con-star"
              data-weak={weak || undefined}
              initial={{ opacity: 0, r: 2 }}
              animate={{ opacity: weak ? 1 : done ? 1 : 0.42, r: weak ? 7 : done ? 4.5 : 3 }}
              transition={{ duration: 0.45, ease: EASE, delay: s.phase === "intro" ? 0.08 + order * 0.5 : 0 }}
            />
          </g>
        );
      })}
      {VERIFY.map((p, i) => {
        const [x, y] = px(p);
        const on = s.phase === "verify" && s.k >= i;
        return (
          <motion.circle key={"v" + i} cx={x} cy={y} r={5} className="con-test" initial={false} animate={{ opacity: s.phase === "verify" ? (on ? 1 : 0.35) : 0 }} transition={{ duration: 0.25, ease: "easeOut" }} />
        );
      })}
    </svg>
  );
}

// The camera cue: sparks climb from the middle of the screen to the notch and
// a reticle closes round the lens, then fills while you look at it.
function CameraGuide({ s, w, h, reduce }: { s: S; w: number; h: number; reduce: boolean }) {
  const on = s.phase === "look";
  const fill = useMotionValue(0);
  useEffect(() => {
    if (!on) return;
    fill.jump(0);
    const c = animate(fill, 1, { delay: 0.85, duration: (T.ready - T.look - 1000) / 1000, ease: "linear" });
    return () => c.stop();
  }, [on, s.attempt]);
  const sparks = [0.4, 0.31, 0.23, 0.16, 0.1];
  return (
    <AnimatePresence>
      {on && (
        <motion.div key={"guide" + s.attempt} className="con-guide" initial={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: 0.2 } }}>
          {!reduce &&
            sparks.map((y, i) => (
              <motion.span
                key={i}
                className="con-spark"
                style={{ left: w / 2, top: y * h }}
                initial={{ opacity: 0, scale: 0.6 }}
                animate={{ opacity: [0, 1, 0], scale: [0.6, 1, 0.8] }}
                transition={{ duration: 0.5, delay: 0.15 + i * (0.1 - i * 0.012), ease: "easeOut", times: [0, 0.35, 1] }}
              />
            ))}
          <motion.div
            className="con-reticle"
            style={{ left: w / 2, top: 18.5 }}
            initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 2.2, rotate: -45 }}
            animate={{ opacity: 1, scale: 1, rotate: 0 }}
            transition={reduce ? { duration: 0.3, delay: 0.3 } : { type: "spring", visualDuration: 0.5, bounce: 0.2, delay: 0.55 }}
          >
            <svg width="40" height="40" viewBox="0 0 40 40">
              <circle cx="20" cy="20" r="16" className="con-reticle-arcs" />
              <motion.circle cx="20" cy="20" r="16" className="con-reticle-fill" style={{ pathLength: fill }} />
            </svg>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

// The star you're looking at: a bright core with twelve ticks that light as
// the dwell runs. It glides along the line being drawn to the next star.
function Marker({ s, pursuit }: { s: S; pursuit: Pursuit }) {
  const visible = s.phase === "ready" || s.phase === "capture" || s.phase === "verify";
  return (
    <motion.div className="con-marker" style={{ x: pursuit.x, y: pursuit.y }} initial={false} animate={{ opacity: visible ? 1 : 0 }} transition={{ duration: 0.25, ease: "easeOut" }} aria-hidden="true">
      <span className="con-marker-glow" />
      <motion.div className="con-ticks" style={{ opacity: pursuit.ring }}>
        {Array.from({ length: 12 }, (_, i) => (
          <Tick key={i} i={i} p={pursuit.p} />
        ))}
      </motion.div>
      <span className="con-marker-core" />
    </motion.div>
  );
}

function Tick({ i, p }: { i: number; p: MotionValue<number> }) {
  const opacity = useTransform(p, [i / 12, (i + 1) / 12], [0.2, 1]);
  const a = (i / 12) * Math.PI * 2 - Math.PI / 2;
  return <motion.span className="con-tick" style={{ opacity, left: Math.cos(a) * 21, top: Math.sin(a) * 21 }} />;
}

// While it checks, the constellation folds into one orb; success is a check
// that flies up into the notch, where Jarvis lives.
function Centre({ s, dark, reduce, w, h }: { s: S; dark: boolean; reduce: boolean; w: number; h: number }) {
  return (
    <AnimatePresence>
      {s.phase === "check" && (
        <motion.div key="orb" className="con-centre" style={{ left: w / 2, top: h / 2 }} initial={{ opacity: 0, scale: reduce ? 1 : 0.8 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, transition: { duration: 0.2 } }} transition={{ duration: 0.35, ease: EASE, delay: 0.3 }}>
          <ThinkingOrb state="connecting" size={64} theme={dark ? "dark" : "light"} />
        </motion.div>
      )}
      {(s.phase === "success" || s.phase === "done") && (
        <motion.div
          key="check"
          className="con-centre"
          style={{ left: w / 2, top: h / 2 }}
          initial={{ opacity: 0, scale: reduce ? 1 : 0.85 }}
          animate={s.phase === "done" ? (reduce ? { opacity: 0 } : { opacity: 0, y: 18.5 - h / 2, scale: 0.3 }) : { opacity: 1, scale: 1, y: 0 }}
          transition={s.phase === "done" ? { duration: 0.55, ease: [0.55, 0, 0.2, 1] } : { duration: 0.3, ease: EASE }}
        >
          <svg width="52" height="52" viewBox="0 0 52 52" aria-hidden="true">
            <circle cx="26" cy="26" r="26" className="con-check-disc" />
            <motion.path d="M17 26.8l6 6 12-13" className="con-check" initial={reduce ? { opacity: 0 } : { pathLength: 0 }} animate={reduce ? { opacity: 1 } : { pathLength: 1 }} transition={{ duration: reduce ? 0.2 : 0.34, ease: EASE, delay: 0.15 }} />
          </svg>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function Words({ s }: { s: S }) {
  const reduce = useReducedMotion();
  const key = s.phase === "intro" || s.phase === "look" || s.phase === "success" || s.phase === "failure" ? s.phase : null;
  return (
    <AnimatePresence>
      {key && (
        <motion.div
          key={key + s.attempt}
          className={"con-words con-words-" + key}
          initial={reduce ? { opacity: 0 } : { opacity: 0, y: 8, filter: "blur(6px)" }}
          animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
          exit={{ opacity: 0, transition: { duration: 0.16, ease: "easeOut" } }}
          transition={{ duration: 0.42, ease: EASE, delay: key === "intro" ? 0.3 : key === "success" ? 0.2 : 0.12 }}
        >
          {key === "intro" && (
            <>
              <h1>Connect the stars</h1>
              <p>Look at each star until it lights up. Nine of them, about 15 seconds.</p>
              <div className="con-actions">
                <button className="cal-btn con-quiet">Not now</button>
                <button className="cal-btn con-primary" data-pressed={s.pressed === "start" || undefined}>Start</button>
              </div>
            </>
          )}
          {key === "look" && <p className="con-look">First, look up at the camera</p>}
          {key === "success" && (
            <>
              <h1>Calibrated</h1>
              <p>All nine stars took.</p>
            </>
          )}
          {key === "failure" && (
            <>
              <h1>Two stars didn’t take</h1>
              <p>The bottom-left corner was hard to read. A little more light usually helps. Your last calibration still works.</p>
              <div className="con-actions">
                <button className="cal-btn con-quiet">Not now</button>
                <button className="cal-btn con-primary" data-pressed={s.pressed === "retry" || undefined}>Retry those two</button>
              </div>
              <motion.span className="con-timer" initial={{ scaleX: 1 }} animate={{ scaleX: 0 }} transition={{ duration: 8, ease: "linear" }} />
            </>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  );
}
