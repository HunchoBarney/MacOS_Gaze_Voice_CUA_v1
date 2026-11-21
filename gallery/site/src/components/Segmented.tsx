import { motion } from "motion/react";
import type { ReactNode } from "react";

type Option<T extends string> = { value: T; label: ReactNode; title?: string };

export function Segmented<T extends string>({
  label,
  options,
  value,
  onChange,
  id,
  size = "md",
  className,
}: {
  label: string;
  options: Option<T>[];
  value: T;
  onChange: (value: T) => void;
  id: string;
  size?: "sm" | "md";
  className?: string;
}) {
  return (
    <div className={"segmented" + (className ? " " + className : "")} data-size={size} role="group" aria-label={label}>
      {options.map((option) => {
        const active = option.value === value;
        return (
          <button
            key={option.value}
            type="button"
            className="segmented-item"
            aria-pressed={active}
            title={option.title}
            aria-label={option.title}
            onClick={() => onChange(option.value)}
          >
            {active && (
              <motion.span
                className="segmented-pill"
                layoutId={"seg-" + id}
                transition={{ type: "spring", bounce: 0, duration: 0.28 }}
              />
            )}
            <span className="segmented-label">{option.label}</span>
          </button>
        );
      })}
    </div>
  );
}
