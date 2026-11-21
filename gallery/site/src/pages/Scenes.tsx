import { useState } from "react";
import { ClipPlayer } from "../components/ClipPlayer";
import { Compare } from "../components/Compare";
import { Segmented } from "../components/Segmented";
import { Stage, type Zoom } from "../components/Stage";
import { Thumb } from "../components/Thumb";
import { plural, sceneVariant } from "../data";
import { Link, navigate, useLocation } from "../router";
import { useTheme } from "../theme";
import type { Gallery, Scheme } from "../types";
import { NotFound } from "./NotFound";

export function Scenes({ gallery }: { gallery: Gallery }) {
  const { resolved } = useTheme();
  return (
    <div className="page">
      <header className="page-head">
        <h1 className="title-1">Scenes</h1>
        <p className="lede">Components together on a fixture macOS desktop, the way a person meets them.</p>
      </header>
      {gallery.scenes.length === 0 ? (
        <p className="muted">No scenes rendered yet.</p>
      ) : (
        <ul className="grid grid-scenes">
          {gallery.scenes.map((scene) => (
            <li key={scene.id}>
              <Link className="card scene-card" href={"/scenes/" + scene.id}>
                <Thumb picture={sceneVariant(scene, resolved)} scheme={resolved} backdrop="desktop" cover />
                <span className="card-text">
                  <span className="card-title">
                    {scene.title}
                    {scene.kind === "proposed" && (
                      <span className="kind-tag" data-kind="proposed">
                        Proposed
                      </span>
                    )}
                  </span>
                  <span className="card-meta">{scene.summary}</span>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function ScenePage({ gallery, id }: { gallery: Gallery; id: string }) {
  const [zoom, setZoom] = useState<Zoom>("fit");
  const { pathname, search } = useLocation();
  const { resolved } = useTheme();
  const scene = gallery.scenes.find((s) => s.id === id);
  if (!scene) return <NotFound what="scene" />;

  const schemes = (scene.variants ?? []).map((v) => v.scheme);
  const param = search.get("scheme");
  const variant = sceneVariant(scene, param === "light" || param === "dark" ? param : resolved);
  const scheme = variant.scheme;
  const picture = { image: variant.image, width: variant.width, height: variant.height, scale: 2, backdrop: "desktop" as const };

  const proposed = scene.kind !== "proposed" ? gallery.scenes.find((s) => s.id === scene.id + "-proposed") : undefined;
  const current = scene.kind === "proposed" ? gallery.scenes.find((s) => s.id === scene.id.replace(/-proposed$/, "")) : undefined;
  const pair = proposed ? [scene, proposed] : current ? [current, scene] : undefined;
  const pairScheme: Scheme | undefined = pair && sceneVariant(pair[1], scheme).scheme;
  const sides = pair && pairScheme ? pair.map((s) => sceneVariant(s, pairScheme)) : undefined;

  return (
    <article className="page">
      <header className="cpage-head">
        <Link className="crumb" href="/scenes">
          Scenes
        </Link>
        <h1 className="title-1">{scene.title}</h1>
        <p className="lede">{scene.summary}</p>
        <ul className="chips" aria-label="Components in this scene">
          {scene.components.map((cid) => {
            const component = gallery.components.find((c) => c.id === cid);
            return (
              <li key={cid}>
                <Link className="chip" href={"/c/" + cid}>
                  {component?.title ?? cid}
                </Link>
              </li>
            );
          })}
        </ul>
      </header>
      <div className="toolbar">
        {schemes.length > 1 && (
          <Segmented
            id="scene-scheme"
            label="Appearance"
            value={scheme}
            onChange={(value) => navigate(pathname + "?scheme=" + value, { replace: true })}
            options={[
              { value: "light", label: "Light" },
              { value: "dark", label: "Dark" },
            ]}
          />
        )}
        <Segmented
          id="scene-zoom"
          label="Zoom"
          value={zoom}
          onChange={setZoom}
          options={[
            { value: "fit", label: "Fit" },
            { value: "1x", label: "1×", title: "Actual size" },
            { value: "2x", label: "2×", title: "Double size" },
          ]}
        />
      </div>
      <Stage picture={picture} alt={scene.title + ": " + scene.summary} zoom={zoom} scheme={scheme} />
      <p className="stage-caption num">
        {schemes.length > 0 && <span>{scheme === "light" ? "Light" : "Dark"}</span>}
        <span>
          {variant.width}×{variant.height} @2x
        </span>
        <span>{plural(scene.components.length, "component")}</span>
      </p>
      {variant.clip && (
        <section className="section" aria-labelledby="scene-motion">
          <h2 id="scene-motion" className="title-3">
            Motion
          </h2>
          <ClipPlayer key={variant.clip.video} clip={variant.clip} id={scene.id} />
        </section>
      )}
      {pair && sides && pairScheme && (
        <section className="section" aria-labelledby="scene-compare">
          <h2 id="scene-compare" className="title-3">
            Current and proposed
          </h2>
          {pairScheme !== scheme && (
            <p className="note compare-note">
              The proposed version is rendered in {pairScheme} only, so this compares the {pairScheme} renders.
            </p>
          )}
          <Compare
            key={pairScheme}
            id={pair[0].id}
            scheme={pairScheme}
            before={{ picture: { ...sides[0], scale: 2, backdrop: "desktop" }, label: pair[0].title, alt: pair[0].summary }}
            after={{ picture: { ...sides[1], scale: 2, backdrop: "desktop" }, label: pair[1].title, alt: pair[1].summary }}
          />
        </section>
      )}
    </article>
  );
}
