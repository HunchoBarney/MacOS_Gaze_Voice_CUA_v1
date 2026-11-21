# EyeTracking fixture renderer (UI gallery)

Renders every surface of the eye tracker's Electron renderer
(`EyeTracking/web/src/App.tsx`) from fixture state. Each surface is rendered
in each state, light and dark, with Reduce Motion off and on. Animated surfaces
also get 60 fps frame sequences. The output is the gallery's
`manifest.tracker.json` fragment (schema: the gallery contract).

    node gallery/tracker/render.mjs --out /absolute/OUT

Options: `--only id[/state],...` renders a subset and writes
`manifest.tracker.partial.json` when a full manifest already exists.
`--no-clips` skips the frame sequences. `--work-dir` sets the build and
Chrome-profile scratch (default `build/gallery-tracker`, gitignored).
`--references` points at JARA-55's renders (default: the captain drive).
`--chrome` sets the Chrome binary. A full run takes about 5 minutes on an M-series
MacBook, and it exits non-zero if any state fails to render.

## How it works

- **The real renderer.** Vite builds the unmodified `App.tsx` and `styles.css`
  with one build-time alias: the app's `./inference/webRuntime` import
  resolves to `fixture/webRuntime.fixture.js`. The bundle loads no model, starts
  no worker and opens no camera. Nothing under `EyeTracking/` is edited, and
  the build output stays out of `EyeTracking/dist`.
- **Fixture bridge.** `fixture/bootstrap.js` runs before the bundle
  (`Page.addScriptToEvaluateOnNewDocument`). It stubs `window.gazeBridge` with
  the shape of `electron/preload.cjs`, refuses `getUserMedia`, clears
  `localStorage` and seeds `Math.random`. Scenarios push the same backend
  messages the tracker sends (`gaze`, `status`, `calibration`, `preview`,
  `lip_click_effect`, `menu_action`).
- **Deterministic time.** The bootstrap replaces `Date`, `performance.now`,
  timers and `requestAnimationFrame` with a manual clock. CSS animations and
  transitions are paused and stepped to the same clock, and a CSS
  `animation-play-state: paused` is honoured. Every frame is exact
  whatever the machine load, so a 60 fps sequence is 60 fps of product time.
- **Headless Chrome** runs over `--remote-debugging-pipe` (no network port)
  with a throwaway `--user-data-dir`, `--use-mock-keychain` and a fake media
  device. It's killed and its profile deleted at exit. The viewport is
  1512x982 CSS px at deviceScaleFactor 2, the logical size of a 14" MacBook Pro.
- **Backdrops.** `transparent` variants are alpha PNGs, cropped tight for
  small surfaces. `desktop` variants put a flat fixture desktop with one generic
  window behind the overlay, light or dark to match the scheme. The overlay
  itself ignores the system appearance. Cropped clips are rendered light and
  dark. Full-screen clips (countdown, capture) are dark only, because the
  calibration scrim hides the desktop.
- **Sources** in the manifest are resolved from code anchors at render time, so
  their file:line stays right as `App.tsx` changes.

Files: `render.mjs` (build, Chrome, capture, manifest), `scenarios.mjs` (the
components, states, clips and scenes), `fixture/` (page-side stubs).
Not part of `make test` or the EyeTracking typecheck/Vitest scope.
