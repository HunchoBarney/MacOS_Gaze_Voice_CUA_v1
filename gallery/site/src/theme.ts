import { useSyncExternalStore } from "react";
import type { Scheme } from "./types";

export type ThemeChoice = "system" | Scheme;
const KEY = "jarvis-gallery-theme";
const media = matchMedia("(prefers-color-scheme: dark)");
const listeners = new Set<() => void>();

function stored(): ThemeChoice {
  try {
    const value = localStorage.getItem(KEY);
    return value === "light" || value === "dark" ? value : "system";
  } catch {
    return "system";
  }
}

let choice: ThemeChoice = stored();
let snapshot = { choice, resolved: resolve(choice) };

function resolve(value: ThemeChoice): Scheme {
  return value === "system" ? (media.matches ? "dark" : "light") : value;
}

function apply() {
  snapshot = { choice, resolved: resolve(choice) };
  document.documentElement.dataset.theme = snapshot.resolved;
  listeners.forEach((listener) => listener());
}

media.addEventListener("change", () => {
  if (choice === "system") apply();
});

export function setTheme(next: ThemeChoice) {
  choice = next;
  try {
    if (next === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, next);
  } catch {
    // Private browsing without storage: the choice lasts for this page only.
  }
  const swap = () => apply();
  const doc = document as Document & { startViewTransition?: (callback: () => void) => unknown };
  if (doc.startViewTransition && snapshot.resolved !== resolve(next)) doc.startViewTransition(swap);
  else swap();
}

export function useTheme() {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => snapshot,
  );
}
