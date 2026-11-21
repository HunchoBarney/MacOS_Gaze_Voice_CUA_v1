import { useEffect } from "react";
import { AnimatePresence, animate, motion, useMotionValue, useReducedMotion, useTransform } from "motion/react";
import { BorderBeam } from "border-beam";
import { ThinkingOrb } from "thinking-orbs";
import { useScript } from "../clock";
import { T, type Phase } from "../script";
import { usePursuit } from "../pursuit";
import { StopControl, useDark, useViewport } from "../stage";
import type { DirectionProps } from "../main";
import "./island.css";

// A · Island. Apple-literal and contained: the whole calibration lives in, and
// comes out of, the notch. The notch is the "look here" light, the target is a
// drop of the island, and every message is the island growing to say it.

type Shape = "rest" | "compact" | "intro" | "checking" | "success" | "failure";
const SHAPES: Record<Shape, { w: number; h: number; r: number }> = {
  rest: { w: 185, h: 37, r: 10 },
  compact: { w: 277, h: 37, r: 18.5 },
  checking: { w: 330, h: 37, r: 18.5 },
  intro: { w: 476, h: 150, r: 38 },
  success: { w: 340, h: 96, r: 34 },
  failure: { w: 476, h: 166, r: 38 }
};
const shapeOf = (phase: Phase): Shape =>
  phase === "intro" ? "intro"
  : phase === "look" || phase === "ready" || phase === "capture" ? "compact"
  : phase === "verify" || phase === "check" ? "checking"
  : phase === "success" ? "success"
  : phase === "failure" ? "failure"
  : "rest";

const EASE = [0.23, 1, 0.32, 1] as const;
// The island's rounded top corners sit above the screen edge, so the visible
// shape is flush with the top like the notch it grows from.
const LIFT = 40;
const contentIn = { opacity: 1, filter: "blur(0px)", scale: 1 };
const contentOut = { opacity: 0, filter: "blur(4px)", scale: 0.97 };

export function Island({ scenario }: DirectionProps) {
  const s = useScript(scenario);
  const reduce = useReducedMotion();
  const dark = useDark();
  const { w } = useViewport();
  const shape = shapeOf(s.phase);
  const geo = SHAPES[shape];
  const grow = geo.w > 300;
  const pursuit = usePursuit(s, [w / 2, 18.5], 0.5);
  const dimmed = ["look", "ready", "capture", "verify", "check"].includes(s.phase);
  const done = s.phase === "capture" ? s.k : ["verify", "check", "success"].includes(s.phase) ? 9 : 0;

  return (
    <div className="isl" data-dark={dark || undefined}>
      <motion.div className="isl-dim" initial={false} animate={{ opacity: dimmed ? 1 : 0 }} transition={{ duration: dimmed ? 0.3 : 0.2, ease: "easeOut" }} />
      <Orb s={s} pursuit={pursuit} />
      <AnimatePresence>
        {s.phase === "look" && (
          <motion.div
            key={"look-" + s.attempt}
            className="isl-bubble"
            initial={reduce ? { opacity: 0 } : { opacity: 0, y: -16, scale: 0.6, filter: "blur(4px)" }}
            animate={{ opacity: 1, y: 0, scale: 1, filter: "blur(0px)" }}
            exit={reduce ? { opacity: 0 } : { opacity: 0, y: -12, scale: 0.7, filter: "blur(3px)", transition: { duration: 0.18, ease: "easeIn" } }}
            transition={reduce ? { duration: 0.2 } : { type: "spring", visualDuration: 0.42, bounce: 0.22, delay: 0.16 }}
          >
            Look at the camera
          </motion.div>
        )}
      </AnimatePresence>
      <div className="isl-anchor">
        <BorderBeam size="md" colorVariant="colorful" theme="dark" active={s.phase === "look"} duration={1.6} brightness={1.8} saturation={1.4} borderRadius={geo.r} staticColors={!!reduce} className="isl-beam">
          <motion.div
            className="isl-body"
            initial={false}
            animate={{ width: geo.w, height: geo.h + LIFT, borderRadius: geo.r }}
            transition={reduce ? { duration: 0 } : { type: "spring", visualDuration: grow ? 0.5 : 0.4, bounce: grow ? 0.18 : 0.08 }}
          >
            <span className="isl-fillet left" />
            <span className="isl-fillet right" />
            <Lens on={s.phase === "look"} attempt={s.attempt} />
            <AnimatePresence initial={false} mode="popLayout">
              <motion.div
                key={shape === "compact" || shape === "checking" ? "bar" : shape}
                className="isl-content"
                initial={contentOut}
                animate={contentIn}
                exit={{ ...contentOut, transition: { duration: 0.12, ease: "easeOut" } }}
                transition={{ duration: 0.26, ease: EASE, delay: grow ? 0.07 : 0.04 }}
              >
                <Content shape={shape} s={s} done={done} pursuitP={pursuit.p} />
              </motion.div>
            </AnimatePresence>
          </motion.div>
        </BorderBeam>
      </div>
      <StopControl visible={dimmed} material="dark" />
    </div>
  );
}

function Content({ shape, s, done, pursuitP }: { shape: Shape; s: ReturnType<typeof useScript>; done: number; pursuitP: ReturnType<typeof useMotionValue<number>> }) {
  if (shape === "rest") return null;
  if (shape === "compact" || shape === "checking") {
    return (
      <div className="isl-bar">
        <EyeGlyph />
        <div className="isl-trail">
          <AnimatePresence initial={false} mode="popLayout">
            {shape === "checking" ? (
              <motion.div key="check" className="isl-checking" initial={{ opacity: 0, filter: "blur(3px)" }} animate={{ opacity: 1, filter: "blur(0px)" }} exit={{ opacity: 0 }} transition={{ duration: 0.22, ease: "easeOut" }}>
                <span>Checking</span>
                <ThinkingOrb state="searching" size={20} theme="dark" />
              </motion.div>
            ) : (
              <motion.div key="ring" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.18 }}>
                <MiniRing done={done} p={pursuitP} live={s.phase === "capture"} />
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </div>
    );
  }
  if (shape === "intro") {
    return (
      <div className="isl-card">
        <div className="isl-wing"><EyeGlyph /></div>
        <div className="isl-text">
          <div className="isl-title">Calibrate eye tracking</div>
          <div className="isl-sub">Look at each light until it fills. About 15 seconds.</div>
        </div>
        <div className="isl-actions">
          <button className="cal-btn isl-quiet">Not now</button>
          <button className="cal-btn isl-primary" data-pressed={s.pressed === "start" || undefined}>Start</button>
        </div>
      </div>
    );
  }
  if (shape === "success") {
    return (
      <div className="isl-card isl-success">
        <Check />
        <div className="isl-text">
          <div className="isl-title">Calibrated</div>
          <div className="isl-sub">Jarvis can see where you look.</div>
        </div>
      </div>
    );
  }
  return (
    <div className="isl-card">
      <div className="isl-wing"><EyeGlyph muted /></div>
      <div className="isl-text">
        <div className="isl-title">Couldn’t get a steady read</div>
        <div className="isl-sub">More light on your face usually fixes it. Your last calibration still works.</div>
      </div>
      <div className="isl-actions">
        <button className="cal-btn isl-quiet">Not now</button>
        <button className="cal-btn isl-primary" data-pressed={s.pressed === "retry" || undefined}>Try again</button>
      </div>
      <Timer />
    </div>
  );
}

// Auto-dismiss in 8 s unless answered (ET-2): a hairline that empties.
function Timer() {
  return <motion.span className="isl-timer" initial={{ scaleX: 1 }} animate={{ scaleX: 0 }} transition={{ duration: 8, ease: "linear" }} />;
}

function MiniRing({ done, p, live }: { done: number; p: ReturnType<typeof useMotionValue<number>>; live: boolean }) {
  const fill = useTransform(p, (v) => Math.min(1, (done + (live ? v : 0)) / 9));
  return (
    <svg className="isl-mini" width="18" height="18" viewBox="0 0 18 18" aria-label={done + " of 9"}>
      <circle cx="9" cy="9" r="7" className="isl-mini-track" />
      <motion.circle cx="9" cy="9" r="7" className="isl-mini-fill" style={{ pathLength: fill }} />
    </svg>
  );
}

function Orb({ s, pursuit }: { s: ReturnType<typeof useScript>; pursuit: ReturnType<typeof usePursuit> }) {
  const reduce = useReducedMotion();
  const visible = s.phase === "ready" || s.phase === "capture" || s.phase === "verify";
  const measuring = s.phase === "verify";
  const stroke = useTransform(pursuit.p, [0, 0.97, 1], ["#ffffff", "#ffffff", "#30d158"]);
  const scale = useMotionValue(0.5);
  useEffect(() => {
    if (reduce) {
      scale.jump(measuring ? 0.72 : 1);
      return;
    }
    const c = animate(scale, visible ? (measuring ? 0.72 : 1) : 0.4, { type: "spring", visualDuration: 0.36, bounce: 0 });
    return () => c.stop();
  }, [visible, measuring, reduce]);
  return (
    <motion.div className="isl-orb" style={{ x: pursuit.x, y: pursuit.y }}>
      <motion.div
        className="isl-orb-disc"
        style={{ scale }}
        initial={false}
        animate={{ opacity: visible ? 1 : 0 }}
        transition={{ duration: visible ? 0.2 : 0.24, ease: "easeOut" }}
      >
        <svg width="48" height="48" viewBox="0 0 48 48" aria-hidden="true">
          <motion.g style={{ opacity: pursuit.ring }}>
            <circle cx="24" cy="24" r="19" className="isl-orb-track" />
            <motion.circle cx="24" cy="24" r="19" className="isl-orb-fill" style={{ pathLength: pursuit.p, stroke }} />
          </motion.g>
        </svg>
        <span className="isl-orb-core" />
      </motion.div>
    </motion.div>
  );
}

// The camera cue: the first point is the camera itself. A ring of light
// round the lens fills while you look at it, the same ring every point uses,
// then the drop that leaves it becomes the first target.
function Lens({ on, attempt }: { on: boolean; attempt: number }) {
  const reduce = useReducedMotion();
  const fill = useMotionValue(0);
  useEffect(() => {
    if (!on) return;
    fill.jump(0);
    const lookMs = T.ready - T.look;
    const c = animate(fill, 1, { delay: 0.55, duration: (lookMs - 750) / 1000, ease: "linear" });
    return () => c.stop();
  }, [on, attempt]);
  return (
    <motion.div className="isl-lens" initial={false} animate={{ opacity: on ? 1 : 0, scale: on || reduce ? 1 : 0.7 }} transition={{ duration: on ? 0.3 : 0.2, ease: on ? EASE : "easeIn", delay: on ? 0.12 : 0 }}>
      <span className="isl-lens-glow" />
      <svg width="34" height="34" viewBox="0 0 34 34" aria-hidden="true">
        <circle cx="17" cy="17" r="13" className="isl-lens-track" />
        <motion.circle cx="17" cy="17" r="13" className="isl-lens-fill" style={{ pathLength: fill }} />
      </svg>
    </motion.div>
  );
}

function EyeGlyph({ muted }: { muted?: boolean }) {
  return (
    <svg className="isl-eye" data-muted={muted || undefined} width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M1.8 10c2.2-4 5-6 8.2-6s6 2 8.2 6c-2.2 4-5 6-8.2 6s-6-2-8.2-6z" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
      <circle cx="10" cy="10" r="2.7" fill="currentColor" />
    </svg>
  );
}

function Check() {
  const reduce = useReducedMotion();
  return (
    <svg className="isl-check" width="34" height="34" viewBox="0 0 34 34" aria-hidden="true">
      <circle cx="17" cy="17" r="17" fill="#30d158" />
      <motion.path
        d="M10.5 17.5l4.3 4.3 8.7-9.3"
        fill="none"
        stroke="#fff"
        strokeWidth="2.6"
        strokeLinecap="round"
        strokeLinejoin="round"
        initial={reduce ? { opacity: 0 } : { pathLength: 0 }}
        animate={reduce ? { opacity: 1 } : { pathLength: 1 }}
        transition={{ duration: reduce ? 0.2 : 0.32, ease: EASE, delay: 0.18 }}
      />
    </svg>
  );
}
