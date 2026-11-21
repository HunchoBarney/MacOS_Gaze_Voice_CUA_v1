import { useEffect, useMemo } from "react";
import { AnimatePresence, animate, motion, useMotionValue, useReducedMotion, useSpring, useTransform } from "motion/react";
import { PulsingBorder } from "@paper-design/shaders-react";
import { VoiceBeam } from "voice-glow";
import { BorderBeam } from "border-beam";
import { useScript } from "../clock";
import { usePursuit, type Pursuit } from "../pursuit";
import { StopControl, useDark, useViewport } from "../stage";
import type { DirectionProps } from "../main";
import "./edge.css";

// B · Edge light. Ambient: no panels and no objects. The display's own edge
// is the light; it gathers under the camera to say "look here", drops to each
// point and focuses there while you hold your gaze, and a hairline round the
// edge is the progress.

const EASE = [0.23, 1, 0.32, 1] as const;
const COOL = ["#0a84ff", "#bf5af2", "#ff375f", "#ff9f0a", "#64d2ff"];
const WARM = ["#ff9f0a", "#ff7a59", "#ffb340"];
const CORNER = 10;

export function EdgeLight({ scenario }: DirectionProps) {
  const s = useScript(scenario);
  const reduce = useReducedMotion();
  const dark = useDark();
  const { w, h } = useViewport();
  const pursuit = usePursuit(s, [w / 2, 26], 0.5);
  const edge = s.phase === "intro" || s.phase === "success";
  const tracking = ["look", "ready", "capture", "verify", "check"].includes(s.phase);

  return (
    <div className="edge" data-dark={dark || undefined}>
      <AnimatePresence>
        {edge && (
          <motion.div key="cool" className="edge-glow" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: s.phase === "done" ? 0.9 : 0.5, ease: "easeOut" } }} transition={{ duration: 0.6, ease: "easeOut" }}>
            <Glow colors={COOL} dark={dark} reduce={!!reduce} />
          </motion.div>
        )}
        {s.phase === "failure" && (
          <motion.div key="warm" className="edge-glow" initial={{ opacity: 0 }} animate={{ opacity: [0, 1, 0.2] }} exit={{ opacity: 0, transition: { duration: 0.3 } }} transition={{ duration: 8.4, times: [0, 0.05, 1], ease: "linear" }}>
            <Glow colors={WARM} dark={dark} reduce={!!reduce} />
          </motion.div>
        )}
      </AnimatePresence>
      <NotchLight on={s.phase === "look"} dark={dark} reduce={!!reduce} />
      <Perimeter s={s} p={pursuit.p} w={w} h={h} />
      <VerifyBeam on={s.phase === "verify" || s.phase === "check"} dark={dark} reduce={!!reduce} />
      <Focus s={s} pursuit={pursuit} />
      <Words s={s} />
      <StopControl visible={tracking} material="auto" />
    </div>
  );
}

function Glow({ colors, dark, reduce }: { colors: string[]; dark: boolean; reduce: boolean }) {
  return (
    <PulsingBorder
      className="edge-shader"
      colors={colors}
      colorBack="#00000000"
      roundness={0.06}
      thickness={dark ? 0.055 : 0.05}
      softness={1}
      intensity={dark ? 0.24 : 0.36}
      bloom={dark ? 0.35 : 0.12}
      spots={3}
      spotSize={0.45}
      pulse={0}
      smoke={0.35}
      smokeSize={0.5}
      scale={1}
      speed={reduce ? 0 : 0.45}
      maxPixelCount={1512 * 982}
    />
  );
}

// The camera cue: the edge light gathered into one beam under the notch.
function NotchLight({ on, dark, reduce }: { on: boolean; dark: boolean; reduce: boolean }) {
  const motionState = useMemo(() => ({ gather: 1, heldLevel: 0.85, stretch: 0 }), []);
  return (
    <motion.div className="edge-notch" initial={false} animate={{ opacity: on ? 1 : 0 }} transition={{ duration: on ? 0.45 : 0.35, ease: "easeOut", delay: on ? 0.15 : 0 }}>
      <VoiceBeam level={0.85} motion={motionState} theme={dark ? "dark" : "light"} active={on} idle={0} staticColors={reduce} flow={reduce ? 0 : 40} strength={1}>
        <div className="edge-notch-host" />
      </VoiceBeam>
    </motion.div>
  );
}

// Progress: a hairline that runs clockwise round the display from the notch.
function Perimeter({ s, p, w, h }: { s: ReturnType<typeof useScript>; p: Pursuit["p"]; w: number; h: number }) {
  const done = s.phase === "capture" ? s.k : s.phase === "ready" ? 0 : 9;
  const live = s.phase === "capture";
  const target = useTransform(p, (v) => Math.min(1, (done + (live ? v : 0)) / 9));
  const length = useSpring(0, { visualDuration: 0.35, bounce: 0 });
  useEffect(() => target.on("change", (v) => length.set(v)), [target]);
  useEffect(() => length.set(target.get()), [done, live]);
  const shown = ["ready", "capture", "verify"].includes(s.phase);
  const i = 1.5;
  const r = CORNER;
  const d = [
    "M", w / 2, i, "H", w - i - r, "A", r, r, 0, 0, 1, w - i, i + r, "V", h - i - r, "A", r, r, 0, 0, 1, w - i - r, h - i,
    "H", i + r, "A", r, r, 0, 0, 1, i, h - i - r, "V", i + r, "A", r, r, 0, 0, 1, i + r, i, "H", w / 2
  ].join(" ");
  return (
    <motion.svg className="edge-perimeter" width={w} height={h} initial={false} animate={{ opacity: shown ? 1 : 0 }} transition={{ duration: 0.4, ease: "easeOut" }} aria-hidden="true">
      <defs>
        <linearGradient id="edge-line" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#64d2ff" />
          <stop offset="0.5" stopColor="#bf5af2" />
          <stop offset="1" stopColor="#ff375f" />
        </linearGradient>
      </defs>
      <motion.path d={d} fill="none" stroke="url(#edge-line)" strokeWidth={3} strokeLinecap="round" style={{ pathLength: length }} />
    </motion.svg>
  );
}

function VerifyBeam({ on, dark, reduce }: { on: boolean; dark: boolean; reduce: boolean }) {
  return (
    <div className="edge-verify" data-on={on || undefined}>
      <BorderBeam size="md" colorVariant="colorful" theme={dark ? "dark" : "light"} active={on} duration={2.2} brightness={1.6} borderRadius={CORNER} staticColors={reduce} strength={reduce ? 0.6 : 1}>
        <div className="edge-verify-host" />
      </BorderBeam>
    </div>
  );
}

// Each point arrives soft and sharpens while you look: focus is the progress.
function Focus({ s, pursuit }: { s: ReturnType<typeof useScript>; pursuit: Pursuit }) {
  const reduce = useReducedMotion();
  const visible = s.phase === "ready" || s.phase === "capture" || s.phase === "verify";
  const sharp = useSpring(pursuit.p, { visualDuration: 0.3, bounce: 0 });
  const bloomScale = useTransform(sharp, [0, 1], reduce ? [1, 1] : [1, 0.26]);
  const bloomOpacity = useTransform(sharp, [0, 1], reduce ? [0.9, 0.12] : [0.85, 1]);
  const coreOpacity = useTransform(sharp, [0, 0.5, 1], [0.15, 0.55, 1]);
  const coreScale = useTransform(sharp, [0, 1], reduce ? [1, 1] : [0.55, 1]);
  const entrance = useMotionValue(0);
  useEffect(() => {
    const c = animate(entrance, visible ? 1 : 0, { duration: visible ? 0.35 : 0.3, ease: "easeOut" });
    return () => c.stop();
  }, [visible]);
  return (
    <motion.div className="edge-focus" style={{ x: pursuit.x, y: pursuit.y, opacity: entrance }} aria-hidden="true">
      <motion.span className="edge-bloom" style={{ scale: bloomScale, opacity: bloomOpacity }} />
      <motion.span className="edge-core" style={{ scale: coreScale, opacity: coreOpacity }} />
    </motion.div>
  );
}

function Words({ s }: { s: ReturnType<typeof useScript> }) {
  const reduce = useReducedMotion();
  const key = s.phase === "intro" ? "intro" : s.phase === "look" ? "look" : s.phase === "success" ? "success" : s.phase === "failure" ? "failure" : null;
  const enter = reduce ? { opacity: 0 } : { opacity: 0, y: 6, filter: "blur(6px)" };
  return (
    <AnimatePresence>
      {key && (
        <motion.div
          key={key + s.attempt}
          className={"edge-words edge-words-" + key}
          initial={key === "intro" ? enter : { ...enter }}
          animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
          exit={{ opacity: 0, filter: reduce ? "blur(0px)" : "blur(4px)", transition: { duration: 0.18, ease: "easeOut" } }}
          transition={{ duration: 0.42, ease: EASE, delay: key === "intro" ? 0.18 : key === "look" ? 0.3 : 0.12 }}
        >
          {key === "intro" && (
            <>
              <h1>Calibrate eye tracking</h1>
              <p>Look at each light until it’s sharp. About 15 seconds.</p>
              <div className="edge-actions">
                <button className="cal-btn edge-quiet">Not now</button>
                <button className="cal-btn edge-primary" data-pressed={s.pressed === "start" || undefined}>Start</button>
              </div>
            </>
          )}
          {key === "look" && <p className="edge-look">Look at the light under the camera</p>}
          {key === "success" && (
            <>
              <h1>You’re set</h1>
              <p>Jarvis can see where you look.</p>
            </>
          )}
          {key === "failure" && (
            <>
              <h1>That one didn’t take</h1>
              <p>A little more light on your face usually fixes it. Your last calibration still works.</p>
              <div className="edge-actions">
                <button className="cal-btn edge-quiet">Not now</button>
                <button className="cal-btn edge-primary" data-pressed={s.pressed === "retry" || undefined}>Try again</button>
              </div>
              <motion.span className="edge-timer" initial={{ scaleX: 1 }} animate={{ scaleX: 0 }} transition={{ duration: 8, ease: "linear" }} />
            </>
          )}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

