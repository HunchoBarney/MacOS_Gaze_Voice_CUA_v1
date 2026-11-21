import { motion } from "motion/react";
import { useEffect, useRef } from "react";
import type { State } from "../types";
import { KindTag } from "./KindTag";

export function StateTabs({
  states,
  selected,
  instant,
  onSelect,
}: {
  states: State[];
  selected: string;
  instant: boolean;
  onSelect: (id: string) => void;
}) {
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const active = list.current?.querySelector<HTMLElement>('[aria-selected="true"]');
    active?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [selected]);
  return (
    <div className="tabs-wrap">
      <div ref={list} className="tabs" role="tablist" aria-label="States" data-lenis-prevent>
        {states.map((state) => {
          const active = state.id === selected;
          return (
            <button
              key={state.id}
              type="button"
              role="tab"
              id={"tab-" + state.id}
              aria-selected={active}
              aria-controls="stage-panel"
              tabIndex={active ? 0 : -1}
              className="tab"
              onClick={() => onSelect(state.id)}
            >
              {active && (
                <motion.span
                  className="tab-pill"
                  layoutId="state-pill"
                  transition={instant ? { duration: 0 } : { type: "spring", bounce: 0, duration: 0.3 }}
                />
              )}
              <span className="tab-label">
                {state.title}
                <KindTag item={state} />
              </span>
            </button>
          );
        })}
      </div>
      <p className="tabs-hint" aria-hidden="true">
        <kbd>←</kbd>
        <kbd>→</kbd>
      </p>
    </div>
  );
}
