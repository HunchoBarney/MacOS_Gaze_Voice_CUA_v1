import { useEffect } from "react";
import { animate, useMotionValue, useReducedMotion, useSpring, type MotionValue } from "motion/react";
import { POINTS, VERIFY, T, dwellOf, type ScriptState } from "./script";
import { useViewport } from "./stage";

// Where the eyes should be, as two independent critically damped springs
// (apple-design: decompose 2D motion into X and Y), and the dwell progress of
// the current point as a motion value. Neither goes through React state, so
// nothing re-renders per frame (ET-5). Under Reduce Motion the position jumps.
export type Pursuit = { x: MotionValue<number>; y: MotionValue<number>; p: MotionValue<number>; ring: MotionValue<number> };

export function pointAt(s: ScriptState): [number, number] | null {
  if (s.phase === "ready" || s.phase === "capture") return POINTS[Math.max(0, s.k)];
  if (s.phase === "verify") return VERIFY[Math.min(VERIFY.length - 1, s.k)];
  return null;
}

export function usePursuit(s: ScriptState, origin: [number, number], visualDuration = 0.42): Pursuit {
  const { w, h } = useViewport();
  const reduce = useReducedMotion();
  const spring = { visualDuration, bounce: 0 };
  const x = useSpring(origin[0], spring);
  const y = useSpring(origin[1], spring);
  const p = useMotionValue(0);
  const ring = useMotionValue(0);

  useEffect(() => {
    if (s.phase === "look" || s.phase === "intro") {
      x.jump(origin[0]);
      y.jump(origin[1]);
      return;
    }
    const point = pointAt(s);
    if (!point) return;
    const [tx, ty] = [point[0] * w, point[1] * h];
    if (reduce) {
      x.jump(tx);
      y.jump(ty);
    } else {
      x.set(tx);
      y.set(ty);
    }
  }, [s.phase, s.k, w, h]);

  useEffect(() => {
    if (s.phase === "capture") {
      const { delay, duration } = dwellOf(s.k);
      const total = delay + 170;
      const progress = animate(p, [0, 1], { delay: delay / 1000, duration: duration / 1000, ease: "linear" });
      const shown = s.k === 0
        ? animate(ring, [0, 0, 1], { duration: total / 1000, times: [0, delay / total, 1] })
        : animate(ring, [1, 0, 0, 1], { duration: total / 1000, times: [0, 120 / total, delay / total, 1] });
      return () => {
        progress.stop();
        shown.stop();
      };
    }
    if (s.phase === "verify") {
      const progress = animate(p, [0, 1], { delay: 0.3, duration: (T.verifyPoint - 340) / 1000, ease: "linear" });
      const shown = animate(ring, 0, { duration: 0.12 });
      return () => {
        progress.stop();
        shown.stop();
      };
    }
    p.jump(0);
    const shown = animate(ring, 0, { duration: 0.15 });
    return () => shown.stop();
  }, [s.phase, s.k]);

  return { x, y, p, ring };
}
