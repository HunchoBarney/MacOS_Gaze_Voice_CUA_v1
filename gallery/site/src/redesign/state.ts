import { useSyncExternalStore } from "react";
import type { Clip, Component, Direction, Gallery, Media, MediaKey, MediaSet, RedesignComponent, Scheme, State } from "../types";
import { pickVariant } from "../data";

function store<T>(read: () => T) {
  let value = read();
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set(next: T) {
      value = next;
      listeners.forEach((listener) => listener());
    },
    reload() {
      value = read();
      listeners.forEach((listener) => listener());
    },
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

function readStorage(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStorage(key: string, value: string | null) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Private browsing without storage: the value lasts for this page only.
  }
}

const RM_KEY = "jarvis-redesign-rm";
const PICKS_KEY = "jarvis-redesign-picks";
const systemReducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

const rmStore = store(() => {
  const stored = readStorage(RM_KEY);
  return stored === null ? systemReducedMotion.matches : stored === "1";
});

export function useReduceMotion() {
  return useSyncExternalStore(rmStore.subscribe, rmStore.get);
}

export function setReduceMotion(next: boolean) {
  writeStorage(RM_KEY, next === systemReducedMotion.matches ? null : next ? "1" : "0");
  rmStore.set(next);
}

systemReducedMotion.addEventListener("change", () => {
  if (readStorage(RM_KEY) === null) rmStore.reload();
});

export type Speed = "1" | "0.5" | "0.25";
const speedStore = store<Speed>(() => "1");
export const useSpeed = () => useSyncExternalStore(speedStore.subscribe, speedStore.get);
export const setSpeed = (next: Speed) => speedStore.set(next);
export const SPEEDS: Speed[] = ["1", "0.5", "0.25"];
export const SPEED_LABEL: Record<Speed, string> = { "1": "1×", "0.5": "½×", "0.25": "¼×" };

export type Choice = "A" | "B" | "C" | "current" | "none";
export type Pick = { choice?: Choice; note?: string };
export type Picks = Record<string, Pick>;

const picksStore = store<Picks>(() => {
  try {
    const parsed = JSON.parse(readStorage(PICKS_KEY) ?? "{}");
    return parsed && typeof parsed === "object" ? (parsed as Picks) : {};
  } catch {
    return {};
  }
});

window.addEventListener("storage", (event) => {
  if (event.key === PICKS_KEY) picksStore.reload();
  if (event.key === RM_KEY) rmStore.reload();
});

export const usePicks = () => useSyncExternalStore(picksStore.subscribe, picksStore.get);

export function updatePick(id: string, change: Pick) {
  const merged = { ...picksStore.get()[id], ...change };
  const next = { ...picksStore.get() };
  if (!merged.choice && !merged.note) delete next[id];
  else next[id] = merged;
  replacePicks(next);
}

export function replacePicks(next: Picks) {
  writeStorage(PICKS_KEY, Object.keys(next).length ? JSON.stringify(next) : null);
  picksStore.set(next);
}

export function choiceLabel(component: RedesignComponent, choice: Choice): string {
  if (choice === "current") return "Keep current";
  if (choice === "none") return "None of these";
  const direction = component.directions.find((d) => d.id === choice);
  return direction ? choice + " (" + direction.name + ")" : choice;
}

export function picksSummary(components: RedesignComponent[], picks: Picks, today = new Date()): string {
  const lines = ["Jarvis redesign picks (" + today.toLocaleDateString("en-CA") + ")"];
  const open: string[] = [];
  for (const component of components) {
    const pick = picks[component.id];
    const note = pick?.note?.trim();
    if (pick?.choice) lines.push(component.id + ": " + choiceLabel(component, pick.choice) + (note ? " — " + note : ""));
    else if (note) lines.push(component.id + ": no pick yet — " + note);
    else open.push(component.id);
  }
  if (open.length) lines.push("", "Not picked yet: " + open.join(", "));
  return lines.join("\n");
}

export type Resolved = { media: Media; key: MediaKey; rmMissing: boolean; schemeMissing: boolean };

// Contract fallback: the asked-for key, then dark <-> light, and Reduce Motion falls back to the
// full-motion render with a visible note.
export function pickMedia(set: MediaSet | undefined, scheme: Scheme, rm: boolean): Resolved | undefined {
  if (!set) return undefined;
  const other: Scheme = scheme === "dark" ? "light" : "dark";
  const order: { key: MediaKey; rmMissing: boolean; schemeMissing: boolean }[] = rm
    ? [
        { key: (scheme + "-rm") as MediaKey, rmMissing: false, schemeMissing: false },
        { key: scheme, rmMissing: true, schemeMissing: false },
        { key: (other + "-rm") as MediaKey, rmMissing: false, schemeMissing: true },
        { key: other, rmMissing: true, schemeMissing: true },
      ]
    : [
        { key: scheme, rmMissing: false, schemeMissing: false },
        { key: other, rmMissing: false, schemeMissing: true },
      ];
  for (const option of order) {
    const media = set[option.key];
    if (media) return { media, ...option };
  }
  return undefined;
}

export const FLOW = "flow";

export function stateIds(component: RedesignComponent): { id: string; title: string }[] {
  const seen = new Map<string, string>();
  for (const direction of component.directions) for (const state of direction.states) if (!seen.has(state.id)) seen.set(state.id, state.title);
  return [...seen].map(([id, title]) => ({ id, title }));
}

export function directionMedia(direction: Direction, stateId: string): MediaSet | undefined {
  if (stateId === FLOW) return direction.flow;
  return direction.states.find((s) => s.id === stateId)?.media;
}

export type CurrentOption = { component: Component; state: State };

export function currentOptions(gallery: Gallery, component: RedesignComponent): CurrentOption[] {
  const options: CurrentOption[] = [];
  for (const id of component.current.componentIds) {
    const found = gallery.components.find((c) => c.id === id);
    if (!found) continue;
    for (const state of found.states) if ((state.kind ?? "current") === "current") options.push({ component: found, state });
  }
  return options;
}

export function currentMedia(option: CurrentOption, scheme: Scheme, rm: boolean): Resolved | undefined {
  const clips = option.state.clips ?? [];
  const clip: Clip | undefined = clips.find((c) => c.scheme === scheme && c.reduceMotion === rm) ?? (rm ? undefined : clips.find((c) => !c.reduceMotion));
  if (clip)
    return {
      media: { kind: "clip", src: clip.video, poster: clip.poster, width: clip.width, height: clip.height, duration: clip.durationMs / 1000 },
      key: (clip.scheme + (clip.reduceMotion ? "-rm" : "")) as MediaKey,
      rmMissing: false,
      schemeMissing: clip.scheme !== scheme,
    };
  const { variant } = pickVariant(option.state, scheme, rm);
  if (!variant) return undefined;
  return {
    media: { kind: "still", src: variant.image, width: variant.width, height: variant.height },
    key: (variant.scheme + (variant.reduceMotion ? "-rm" : "")) as MediaKey,
    rmMissing: rm && !variant.reduceMotion,
    schemeMissing: variant.scheme !== scheme,
  };
}

export type Batch = { n: 1 | 2 | 3; title: string; expected: string[] };

export const BATCHES: Batch[] = [
  { n: 1, title: "Voice, gaze and confirmation", expected: ["Voice surface", "Gaze highlight and orb", "Calibration and camera marker", "Confirmation and “this” flashes, press glow"] },
  { n: 2, title: "Agents and guidance", expected: ["Agent cursor and shelf", "Guide callout", "Chips and “Things you can say”", "Ask and problem cards"] },
  { n: 3, title: "Windows", expected: ["Menu bar", "Settings", "Agents", "First run"] },
];
