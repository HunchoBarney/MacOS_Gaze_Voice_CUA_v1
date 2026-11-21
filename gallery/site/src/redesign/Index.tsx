import { asset, plural } from "../data";
import { Link } from "../router";
import { useTheme } from "../theme";
import type { Gallery, Redesign, RedesignComponent, Scheme } from "../types";
import { BATCHES, choiceLabel, pickMedia, useReduceMotion, usePicks } from "./state";

function Poster({ component, scheme, rm }: { component: RedesignComponent; scheme: Scheme; rm: boolean }) {
  return (
    <span className="rd-tiles" data-n={component.directions.length}>
      {component.directions.map((direction) => {
        const media = pickMedia(direction.states[0]?.media ?? direction.flow, scheme, rm)?.media;
        const src = media?.kind === "still" ? media.src : media?.poster;
        return (
          <span key={direction.id} className="rd-tile" data-scheme={scheme}>
            {src && <img src={asset(src)} alt="" loading="lazy" decoding="async" />}
            <span className="rd-tile-tag">
              <b>{direction.id}</b> {direction.name}
            </span>
          </span>
        );
      })}
    </span>
  );
}

export function RedesignIndex({ gallery, data, openPicks }: { gallery: Gallery; data: Redesign; openPicks: () => void }) {
  const { resolved } = useTheme();
  const rm = useReduceMotion();
  const picks = usePicks();
  const done = data.components.filter((c) => picks[c.id]?.choice).length;
  const directions = data.components.reduce((sum, c) => sum + c.directions.length, 0);

  return (
    <div className="page rd-index">
      <header className="rd-head">
        <p className="eyebrow">Redesign</p>
        <h1 className="title-1">Pick the next Jarvis.</h1>
        <p className="lede">
          Every visible surface, redesigned in two or three genuinely different directions and rendered from the real SwiftUI views at 60 fps. Watch each one beside today’s design, then pick one per
          component. Picks stay in this browser until you copy them.
        </p>
        {data.components.length > 0 && (
          <div className="rd-head-actions">
            <button type="button" className="rd-button rd-button-primary" onClick={openPicks}>
              Your picks · <span className="num">{done}/{data.components.length}</span>
            </button>
            <span className="muted num">
              {plural(data.components.length, "component")} · {plural(directions, "direction")} · {plural(data.scenes.length, "scene")}
            </span>
          </div>
        )}
      </header>

      {BATCHES.map((batch) => {
        const components = data.components.filter((c) => c.batch === batch.n);
        return (
          <section key={batch.n} className="rd-batch" aria-labelledby={"batch-" + batch.n} data-coming={components.length === 0 || undefined}>
            <div className="area-head">
              <h2 id={"batch-" + batch.n} className="title-2">
                <span className="rd-batch-n num">Batch {batch.n}</span> {batch.title}
              </h2>
              {components.length === 0 && <span className="rd-coming">Coming</span>}
            </div>
            {components.length === 0 ? (
              <ul className="rd-coming-list">
                {batch.expected.map((name) => (
                  <li key={name}>{name}</li>
                ))}
              </ul>
            ) : (
              <ul className="rd-cards">
                {components.map((component) => {
                  const pick = picks[component.id];
                  const today = component.current.componentIds.filter((id) => gallery.components.some((c) => c.id === id)).length;
                  return (
                    <li key={component.id}>
                      <Link className="card rd-card" href={"/redesign/" + component.id}>
                        <Poster component={component} scheme={resolved} rm={rm} />
                        <span className="card-text">
                          <span className="card-title">
                            {component.title}
                            {pick?.choice && <span className="rd-picked">{choiceLabel(component, pick.choice)}</span>}
                          </span>
                          <span className="rd-card-summary">{component.summary}</span>
                          <span className="card-meta num">
                            {component.directions.map((d) => d.name).join(" · ")}
                            {today === 0 && " · not in today’s gallery"}
                          </span>
                        </span>
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </section>
        );
      })}

      {data.scenes.length > 0 && (
        <section className="rd-batch" aria-labelledby="rd-scenes">
          <div className="area-head">
            <h2 id="rd-scenes" className="title-2">
              Scenes
            </h2>
            <Link className="text-button" href="/redesign/scenes">
              Watch all
            </Link>
          </div>
          <ul className="rd-cards">
            {data.scenes.map((scene) => {
              const media = pickMedia(scene.media, resolved, rm)?.media;
              const src = media?.kind === "still" ? media.src : media?.poster;
              return (
                <li key={scene.id}>
                  <Link className="card rd-card" href={"/redesign/scenes#" + scene.id}>
                    <span className="rd-tiles" data-n={1}>
                      <span className="rd-tile" data-scheme={resolved}>
                        {src && <img src={asset(src)} alt="" loading="lazy" decoding="async" />}
                      </span>
                    </span>
                    <span className="card-text">
                      <span className="card-title">{scene.title}</span>
                      <span className="rd-card-summary">{scene.caption}</span>
                    </span>
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {data.components.length === 0 && (
        <p className="muted rd-empty">No redesign renders yet. When the producers write manifest.redesign.*.json into the renders folder, run the collect step and they show up here.</p>
      )}
    </div>
  );
}
