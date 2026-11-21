import { Command } from "cmdk";
import { useEffect, useRef } from "react";
import { navigate } from "../router";
import type { Gallery } from "../types";
import { SeverityChip } from "./Severity";

export default function Palette({ gallery, open, onClose }: { gallery: Gallery; open: boolean; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      element.showModal();
      element.querySelector("input")?.focus();
    }
    if (!open && element.open) element.close();
  }, [open]);

  function go(href: string) {
    onClose();
    navigate(href);
  }

  return (
    <dialog
      ref={dialog}
      className="palette"
      aria-label="Jump to"
      onClose={onClose}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      {open && (
        <Command label="Jump to" loop>
          <Command.Input className="palette-input" placeholder="Jump to a component, state, finding, scene or redesign" autoFocus />
          <Command.List className="palette-list" data-lenis-prevent>
            <Command.Empty className="palette-empty">No matches.</Command.Empty>
            <Command.Group heading="Pages">
              <Command.Item value="Home all components" onSelect={() => go("/")}>
                All components
              </Command.Item>
              <Command.Item value="Scenes" onSelect={() => go("/scenes")}>
                Scenes
              </Command.Item>
              <Command.Item value="Audit findings" onSelect={() => go("/audit")}>
                Audit
              </Command.Item>
              <Command.Item value="Redesign pick directions" onSelect={() => go("/redesign")}>
                Redesign
              </Command.Item>
              <Command.Item value="Redesign scenes" onSelect={() => go("/redesign/scenes")}>
                Redesign scenes
              </Command.Item>
              <Command.Item value="Redesign references the bar" onSelect={() => go("/redesign/references")}>
                References
              </Command.Item>
            </Command.Group>
            {gallery.redesign && gallery.redesign.components.length > 0 && (
              <Command.Group heading="Redesign">
                {gallery.redesign.components.map((c) => (
                  <Command.Item
                    key={c.id}
                    value={"redesign " + c.title + " " + c.id + " " + c.directions.map((d) => d.id + " " + d.name).join(" ")}
                    onSelect={() => go("/redesign/" + c.id)}
                  >
                    <span>{c.title}</span>
                    <span className="palette-meta">{c.directions.map((d) => d.name).join(" · ")}</span>
                  </Command.Item>
                ))}
              </Command.Group>
            )}
            <Command.Group heading="Components">
              {gallery.components.map((c) => (
                <Command.Item key={c.id} value={"component " + c.title + " " + c.area + " " + c.id} onSelect={() => go("/c/" + c.id)}>
                  <span>{c.title}</span>
                  <span className="palette-meta">{c.area}</span>
                </Command.Item>
              ))}
            </Command.Group>
            <Command.Group heading="States">
              {gallery.components.flatMap((c) =>
                c.states.map((s) => (
                  <Command.Item key={c.id + "/" + s.id} value={"state " + c.title + " " + s.title + " " + (s.kind ?? "") + (s.superseded ? " superseded" : "")} onSelect={() => go("/c/" + c.id + "?s=" + s.id)}>
                    <span>
                      {c.title} <span className="palette-sep">›</span> {s.title}
                    </span>
                    {s.superseded ? <span className="palette-meta">Superseded</span> : s.kind === "proposed" && <span className="palette-meta">Proposed</span>}
                  </Command.Item>
                )),
              )}
            </Command.Group>
            <Command.Group heading="Findings">
              {gallery.findings.map((f) => (
                <Command.Item key={f.id} value={"finding " + f.id + " " + f.title + " " + f.severity} onSelect={() => go("/c/" + f.component + "#" + f.id)}>
                  <SeverityChip severity={f.severity} />
                  <span className="palette-finding">{f.title}</span>
                  <span className="palette-meta num">{f.id}</span>
                </Command.Item>
              ))}
            </Command.Group>
            <Command.Group heading="Scenes">
              {gallery.scenes.map((s) => (
                <Command.Item key={s.id} value={"scene " + s.title} onSelect={() => go("/scenes/" + s.id)}>
                  {s.title}
                </Command.Item>
              ))}
            </Command.Group>
          </Command.List>
        </Command>
      )}
    </dialog>
  );
}
