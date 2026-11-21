import type { Scene, State } from "../types";

export function KindTag({ item }: { item: Pick<State, "kind" | "superseded"> | Pick<Scene, "kind" | "superseded"> }) {
  if (item.superseded) {
    return (
      <span className="kind-tag" data-kind="superseded">
        Superseded
      </span>
    );
  }
  if (item.kind !== "proposed" && item.kind !== "reference") return null;
  return (
    <span className="kind-tag" data-kind={item.kind}>
      {item.kind === "proposed" ? "Proposed" : "Reference"}
    </span>
  );
}
