import { useMemo } from "react";
import { toast } from "sonner";
import { Drawer } from "vaul";
import { Link } from "../router";
import type { RedesignComponent } from "../types";
import { choiceLabel, picksSummary, replacePicks, updatePick, usePicks, type Choice } from "./state";

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  }
}

export function PicksButton({ components, onOpen, compact = false }: { components: RedesignComponent[]; onOpen: () => void; compact?: boolean }) {
  const picks = usePicks();
  const done = components.filter((c) => picks[c.id]?.choice).length;
  return (
    <button type="button" className="rd-picks-button" data-compact={compact || undefined} onClick={onOpen} aria-haspopup="dialog">
      <span className="rd-picks-dot" data-done={done > 0 || undefined} aria-hidden="true" />
      <span className="rd-picks-label">Your picks</span>
      <span className="rd-picks-count num">
        {done}/{components.length}
      </span>
    </button>
  );
}

// Vaul: drag to dismiss, focus trap and Escape come from the library (gestures skill). On a wide
// screen it docks to the right edge, on a phone it is a bottom sheet in thumb reach.
export function PicksSheet({ components, open, onOpenChange, wide }: { components: RedesignComponent[]; open: boolean; onOpenChange: (open: boolean) => void; wide: boolean }) {
  const picks = usePicks();
  const summary = useMemo(() => picksSummary(components, picks), [components, picks]);
  const done = components.filter((c) => picks[c.id]?.choice).length;

  async function copy() {
    if (await copyText(summary)) toast("Picks copied", { description: done + " of " + components.length + " components picked." });
    else toast.error("Couldn’t copy. Select the text and copy it instead.");
  }

  function clear() {
    const previous = picks;
    replacePicks({});
    toast("Picks cleared", { action: { label: "Undo", onClick: () => replacePicks(previous) } });
  }

  return (
    <Drawer.Root open={open} onOpenChange={onOpenChange} direction={wide ? "right" : "bottom"}>
      <Drawer.Portal>
        <Drawer.Overlay className="rd-overlay" />
        <Drawer.Content className="rd-sheet" data-side={wide ? "right" : "bottom"} aria-describedby={undefined}>
          {!wide && <Drawer.Handle className="rd-sheet-handle" />}
          <div className="rd-sheet-head">
            <Drawer.Title className="title-3">Your picks</Drawer.Title>
            <span className="rd-sheet-count num">
              {done} of {components.length}
            </span>
          </div>
          <div className="rd-sheet-body" data-vaul-no-drag>
            {components.length === 0 && <p className="muted">Nothing to pick yet.</p>}
            <ul className="rd-sheet-list">
              {components.map((component) => {
                const pick = picks[component.id];
                return (
                  <li key={component.id}>
                    <Link className="rd-sheet-row" href={"/redesign/" + component.id} onClick={() => onOpenChange(false)}>
                      <span className="rd-sheet-title">{component.title}</span>
                      <span className="rd-sheet-choice" data-empty={!pick?.choice || undefined}>
                        {pick?.choice ? choiceLabel(component, pick.choice) : "Not picked"}
                      </span>
                      {pick?.note && <span className="rd-sheet-note">{pick.note}</span>}
                    </Link>
                  </li>
                );
              })}
            </ul>
            <pre className="rd-summary" aria-label="Plain-text summary">
              {summary}
            </pre>
          </div>
          <div className="rd-sheet-foot" data-vaul-no-drag>
            <button type="button" className="rd-button" onClick={clear} disabled={Object.keys(picks).length === 0}>
              Clear
            </button>
            <button type="button" className="rd-button rd-button-primary" onClick={() => void copy()}>
              Copy summary
            </button>
          </div>
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}

export function PickControl({ component }: { component: RedesignComponent }) {
  const pick = usePicks()[component.id];
  const options: { value: Choice; label: string; sub?: string }[] = [
    ...component.directions.map((d) => ({ value: d.id as Choice, label: d.id, sub: d.name })),
    { value: "current", label: "Keep current" },
    { value: "none", label: "None of these" },
  ];
  return (
    <section className="rd-pick" aria-labelledby={"pick-" + component.id}>
      <h2 id={"pick-" + component.id} className="title-3">
        Your pick
      </h2>
      <div className="rd-pick-options" role="radiogroup" aria-labelledby={"pick-" + component.id}>
        {options.map((option) => (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={pick?.choice === option.value}
            className="rd-pick-option"
            onClick={() => updatePick(component.id, { choice: pick?.choice === option.value ? undefined : option.value })}
          >
            <span className="rd-pick-letter">{option.label}</span>
            {option.sub && <span className="rd-pick-name">{option.sub}</span>}
          </button>
        ))}
      </div>
      <label className="rd-note">
        <span className="rd-note-label">Note</span>
        <input
          type="text"
          value={pick?.note ?? ""}
          maxLength={160}
          placeholder="Optional, one line"
          enterKeyHint="done"
          onChange={(event) => updatePick(component.id, { note: event.currentTarget.value })}
          onKeyDown={(event) => {
            if (event.key === "Enter") event.currentTarget.blur();
          }}
        />
      </label>
    </section>
  );
}
