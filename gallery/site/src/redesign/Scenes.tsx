import { MoonIcon, SunIcon } from "../components/Icons";
import { Segmented } from "../components/Segmented";
import { Link } from "../router";
import { setTheme, useTheme } from "../theme";
import type { Redesign, RedesignScene, Scheme } from "../types";
import { ClipView, Transport } from "./Clip";
import { useClock } from "./clock";
import { choiceLabel, pickMedia, setReduceMotion, useReduceMotion } from "./state";

export function RedesignScenes({ data }: { data: Redesign }) {
  const { resolved: scheme } = useTheme();
  const rm = useReduceMotion();
  return (
    <div className="page rd-scenes">
      <header className="rd-head">
        <p className="eyebrow">Redesign</p>
        <h1 className="title-1">Scenes</h1>
        <p className="lede">The picked directions together on a MacBook desktop with the notch, so you can judge how they sit with each other and with real work.</p>
      </header>
      <div className="rd-toolbar">
        <div className="rd-toggles">
          <Segmented<Scheme>
            id="rd-scene-scheme"
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
      {data.scenes.length === 0 && <p className="muted rd-empty">No redesign scenes yet.</p>}
      {data.scenes.map((scene) => (
        <SceneBlock key={scene.id} scene={scene} data={data} scheme={scheme} rm={rm} />
      ))}
    </div>
  );
}

function SceneBlock({ scene, data, scheme, rm }: { scene: RedesignScene; data: Redesign; scheme: Scheme; rm: boolean }) {
  const clock = useClock({ autoplay: true });
  const resolved = pickMedia(scene.media, scheme, rm);
  return (
    <section id={scene.id} className="rd-scene" aria-labelledby={scene.id + "-title"}>
      <div className="rd-scene-head">
        <h2 id={scene.id + "-title"} className="title-2">
          {scene.title}
        </h2>
        <p className="rd-text">{scene.caption}</p>
      </div>
      <ClipView resolved={resolved} clock={clock} label={scene.title} scheme={scheme} />
      <Transport clock={clock} />
      {Object.keys(scene.picks).length > 0 && (
        <ul className="rd-scene-picks" aria-label="Directions in this scene">
          {Object.entries(scene.picks).map(([id, choice]) => {
            const component = data.components.find((c) => c.id === id);
            return (
              <li key={id}>
                <Link className="rd-mini-chip" href={"/redesign/" + id}>
                  {component ? component.title + ": " + choiceLabel(component, choice as "A") : id + ": " + choice}
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
