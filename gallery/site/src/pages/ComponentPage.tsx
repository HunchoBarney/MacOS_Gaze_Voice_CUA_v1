import { useEffect, useMemo, useRef, useState } from "react";
import { ClipPlayer } from "../components/ClipPlayer";
import { Compare } from "../components/Compare";
import { FindingCard } from "../components/FindingCard";
import { ArrowUpRightIcon, ChevronLeftIcon, ChevronRightIcon } from "../components/Icons";
import { KindTag } from "../components/KindTag";
import { Thumb } from "../components/Thumb";
import { Segmented } from "../components/Segmented";
import { SeverityChip } from "../components/Severity";
import { Stage, ZOOMS, type Zoom } from "../components/Stage";
import { StateTabs } from "../components/StateTabs";
import { asset, baseStateFor, bySeverity, pickVariant, plural, severityCounts, sourceUrl } from "../data";
import { Link, navigate, useLocation } from "../router";
import { scrollToElement } from "../scroll";
import { useTheme } from "../theme";
import type { Component, Gallery, Scheme, State } from "../types";
import { SEVERITIES } from "../types";
import { NotFound } from "./NotFound";

const isEditable = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT", "VIDEO"].includes(target.tagName) || target.getAttribute("role") === "slider");

export function areaAnchor(area: string) {
  return "area-" + area.toLowerCase().replace(/\s+/g, "-");
}

export function ComponentPage({ gallery, id }: { gallery: Gallery; id: string }) {
  const component = gallery.components.find((c) => c.id === id);
  if (!component) return <NotFound what="component" />;
  return <ComponentView key={component.id} gallery={gallery} component={component} />;
}

function ComponentView({ gallery, component }: { gallery: Gallery; component: Component }) {
  const { pathname, search, hash } = useLocation();
  const theme = useTheme();
  const [instant, setInstant] = useState(false);
  const stageRef = useRef<HTMLDivElement>(null);

  const states = component.states;
  const state = states.find((s) => s.id === search.get("s")) ?? states[0];
  const schemeParam = search.get("scheme");
  const scheme: Scheme = schemeParam === "light" || schemeParam === "dark" ? schemeParam : theme.resolved;
  const reduceMotion = search.get("rm") === "1";
  const zoomParam = search.get("zoom") as Zoom | null;
  const zoom: Zoom = zoomParam && ZOOMS.includes(zoomParam) ? zoomParam : "fit";

  const findings = useMemo(() => gallery.findings.filter((f) => f.component === component.id).sort(bySeverity), [gallery, component]);
  const counts = severityCounts(findings);
  const index = gallery.components.indexOf(component);
  const previous = gallery.components[index - 1];
  const next = gallery.components[index + 1];

  function update(params: Record<string, string | null>) {
    const query = new URLSearchParams(search);
    for (const [key, value] of Object.entries(params)) {
      if (value === null) query.delete(key);
      else query.set(key, value);
    }
    const qs = query.toString();
    navigate(pathname + (qs ? "?" + qs : "") + (hash ? "#" + hash : ""), { replace: true });
  }

  function selectState(next: State | undefined, viaKeyboard = false) {
    if (!next) return;
    setInstant(viaKeyboard);
    update({ s: next.id === states[0]?.id ? null : next.id });
  }

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || isEditable(event.target)) return;
      if (document.querySelector("dialog[open]")) return;
      const current = states.indexOf(state);
      const target = states[current + (event.key === "ArrowRight" ? 1 : -1)];
      if (!target) return;
      event.preventDefault();
      selectState(target, true);
      if ((event.target as HTMLElement | null)?.getAttribute("role") === "tab")
        requestAnimationFrame(() => document.getElementById("tab-" + target.id)?.focus());
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  useEffect(() => {
    if (!hash) return;
    const element = document.getElementById(hash);
    if (element) requestAnimationFrame(() => scrollToElement(element));
  }, [hash]);

  useEffect(() => {
    const neighbours = [states[states.indexOf(state) - 1], states[states.indexOf(state) + 1], state];
    for (const s of neighbours) {
      if (!s) continue;
      for (const v of s.variants) if (v.scheme === scheme) new Image().src = asset(v.image);
    }
  }, [state, states, scheme]);

  if (!state) return <NotFound what="state" />;

  const { variant, exact } = pickVariant(state, scheme, reduceMotion);
  const clips = (state.clips ?? []).filter((c) => c.scheme === scheme && c.reduceMotion === reduceMotion);
  const otherClips = (state.clips ?? []).length - clips.length;

  const proposed = states.filter((s) => s.kind === "proposed");
  const pairProposed = state.kind === "proposed" ? state : proposed.find((p) => baseStateFor(component, p) === state) ?? proposed[0];
  const pairBase = pairProposed && baseStateFor(component, pairProposed);
  const beforeVariant = pairBase && pickVariant(pairBase, scheme, reduceMotion).variant;
  const afterVariant = pairProposed && pickVariant(pairProposed, scheme, reduceMotion).variant;

  const kindNote = (s: State) => (s.superseded ? " (superseded proposal)" : s.kind === "proposed" ? " (proposed)" : "");
  const describe = (s: State) => component.title + ", " + s.title + kindNote(s) + ", " + scheme + " appearance" + (reduceMotion ? ", Reduce Motion on" : "");

  function showState(id: string) {
    const target = states.find((s) => s.id === id);
    selectState(target);
    if (stageRef.current && stageRef.current.getBoundingClientRect().top < 0) scrollToElement(stageRef.current, { smooth: true });
  }

  return (
    <article className="cpage page">
      <header className="cpage-head">
        <Link className="crumb" href={"/#" + areaAnchor(component.area)}>
          {component.area}
        </Link>
        <h1 className="title-1">{component.title}</h1>
        <p className="lede">{component.summary}</p>
        <div className="meta-row">
          {component.owner && <span className="owner">Redesign owned by {component.owner}</span>}
          <span className="meta num">{plural(states.length, "state")}</span>
          {SEVERITIES.filter((s) => counts[s] > 0).map((s) => (
            <span key={s} className="meta-sev">
              <SeverityChip severity={s} /> <span className="num">{counts[s]}</span>
            </span>
          ))}
        </div>
        <ul className="sources" aria-label="Source">
          {component.sources.map((source) => (
            <li key={source}>
              <a href={sourceUrl(source)} target="_blank" rel="noreferrer">
                <code>{source}</code>
                <ArrowUpRightIcon size={12} />
              </a>
            </li>
          ))}
        </ul>
      </header>

      <div className="cpage-grid">
        <div className="cpage-main">
          <div ref={stageRef} className="stage-block">
            <StateTabs states={states} selected={state.id} instant={instant} onSelect={(sid) => selectState(states.find((s) => s.id === sid))} />
            <div className="toolbar">
              <Segmented
                id="scheme"
                label="Appearance"
                value={scheme}
                onChange={(value) => update({ scheme: value })}
                options={[
                  { value: "light", label: "Light" },
                  { value: "dark", label: "Dark" },
                ]}
              />
              <Segmented
                id="motion"
                label="Reduce Motion"
                value={reduceMotion ? "on" : "off"}
                onChange={(value) => update({ rm: value === "on" ? "1" : null })}
                options={[
                  { value: "off", label: "Motion" },
                  { value: "on", label: "Reduced" },
                ]}
              />
              <Segmented
                id="zoom"
                label="Zoom"
                value={zoom}
                onChange={(value) => update({ zoom: value === "fit" ? null : value })}
                options={[
                  { value: "fit", label: "Fit" },
                  { value: "1x", label: "1×", title: "Actual size" },
                  { value: "2x", label: "2×", title: "Double size" },
                ]}
              />
            </div>
            <div id="stage-panel" role="tabpanel" aria-labelledby={"tab-" + state.id}>
              {state.superseded && <p className="note stage-notice">{state.superseded}</p>}
              {variant ? (
                <Stage picture={variant} alt={describe(state)} zoom={zoom} scheme={scheme} />
              ) : (
                <div className="stage stage-empty">No render for this state yet.</div>
              )}
              <p className="stage-caption num">
                <span>{state.title}</span>
                <span>{variant?.scheme === "light" ? "Light" : "Dark"}</span>
                <span>{variant?.reduceMotion ? "Reduce Motion on" : "Reduce Motion off"}</span>
                {variant && (
                  <span>
                    {variant.width}×{variant.height} @{variant.scale}x
                  </span>
                )}
              </p>
              {!exact && variant && (
                <p className="note" data-tone="warn">
                  No {reduceMotion ? "Reduce Motion" : "standard"} {scheme} render for this state, so this shows the {variant.reduceMotion ? "Reduce Motion" : "standard"} {variant.scheme} one.
                </p>
              )}
              {state.note && <p className="note">{state.note}</p>}
            </div>
          </div>

          {(clips.length > 0 || otherClips > 0) && (
            <section className="section" aria-labelledby="motion-heading">
              <h2 id="motion-heading" className="title-3">
                Motion
              </h2>
              {clips.map((clip, i) => (
                <ClipPlayer key={clip.video} clip={clip} id={state.id + i} />
              ))}
              {clips.length === 0 && (
                <p className="muted">
                  {plural(otherClips, "clip")} for this state in another appearance or motion setting.
                </p>
              )}
            </section>
          )}

          {pairProposed && pairBase && beforeVariant && afterVariant && (
            <section className="section" aria-labelledby="compare-heading">
              <h2 id="compare-heading" className="title-3">
                {pairProposed.superseded ? "Current and superseded proposal" : "Current and proposed"}
              </h2>
              <Compare
                id={pairProposed.id}
                scheme={scheme}
                before={{ picture: beforeVariant, label: pairBase.title, alt: describe(pairBase) }}
                after={{ picture: afterVariant, label: pairProposed.title + kindNote(pairProposed), alt: describe(pairProposed), superseded: Boolean(pairProposed.superseded) }}
              />
            </section>
          )}

          <section className="section" aria-labelledby="sheet-heading">
            <h2 id="sheet-heading" className="title-3">
              All states
            </h2>
            <ul className="sheet">
              {states.map((s) => {
                const v = pickVariant(s, scheme, reduceMotion).variant;
                return (
                  <li key={s.id}>
                    <button type="button" className="sheet-card" aria-current={s.id === state.id} onClick={() => showState(s.id)}>
                      <Thumb picture={v} scheme={scheme} backdrop={v?.backdrop} />
                      <span className="sheet-title">
                        {s.title}
                        <KindTag item={s} />
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          </section>
        </div>

        <aside className="cpage-aside" aria-labelledby="findings-heading" data-lenis-prevent>
          <h2 id="findings-heading" className="title-3">
            Findings <span className="count num">{findings.length}</span>
          </h2>
          {findings.length === 0 ? (
            <p className="muted">No findings for this component.</p>
          ) : (
            <div className="findings">
              {findings.map((finding) => {
                const target = states.find((s) => s.id === finding.proposedState);
                return (
                  <FindingCard
                    key={finding.id}
                    finding={finding}
                    active={hash === finding.id}
                    onShowProposed={target ? () => showState(target.id) : undefined}
                    proposalSuperseded={Boolean(target?.superseded)}
                  />
                );
              })}
            </div>
          )}
        </aside>
      </div>

      <nav className="pager" aria-label="More components">
        {previous ? (
          <Link className="pager-link" href={"/c/" + previous.id}>
            <ChevronLeftIcon />
            <span>
              <span className="pager-dir">Previous</span>
              <span className="pager-title">{previous.title}</span>
            </span>
          </Link>
        ) : (
          <span />
        )}
        {next && (
          <Link className="pager-link" data-dir="next" href={"/c/" + next.id}>
            <span>
              <span className="pager-dir">Next</span>
              <span className="pager-title">{next.title}</span>
            </span>
            <ChevronRightIcon />
          </Link>
        )}
      </nav>
    </article>
  );
}
