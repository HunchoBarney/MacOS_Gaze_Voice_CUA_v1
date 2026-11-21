import type Lenis from "lenis";

let lenis: Lenis | undefined;

const reduceMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export async function startSmoothScroll() {
  if (reduceMotion() || !matchMedia("(hover: hover) and (pointer: fine)").matches) return;
  const { default: LenisClass } = await import("lenis");
  lenis = new LenisClass({ autoRaf: true, lerp: 0.14, anchors: false });
  matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", (event) => {
    if (event.matches) {
      lenis?.destroy();
      lenis = undefined;
    }
  });
}

export function scrollToTop() {
  if (lenis) lenis.scrollTo(0, { immediate: true, force: true });
  else window.scrollTo(0, 0);
}

export function scrollToElement(element: HTMLElement, { smooth = false } = {}) {
  const offset = -76;
  if (!smooth) {
    element.scrollIntoView({ block: "start" });
    return;
  }
  if (lenis) {
    lenis.scrollTo(element, { offset, immediate: !smooth, force: true, duration: 0.6 });
    return;
  }
  const top = element.getBoundingClientRect().top + window.scrollY + offset;
  window.scrollTo({ top, behavior: smooth && !reduceMotion() ? "smooth" : "auto" });
}
