import { motion } from "motion/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowUpRightIcon, ChevronLeftIcon, ChevronRightIcon, MoonIcon, SunIcon } from "../components/Icons";
import { Segmented } from "../components/Segmented";
import { Link, navigate, useLocation } from "../router";
import { setTheme, useTheme } from "../theme";
import type { Direction, Gallery, Redesign, RedesignComponent, Scheme } from "../types";
import { ClipView, Transport } from "./Clip";
import { useClock, type SyncClock } from "./clock";
import { PickControl, PicksButton } from "./Picks";
import {
  currentMedia,
  currentOptions,
  directionMedia,
  FLOW,
  pickMedia,
  setReduceMotion,
  stateIds,
  updatePick,
  useReduceMotion,
  usePicks,
  type Choice,
  type CurrentOption,
} from "./state";

const typing = (target: EventTarget | null) =>
  target instanceof HTMLElement && (/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable);

export function RedesignComponentPage({ gallery, data, component, openPicks }: { gallery: Gallery; data: Redesign; component: RedesignComponent; openPicks: () => void }) {
  const { search } = useLocation();
  const { resolved: scheme } = useTheme();
  const rm = useReduceMotion();
  const picks = usePicks();
  const pick = picks[component.id]?.choice;
  const clock = useClock({ autoplay: true });
  const states = useMemo(() => stateIds(component), [component]);
  const hasFlow = component.directions.some((d) => d.flow);
  const stops = useMemo(() => [...states.map((s) => s.id), ...(hasFlow ? [FLOW] : [])], [states, hasFlow]);
  const requested = search.get("s");
  const active = requested && stops.includes(requested) ? requested : stops[0] ?? FLOW;
  const options = useMemo(() => currentOptions(gallery, component), [gallery, component]);
  const matched = options.find((o) => o.state.id === active);
  const [chosenCurrent, setChosenCurrent] = useState(0);
  const current: CurrentOption | undefined = matched ?? options[chosenCurrent] ?? options[0];
  const columns = 1 + component.directions.length;
  const [focused, setFocused] = useState(() => Math.min(columns - 1, Math.max(0, Number(search.get("v") ?? 1) - 1)));
  const track = useRef<HTMLDivElement>(null);

  const first = component.directions.map((d) => pickMedia(directionMedia(d, active), scheme, rm)).find(Boolean)?.media;
  const ratio = first ? first.width / first.height : 16 / 10;
  const order = data.components;
  const index = order.findIndex((c) => c.id === component.id);
  const previous = order[index - 1];
  const next = order[index + 1];

  function select(stop: string, { restart = false } = {}) {
    const params = new URLSearchParams(search);
    params.set("s", stop);
    navigate("?" + params.toString(), { replace: true });
    if (restart) clock.restart();
    else clock.seek(0);
  }

  function focusColumn(column: number, { scroll = true } = {}) {
    setFocused(column);
    const params = new URLSearchParams(location.search);
    params.set("v", String(column + 1));
    navigate("?" + params.toString(), { replace: true });
    const card = track.current?.children[column] as HTMLElement | undefined;
    if (scroll && card && track.current && track.current.scrollWidth > track.current.clientWidth + 1) {
      const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
      track.current.scrollTo({ left: card.offsetLeft - track.current.offsetLeft - parseFloat(getComputedStyle(track.current).scrollPaddingLeft || "0"), behavior: reduce ? "auto" : "smooth" });
    }
  }

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.metaKey || event.ctrlKey || event.altKey || typing(event.target)) return;
      const at = stops.indexOf(active);
      if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
        if (stops.length < 2) return;
        event.preventDefault();
        select(stops[(at + (event.key === "ArrowRight" ? 1 : -1) + stops.length) % stops.length]);
      } else if (event.key === " " || event.key === "k") {
        if (event.target instanceof HTMLButtonElement || event.target instanceof HTMLAnchorElement) return;
        event.preventDefault();
        clock.toggle();
      } else if (event.key === "," || event.key === ".") {
        clock.step(event.key === "," ? -1 : 1);
      } else if (/^[1-9]$/.test(event.key) && Number(event.key) <= columns) {
        focusColumn(Number(event.key) - 1);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  useEffect(() => {
    const el = track.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (el.scrollWidth <= el.clientWidth + 1) return;
        const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        if (visible) setFocused([...el.children].indexOf(visible.target));
      },
      { root: el, threshold: [0.6] },
    );
    [...el.children].forEach((child) => observer.observe(child));
    if (focused > 0) focusColumn(focused);
    return () => observer.disconnect();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const columnLabels = [{ value: "0", label: "Now" }, ...component.directions.map((d, i) => ({ value: String(i + 1), label: d.id + " " + d.name }))];

  return (
    <div className="page rd-cpage">
      <header className="rd-chead">
        <Link className="crumb" href="/redesign">
          <ChevronLeftIcon size={14} /> Redesign · Batch {component.batch}
        </Link>
        <h1 className="title-1">{component.title}</h1>
        <p className="lede">{component.summary}</p>
      </header>

      <div className="rd-toolbar">
        <div className="rd-stepper">
          <button type="button" className="rd-tbutton" aria-label="Previous state" disabled={stops.length < 2} onClick={() => select(stops[(stops.indexOf(active) - 1 + stops.length) % stops.length])}>
            <ChevronLeftIcon />
          </button>
          <div className="rd-chips" role="tablist" aria-label="States" data-lenis-prevent>
            {states.map((state) => (
              <Chip key={state.id} active={state.id === active} onClick={() => select(state.id)}>
                {state.title}
              </Chip>
            ))}
          </div>
          <button type="button" className="rd-tbutton" aria-label="Next state" disabled={stops.length < 2} onClick={() => select(stops[(stops.indexOf(active) + 1) % stops.length])}>
            <ChevronRightIcon />
          </button>
        </div>
        {hasFlow && (
          <button type="button" className="rd-flow" aria-pressed={active === FLOW} onClick={() => select(FLOW, { restart: true })}>
            {active === FLOW && <motion.span className="rd-flow-pill" layoutId="rd-state-pill" transition={{ type: "spring", bounce: 0, duration: 0.28 }} />}
            <span>Play the flow</span>
          </button>
        )}
        <div className="rd-toggles">
          <Segmented<Scheme>
            id="rd-scheme"
            label="Appearance"
            size="sm"
            value={scheme}
            onChange={setTheme}
            options={[
              { value: "dark", label: <MoonIcon size={14} />, title: "Dark" },
              { value: "light", label: <SunIcon size={14} />, title: "Light" },
            ]}
          />
          <button type="button" className="rd-switch" role="switch" aria-checked={rm} onClick={() => setReduceMotion(!rm)}>
            <span className="rd-switch-track" aria-hidden="true" />
            Reduce Motion
          </button>
        </div>
      </div>

      <div className="rd-colseg">
        <Segmented id="rd-columns" label="Direction" value={String(focused)} onChange={(v) => focusColumn(Number(v))} options={columnLabels.map((o) => ({ value: o.value, label: o.label.split(" ")[0], title: o.label }))} />
      </div>

      <div ref={track} className="rd-grid" data-columns={columns} data-wide={ratio > 1.7 || undefined} data-lenis-prevent>
        <article className="rd-col" data-focused={focused === 0 || undefined} aria-label="Current design">
          <ClipView resolved={current && currentMedia(current, scheme, rm)} clock={clock} label={"Current, " + (current?.state.title ?? "not in the gallery")} scheme={scheme} ratio={ratio} priority />
          {!matched && options.length > 1 && (
            <div className="rd-current-states" role="group" aria-label="Today’s states">
              {options.map((option, i) => (
                <button key={option.component.id + "/" + option.state.id} type="button" className="rd-mini-chip" aria-pressed={current === option} onClick={() => setChosenCurrent(i)}>
                  {component.current.componentIds.length > 1 ? option.component.title + " · " : ""}
                  {option.state.title}
                </button>
              ))}
            </div>
          )}
          <div className="rd-col-head">
            <span className="rd-letter" data-current>
              Now
            </span>
            <h2 className="title-3">Current</h2>
            <PickButton component={component} choice="current" picked={pick === "current"} />
          </div>
          <p className="rd-axis">
            {options.length > 0 ? "Today’s " + [...new Set(options.map((o) => o.component.title))].join(" and ") : "Not in today’s gallery"}
            {matched ? "" : options.length > 0 && active !== FLOW ? " · no matching state, showing " + (current?.state.title ?? "") : ""}
          </p>
          {component.current.note && <p className="rd-text">{component.current.note}</p>}
          {current && (
            <Link className="text-button" href={"/c/" + current.component.id + "?s=" + current.state.id}>
              Open in the gallery <ArrowUpRightIcon size={12} />
            </Link>
          )}
        </article>
        {component.directions.map((direction, i) => (
          <DirectionCard
            key={direction.id}
            component={component}
            direction={direction}
            active={active}
            clock={clock}
            scheme={scheme}
            rm={rm}
            ratio={ratio}
            focused={focused === i + 1}
            picked={pick === direction.id}
          />
        ))}
      </div>

      <PickControl component={component} />

      <nav className="pager" aria-label="More redesigned components">
        {previous ? (
          <Link className="pager-link" href={"/redesign/" + previous.id}>
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
          <Link className="pager-link" data-dir="next" href={"/redesign/" + next.id}>
            <span>
              <span className="pager-dir">Next</span>
              <span className="pager-title">{next.title}</span>
            </span>
            <ChevronRightIcon />
          </Link>
        )}
      </nav>

      <p className="rd-keys muted" aria-hidden="true">
        <kbd>←</kbd> <kbd>→</kbd> states · <kbd>Space</kbd> play · <kbd>,</kbd> <kbd>.</kbd> frame · <kbd>1</kbd>–<kbd>{columns}</kbd> direction
      </p>

      <div className="rd-dock" role="region" aria-label="Playback">
        <Transport clock={clock} variant="dock">
          <PicksButton components={data.components} onOpen={openPicks} compact />
        </Transport>
      </div>
    </div>
  );
}

function Chip({ active, onClick, children }: { active: boolean; onClick: () => void; children: string }) {
  return (
    <button type="button" role="tab" aria-selected={active} tabIndex={active ? 0 : -1} className="rd-chip" onClick={onClick}>
      {active && <motion.span className="rd-chip-pill" layoutId="rd-state-pill" transition={{ type: "spring", bounce: 0, duration: 0.28 }} />}
      <span className="rd-chip-label">{children}</span>
    </button>
  );
}

function PickButton({ component, choice, picked }: { component: RedesignComponent; choice: Choice; picked: boolean }) {
  return (
    <button type="button" className="rd-pick-button" aria-pressed={picked} onClick={() => updatePick(component.id, { choice: picked ? undefined : choice })}>
      {picked ? "Picked" : choice === "current" ? "Keep" : "Pick " + choice}
    </button>
  );
}

function DirectionCard({
  component,
  direction,
  active,
  clock,
  scheme,
  rm,
  ratio,
  focused,
  picked,
}: {
  component: RedesignComponent;
  direction: Direction;
  active: string;
  clock: SyncClock;
  scheme: Scheme;
  rm: boolean;
  ratio: number;
  focused: boolean;
  picked: boolean;
}) {
  const state = direction.states.find((s) => s.id === active);
  const resolved = pickMedia(directionMedia(direction, active), scheme, rm);
  return (
    <article className="rd-col" data-focused={focused || undefined} data-picked={picked || undefined} aria-label={"Direction " + direction.id + ", " + direction.name}>
      <ClipView resolved={resolved} clock={clock} label={direction.name + ", " + (active === FLOW ? "full flow" : state?.title ?? active)} scheme={scheme} ratio={ratio} priority />
      {active === FLOW && !direction.flow && <p className="rd-caption">No flow clip for this direction.</p>}
      {state?.caption && active !== FLOW && <p className="rd-caption">{state.caption}</p>}
      <div className="rd-col-head">
        <span className="rd-letter">{direction.id}</span>
        <h2 className="title-3">{direction.name}</h2>
        <PickButton component={component} choice={direction.id} picked={picked} />
      </div>
      <p className="rd-axis">{direction.axis}</p>
      <dl className="rd-facts">
        <div>
          <dt>Wins when</dt>
          <dd>{direction.pitch}</dd>
        </div>
        <div>
          <dt>Costs</dt>
          <dd>{direction.cost}</dd>
        </div>
      </dl>
      {direction.perf ? (
        <div className="rd-perf">
          <dl className="rd-perf-grid num">
            <div>
              <dt>CPU</dt>
              <dd>{direction.perf.cpu}</dd>
            </div>
            <div>
              <dt>GPU</dt>
              <dd>{direction.perf.gpu}</dd>
            </div>
            <div>
              <dt>Idle</dt>
              <dd>{direction.perf.idle}</dd>
            </div>
          </dl>
          {direction.perf.note && <p className="rd-perf-note">{direction.perf.note}</p>}
        </div>
      ) : (
        <p className="rd-perf-note">Not measured yet.</p>
      )}
      <details className="rd-more">
        <summary>
          Libraries and skills <span className="num">({direction.libraries.length + direction.skills.length})</span>
        </summary>
        {direction.libraries.length > 0 && (
          <ul className="rd-libs">
            {direction.libraries.map((library) => (
              <li key={library.name}>
                <a href={library.url} target="_blank" rel="noreferrer">
                  {library.name}
                </a>{" "}
                <span className="num">{library.version}</span> · {library.license}
                <span className="rd-lib-role">{library.role}</span>
              </li>
            ))}
          </ul>
        )}
        {direction.custom && (
          <p className="rd-text">
            <b>Custom:</b> {direction.custom}
          </p>
        )}
        {direction.skills.length > 0 && (
          <ul className="rd-skills">
            {direction.skills.map((s) => (
              <li key={s.skill}>
                <code>{s.skill}</code> {s.change}
              </li>
            ))}
          </ul>
        )}
      </details>
    </article>
  );
}
