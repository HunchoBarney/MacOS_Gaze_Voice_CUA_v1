import NumberFlow from "@number-flow/react";
import { lazy, Suspense, useState, type CSSProperties } from "react";
import { KindTag } from "../components/KindTag";
import { Thumb } from "../components/Thumb";
import { SeverityChip, severityName } from "../components/Severity";
import { coverVariant, plural, sceneVariant, severityCounts } from "../data";
import { Link } from "../router";
import { useTheme } from "../theme";
import type { Gallery } from "../types";
import { AREAS, SEVERITIES } from "../types";
import { areaAnchor } from "./ComponentPage";

const HeroShader = lazy(() => import("../components/HeroShader"));
let entrancePlayed = false;

export function Home({ gallery }: { gallery: Gallery }) {
  const { resolved } = useTheme();
  const [enter] = useState(() => {
    const first = !entrancePlayed;
    entrancePlayed = true;
    return first;
  });
  const counts = severityCounts(gallery.findings);
  const stateCount = gallery.components.reduce((sum, c) => sum + c.states.length, 0);
  const areas = AREAS.map((area) => ({ area, components: gallery.components.filter((c) => c.area === area) })).filter((a) => a.components.length > 0);

  return (
    <div className="home">
      <section className="hero" aria-labelledby="hero-title" data-enter={enter || undefined}>
        <Suspense fallback={null}>
          <HeroShader />
        </Suspense>
        <div className="hero-inner page">
          <p className="eyebrow enter" style={{ "--delay": "0ms" } as CSSProperties}>
            Jarvis UI gallery
          </p>
          <h1 id="hero-title" className="display enter" style={{ "--delay": "40ms" } as CSSProperties}>
            Every surface Jarvis shows, in every state.
          </h1>
          <p className="hero-lede enter" style={{ "--delay": "90ms" } as CSSProperties}>
            Rendered offscreen from the app’s own views and the eye tracker, in light and dark, with Reduce Motion on and off. Each audit finding sits beside the component it’s about.
          </p>
          <dl className="stats enter" style={{ "--delay": "130ms" } as CSSProperties}>
            <div className="stat">
              <dt>Components</dt>
              <dd className="num">
                <NumberFlow value={gallery.components.length} />
              </dd>
            </div>
            <div className="stat">
              <dt>States</dt>
              <dd className="num">
                <NumberFlow value={stateCount} />
              </dd>
            </div>
            <div className="stat">
              <dt>Scenes</dt>
              <dd className="num">
                <NumberFlow value={gallery.scenes.length} />
              </dd>
            </div>
            <div className="stat stat-findings">
              <dt>
                <Link href="/audit">Findings</Link>
              </dt>
              <dd>
                {SEVERITIES.map((s) => (
                  <Link key={s} className="stat-sev" href={"/audit?sev=" + s} aria-label={counts[s] + " " + severityName(s).toLowerCase() + " findings"}>
                    <SeverityChip severity={s} />
                    <span className="num">
                      <NumberFlow value={counts[s]} />
                    </span>
                  </Link>
                ))}
              </dd>
            </div>
          </dl>
        </div>
      </section>

      <div className="page home-body">
        {gallery.scenes.length > 0 && (
          <section className="area" aria-labelledby="scenes-heading">
            <div className="area-head">
              <h2 id="scenes-heading" className="title-2">
                Scenes
              </h2>
              <Link className="text-button" href="/scenes">
                All scenes
              </Link>
            </div>
            <ul className="strip" data-lenis-prevent>
              {gallery.scenes.map((scene) => (
                <li key={scene.id}>
                  <Link className="card scene-card" href={"/scenes/" + scene.id}>
                    <Thumb picture={sceneVariant(scene, resolved)} scheme={resolved} backdrop="desktop" cover />
                    <span className="card-text">
                      <span className="card-title">
                        {scene.title}
                        <KindTag item={scene} />
                      </span>
                      <span className="card-meta">{plural(scene.components.length, "component")}</span>
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        )}

        <div className="areas">
        {areas.map(({ area, components }) => (
          <section key={area} id={areaAnchor(area)} className="area" data-n={Math.min(components.length, 4)} aria-labelledby={areaAnchor(area) + "-h"}>
            <div className="area-head">
              <h2 id={areaAnchor(area) + "-h"} className="title-2">
                {area}
              </h2>
              <span className="area-count num">{components.length}</span>
            </div>
            <ul className="grid">
              {components.map((component) => {
                const cover = coverVariant(component, resolved);
                const findings = gallery.findings.filter((f) => f.component === component.id);
                const c = severityCounts(findings);
                const clips = component.states.reduce((sum, s) => sum + (s.clips?.length ?? 0), 0);
                return (
                  <li key={component.id}>
                    <Link className="card" href={"/c/" + component.id}>
                      <Thumb picture={cover} scheme={resolved} backdrop={cover?.backdrop} />
                      <span className="card-text">
                        <span className="card-title">{component.title}</span>
                        <span className="card-meta num">
                          {plural(component.states.length, "state")}
                          {clips > 0 && " · " + plural(clips, "clip")}
                        </span>
                        {findings.length > 0 && (
                          <span className="card-sevs">
                            {SEVERITIES.filter((s) => c[s] > 0).map((s) => (
                              <span key={s} className="card-sev">
                                <SeverityChip severity={s} />
                                <span className="num">{c[s]}</span>
                              </span>
                            ))}
                          </span>
                        )}
                      </span>
                    </Link>
                  </li>
                );
              })}
            </ul>
          </section>
        ))}
        </div>

        {gallery.components.length === 0 && (
          <p className="muted">No renders yet. Run the collect step with a renders directory to fill the gallery.</p>
        )}
      </div>
    </div>
  );
}
