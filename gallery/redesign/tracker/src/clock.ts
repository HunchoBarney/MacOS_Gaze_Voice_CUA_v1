import { useEffect, useState } from "react";
import { at, type Scenario, type ScriptState } from "./script";

// Script time is performance.now() since mount. In the renderer the gallery's
// fixture bootstrap swaps performance.now and requestAnimationFrame for a
// manual clock, so every frame is exact; in a browser it runs in real time.
const params = new URLSearchParams(location.search);
const hold = params.has("hold") ? Number(params.get("hold")) : null;
let origin = performance.now();

export const resetClock = () => {
  origin = performance.now();
};
export const scriptNow = () => (hold !== null ? hold : performance.now() - origin);

const same = (a: ScriptState, b: ScriptState) => a.phase === b.phase && a.k === b.k && a.pressed === b.pressed && a.attempt === b.attempt;

// Discrete script state only: phase, point index, press. React re-renders on
// those changes, never per frame; continuous motion lives in motion values.
export function useScript(scenario: Scenario): ScriptState {
  const [state, setState] = useState(() => at(scriptNow(), scenario));
  useEffect(() => {
    let id = 0;
    const tick = () => {
      const next = at(scriptNow(), scenario);
      setState((prev) => (same(prev, next) ? prev : next));
      id = requestAnimationFrame(tick);
    };
    id = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(id);
  }, [scenario]);
  return state;
}
