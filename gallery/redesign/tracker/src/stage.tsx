import { useEffect, useState, type ReactNode } from "react";

// The fixture MacBook desktop: the gallery's flat fixture desktop
// (gallery/tracker/fixture/bootstrap.js, DESKTOP_CSS) with a placeholder menu
// bar and the notch drawn at the top centre (185 x 37 pt). No real screen
// content: every shape is a placeholder.
export const NOTCH = { width: 185, height: 37 };

export function useMedia(query: string) {
  const [matches, setMatches] = useState(() => matchMedia(query).matches);
  useEffect(() => {
    const list = matchMedia(query);
    const update = () => setMatches(list.matches);
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, [query]);
  return matches;
}
export const useDark = () => useMedia("(prefers-color-scheme: dark)");
export const useReducedTransparency = () => useMedia("(prefers-reduced-transparency: reduce)");

export function useViewport() {
  const [size, setSize] = useState(() => ({ w: innerWidth, h: innerHeight }));
  useEffect(() => {
    const update = () => setSize({ w: innerWidth, h: innerHeight });
    addEventListener("resize", update);
    return () => removeEventListener("resize", update);
  }, []);
  return size;
}

export function Desktop({ children }: { children: ReactNode }) {
  return (
    <div className="desktop">
      <div className="desktop-window" aria-hidden="true">
        <div className="desktop-window-lines" />
      </div>
      <div className="menubar" aria-hidden="true">
        <div className="menubar-left">
          <span className="mb-glyph" />
          <span className="mb-item" style={{ width: 42 }} />
          <span className="mb-item" style={{ width: 28 }} />
          <span className="mb-item" style={{ width: 30 }} />
          <span className="mb-item" style={{ width: 36 }} />
        </div>
        <div className="menubar-right">
          <span className="mb-icon" />
          <span className="mb-icon" />
          <span className="mb-icon" />
          <span className="mb-item" style={{ width: 78 }} />
        </div>
      </div>
      {children}
      <Notch />
    </div>
  );
}

export function Notch() {
  return (
    <div className="notch" aria-hidden="true">
      <span className="notch-fillet left" />
      <span className="notch-fillet right" />
      <span className="notch-lens" />
    </div>
  );
}

export function StopControl({ visible, material }: { visible: boolean; material: "dark" | "auto" }) {
  return (
    <button className="stop" data-visible={visible || undefined} data-material={material} tabIndex={visible ? 0 : -1} aria-label="Stop calibration">
      <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
        <path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
      <span>Stop</span>
      <kbd>esc</kbd>
    </button>
  );
}
