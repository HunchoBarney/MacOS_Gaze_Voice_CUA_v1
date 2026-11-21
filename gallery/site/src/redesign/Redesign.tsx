import { useEffect, useState, useSyncExternalStore } from "react";
import { NotFound } from "../pages/NotFound";
import { Link } from "../router";
import type { Gallery, Redesign as RedesignData } from "../types";
import { RedesignComponentPage } from "./ComponentPage";
import { RedesignIndex } from "./Index";
import { PicksButton, PicksSheet } from "./Picks";
import { References } from "./References";
import { RedesignScenes } from "./Scenes";
import "./redesign.css";

const EMPTY: RedesignData = { generatedAt: "", producers: [], components: [], scenes: [] };
const wideQuery = matchMedia("(min-width: 900px)");
const useWide = () =>
  useSyncExternalStore(
    (listener) => {
      wideQuery.addEventListener("change", listener);
      return () => wideQuery.removeEventListener("change", listener);
    },
    () => wideQuery.matches,
  );

export default function Redesign({ gallery, path }: { gallery: Gallery; path: string }) {
  const data = gallery.redesign ?? EMPTY;
  const [open, setOpen] = useState(false);
  const wide = useWide();
  const component = path && path !== "scenes" && path !== "references" ? data.components.find((c) => c.id === path) : undefined;
  const openPicks = () => setOpen(true);

  useEffect(() => setOpen(false), [path]);

  let page;
  if (!path) page = <RedesignIndex gallery={gallery} data={data} openPicks={openPicks} />;
  else if (path === "scenes") page = <RedesignScenes data={data} />;
  else if (path === "references") page = <References />;
  else if (component) page = <RedesignComponentPage key={component.id} gallery={gallery} data={data} component={component} openPicks={openPicks} />;
  else page = <NotFound />;

  const section = !path ? "overview" : path === "scenes" || path === "references" ? path : "component";

  return (
    <div className="rd" data-section={section}>
      <nav className="rd-subnav page" aria-label="Redesign">
        <Link href="/redesign" aria-current={section === "overview" ? "page" : undefined}>
          Overview
        </Link>
        <Link href="/redesign/scenes" aria-current={section === "scenes" ? "page" : undefined}>
          Scenes
        </Link>
        <Link href="/redesign/references" aria-current={section === "references" ? "page" : undefined}>
          References
        </Link>
      </nav>
      {page}
      {section !== "component" && data.components.length > 0 && (
        <div className="rd-float">
          <PicksButton components={data.components} onOpen={openPicks} />
        </div>
      )}
      <PicksSheet components={data.components} open={open} onOpenChange={setOpen} wide={wide} />
    </div>
  );
}
