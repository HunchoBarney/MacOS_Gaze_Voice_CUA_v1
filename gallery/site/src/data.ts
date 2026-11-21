import { useSyncExternalStore } from "react";
import type { Component, Finding, Gallery, Scene, SceneVariant, Scheme, Severity, State, Variant } from "./types";
import { SEVERITIES } from "./types";

type Load = { status: "loading" } | { status: "error"; message: string } | { status: "ready"; gallery: Gallery };

let load: Load = { status: "loading" };
const listeners = new Set<() => void>();

fetch(asset("gallery.json"))
  .then((response) => {
    if (!response.ok) throw new Error("gallery.json returned " + response.status);
    return response.json() as Promise<Gallery>;
  })
  .then((gallery) => {
    load = { status: "ready", gallery };
  })
  .catch((error: unknown) => {
    load = { status: "error", message: error instanceof Error ? error.message : String(error) };
  })
  .finally(() => listeners.forEach((listener) => listener()));

export function useGallery(): Load {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => load,
  );
}

export function asset(path: string): string {
  return import.meta.env.BASE_URL + "renders/" + path;
}

export function sourceUrl(source: string): string {
  const [path, line] = source.split(":");
  return "https://github.com/HunchoBarney/MacOS_Gaze_Voice_CUA_v1/blob/main/" + path + (line ? "#L" + line : "");
}

export function pickVariant(state: State, scheme: Scheme, reduceMotion: boolean): { variant: Variant | undefined; exact: boolean } {
  const exact = state.variants.find((v) => v.scheme === scheme && v.reduceMotion === reduceMotion);
  if (exact) return { variant: exact, exact: true };
  const fallback =
    state.variants.find((v) => v.scheme === scheme && !v.reduceMotion) ??
    state.variants.find((v) => v.scheme === scheme) ??
    state.variants.find((v) => v.reduceMotion === reduceMotion) ??
    state.variants[0];
  return { variant: fallback, exact: false };
}

export function sceneVariant(scene: Scene, scheme: Scheme): SceneVariant {
  const variants = scene.variants ?? [];
  return (
    variants.find((v) => v.scheme === scheme) ??
    variants[0] ?? { scheme: "dark", image: scene.image, width: scene.width, height: scene.height, thumb: scene.thumb, clip: scene.clip }
  );
}

export function isTall(picture: { width: number; height: number }) {
  return picture.height / picture.width > 1.2;
}

export function coverVariant(component: Component, scheme: Scheme): Variant | undefined {
  const state = component.states.find((s) => (s.kind ?? "current") === "current") ?? component.states[0];
  return state ? pickVariant(state, scheme, false).variant : undefined;
}

export function baseStateFor(component: Component, proposed: State): State | undefined {
  const current = component.states.filter((s) => (s.kind ?? "current") === "current");
  const base = proposed.id.replace(/-proposed$/, "").replace(/^proposed-/, "");
  return current.find((s) => s.id === base) ?? current.find((s) => s.id.endsWith("-" + base)) ?? current[0];
}

export function severityCounts(findings: Finding[]): Record<Severity, number> {
  const counts = { P0: 0, P1: 0, P2: 0, P3: 0 };
  for (const finding of findings) counts[finding.severity] += 1;
  return counts;
}

export function bySeverity(a: Finding, b: Finding): number {
  return SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity) || a.id.localeCompare(b.id, undefined, { numeric: true });
}

export function plural(count: number, one: string, many = one + "s"): string {
  return count + " " + (count === 1 ? one : many);
}
