import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { DisplayIcon, MoonIcon, SearchIcon, SunIcon, Waveform } from "./components/Icons";
import { Segmented } from "./components/Segmented";
import { useGallery } from "./data";
import { Audit } from "./pages/Audit";
import { ComponentPage } from "./pages/ComponentPage";
import { Home } from "./pages/Home";
import { NotFound } from "./pages/NotFound";
import { ScenePage, Scenes } from "./pages/Scenes";
import { Link, useLocation } from "./router";
import { scrollToTop } from "./scroll";
import { setTheme, useTheme, type ThemeChoice } from "./theme";
import type { Gallery } from "./types";

const loadPalette = () => import("./components/Palette");
const Palette = lazy(loadPalette);
const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
const NEXT_THEME: Record<ThemeChoice, ThemeChoice> = { system: "light", light: "dark", dark: "system" };
const THEME_NAMES: Record<ThemeChoice, string> = { system: "match system", light: "light", dark: "dark" };

function route(pathname: string, gallery: Gallery) {
  const [, first, second] = pathname.split("/").map(decodeURIComponent);
  if (!first) return { title: "", page: <Home gallery={gallery} /> };
  if (first === "c" && second) {
    const component = gallery.components.find((c) => c.id === second);
    return { title: component?.title ?? "Not found", page: <ComponentPage gallery={gallery} id={second} /> };
  }
  if (first === "scenes" && !second) return { title: "Scenes", page: <Scenes gallery={gallery} /> };
  if (first === "scenes" && second) {
    const scene = gallery.scenes.find((s) => s.id === second);
    return { title: scene?.title ?? "Not found", page: <ScenePage gallery={gallery} id={second} /> };
  }
  if (first === "audit") return { title: "Audit", page: <Audit gallery={gallery} /> };
  return { title: "Not found", page: <NotFound /> };
}

export function App() {
  const load = useGallery();
  const { pathname, hash } = useLocation();
  const theme = useTheme();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [paletteWanted, setPaletteWanted] = useState(false);
  const sentinel = useRef<HTMLDivElement>(null);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key.toLowerCase() === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setPaletteWanted(true);
        setPaletteOpen((open) => !open);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (!hash) scrollToTop();
  }, [pathname]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const observer = new IntersectionObserver(([entry]) => setScrolled(!entry.isIntersecting));
    if (sentinel.current) observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, []);

  const resolved = load.status === "ready" ? route(pathname, load.gallery) : undefined;

  useEffect(() => {
    document.title = resolved?.title ? resolved.title + " · Jarvis UI gallery" : "Jarvis UI gallery";
  }, [resolved?.title]);

  const section = pathname.startsWith("/scenes") ? "scenes" : pathname.startsWith("/audit") ? "audit" : "components";

  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <div ref={sentinel} className="sentinel" aria-hidden="true" />
      <header className="bar" data-scrolled={scrolled || undefined}>
        <div className="bar-inner">
          <Link className="brand" href="/" aria-label="Jarvis UI gallery, home">
            <span className="brand-mark" aria-hidden="true">
              <Waveform size={14} />
            </span>
            <span className="brand-name">Jarvis</span>
            <span className="brand-sub">UI gallery</span>
          </Link>
          <nav className="nav" aria-label="Sections">
            <Link href="/" aria-current={section === "components" ? "page" : undefined}>
              Components
            </Link>
            <Link href="/scenes" aria-current={section === "scenes" ? "page" : undefined}>
              Scenes
            </Link>
            <Link href="/audit" aria-current={section === "audit" ? "page" : undefined}>
              Audit
            </Link>
          </nav>
          <div className="bar-tools">
            <button
              type="button"
              className="search-button"
              onPointerEnter={() => void loadPalette()}
              onFocus={() => void loadPalette()}
              onClick={() => {
                setPaletteWanted(true);
                setPaletteOpen(true);
              }}
              aria-label="Jump to"
              aria-keyshortcuts={isMac ? "Meta+K" : "Control+K"}
            >
              <SearchIcon />
              <span className="search-label">Jump to</span>
              <kbd className="search-kbd">{isMac ? "⌘K" : "Ctrl K"}</kbd>
            </button>
            <button
              type="button"
              className="icon-button theme-cycle"
              onClick={() => setTheme(NEXT_THEME[theme.choice])}
              aria-label={"Theme: " + THEME_NAMES[theme.choice] + ". Switch to " + THEME_NAMES[NEXT_THEME[theme.choice]]}
            >
              {theme.choice === "system" ? <DisplayIcon /> : theme.choice === "light" ? <SunIcon /> : <MoonIcon />}
            </button>
            <Segmented<ThemeChoice>
              id="theme"
              className="theme-seg"
              label="Theme"
              size="sm"
              value={theme.choice}
              onChange={setTheme}
              options={[
                { value: "system", label: <DisplayIcon size={14} />, title: "Match system" },
                { value: "light", label: <SunIcon size={14} />, title: "Light" },
                { value: "dark", label: <MoonIcon size={14} />, title: "Dark" },
              ]}
            />
          </div>
        </div>
      </header>

      <main id="main" tabIndex={-1}>
        {load.status === "loading" && <div className="page loading" aria-busy="true" />}
        {load.status === "error" && (
          <section className="page empty-page">
            <h1 className="title-1">The gallery data didn’t load</h1>
            <p className="lede">{load.message}. Run the collect step, then rebuild.</p>
          </section>
        )}
        {resolved?.page}
      </main>

      {load.status === "ready" && (
        <footer className="footer page">
          <p>
            Rendered from{" "}
            {load.gallery.producers.map((p, i) => (
              <span key={p.producer}>
                {i > 0 && ", "}
                {p.producer} <code>{p.commit}</code>
              </span>
            ))}{" "}
            on {new Date(load.gallery.generatedAt).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })}. Fixture data only.
          </p>
          <p>
            <a href="https://github.com/HunchoBarney/MacOS_Gaze_Voice_CUA_v1" target="_blank" rel="noreferrer">
              Source on GitHub
            </a>
          </p>
        </footer>
      )}

      {load.status === "ready" && paletteWanted && (
        <Suspense fallback={null}>
          <Palette gallery={load.gallery} open={paletteOpen} onClose={() => setPaletteOpen(false)} />
        </Suspense>
      )}
    </>
  );
}
