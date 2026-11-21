# Jarvis UI gallery site

A static Vite + React site that shows every visible Jarvis component in each state, light and dark, with Reduce Motion on and off, plus motion clips, combined scenes and the audit findings beside each component. It deploys to Cloudflare Pages as plain files.

It is a standalone package. It isn't part of any workspace, `make test` and CI don't touch it, and it has its own lockfile.

## Run it

```sh
cd gallery/site
corepack pnpm install --frozen-lockfile
corepack pnpm sample          # fixture renders + findings into public/renders
corepack pnpm dev             # or: corepack pnpm build && corepack pnpm preview
```

With real renders, point the collect step at the harness output and the audit:

```sh
node scripts/collect.mjs --renders <OUT dir> --findings ../audit/findings.json
corepack pnpm build           # dist/ is the Pages output
```

`collect.mjs` merges every `manifest.*.json` fragment in the renders directory (schema in the JARA-56 contract), checks that each referenced image, clip and poster exists, that every finding names a known component and proposed state, and prints warnings for anything missing. It copies the renders, without the raw `*.frames` directories, into `public/renders/` and writes `public/renders/gallery.json`, which the app fetches at runtime. `public/renders/` is gitignored.

Two more things happen in collect:

- **Scene pairs merge.** The native harness renders each scene as `<id>` (dark) and `<id>-light`. Collect folds each pair into one scene with a `variants` entry per appearance, so /scenes lists each moment once and the scene page gets a Light/Dark toggle. A scene without a pair stays as it is.
- **Thumbnails.** Every PNG larger than 960 px on its long side (or over 160 KB) gets a thumbnail in `public/renders/_thumbs/`, made with `sips -Z 960`: JPEG at quality 82 for opaque renders, PNG for transparent overlays so the checkerboard still shows. Grids, cards and contact sheets load the thumbnail; the stage, 1× and 2× keep the full PNG. Thumbnails are cached in `node_modules/.cache/gallery-thumbs`, keyed by path, size and mtime, so a rerun only redoes changed renders. Without `sips` (not on macOS), collect warns and cards fall back to the full images.

## Pages

- `/` all components grouped by area, finding counts by severity, and the scenes strip.
- `/c/<id>` one component: state tabs (← and → switch states), Light/Dark, Reduce Motion, zoom (Fit, 1× pixel-exact at the render's scale, 2×), clips with play, scrub, loop and slow motion, a Current/Proposed swipe or side-by-side compare when a proposed state exists, every state as a contact sheet, and the findings beside the stage. Each finding has an anchor (`/c/<id>#<finding-id>`). The view is kept in the query string (`?s=&scheme=&rm=1&zoom=`), so any view can be linked.
- `/scenes`, `/scenes/<id>` combined scenes on a fixture desktop, with a compare when `<id>-proposed` exists.
- A state or scene with a `superseded` string stays on the site: it shows a muted Superseded tag instead of Proposed, the string as a notice above the stage, and "Superseded proposal" on its side of the compare.
- `/audit` every finding, filterable by severity, area and component (also kept in the query string).
- ⌘K or Ctrl+K opens a palette that jumps to any component, state, finding or scene.

`public/_redirects` sends every path to `index.html` so deep links work on Pages, and `public/_headers` caches hashed assets for a year and revalidates `gallery.json`.

## Sample data

`scripts/make-sample.mjs` writes small SVG placeholders and two manifest fragments into `sample/renders/`, plus `sample/findings.json`. All text is invented fixture data. `sample/clips/` holds one 2.4-second H.264 clip, recorded once from a canvas in headless Chrome, so the clip player has something to play.

See [REUSE.md](REUSE.md) for the libraries and their licences.
