# Calibration redesign: three directions (gallery prototype)

Three directions for the eye tracker's whole calibration flow, built as React
components and rendered for the UI gallery. They're proposals: nothing under
`EyeTracking/` changes, and the owner's pick ships later.

| | Direction | Axis |
|---|---|---|
| A | **Island** | Contained: everything lives in and comes out of the notch |
| B | **Edge light** | Ambient: the display's edge is the light, with no panels or objects |
| C | **Constellation** | Spatial and playful: the whole task is a map you complete |

Each one covers invitation → camera cue (the yellow arrow's replacement) →
ready (no countdown) → nine points with dwell progress → verify pass → success,
plus the failure path: plain words, Try again, and an 8 s auto-dismiss (ET-2).

## Run it

    node gallery/redesign/tracker/render.mjs --out /absolute/OUT

Writes `OUT/redesign/calibration/<A|B|C>/`: a still per state and variant
(`<state>.<dark|light|dark-rm|light-rm>.png`, 3024x1964), an MP4 and poster per
state clip (`<state>.<variant>.mp4`, `.poster.png`, 60 fps, 1512x982) and
`flow.<variant>.mp4` for the whole ~18 s flow, then
`OUT/manifest.redesign.tracker.json`. Clips are encoded inside Chrome
(WebCodecs H.264, which uses VideoToolbox on the Mac, muxed by mp4-muxer), so no
PNG frame sequence is ever written: the Swift gallery step has nothing to encode
for this producer.

Options: `--only A,C`, `--states intro,look`, `--no-stills`, `--no-clips`,
`--no-perf`, `--clip-variants dark,dark-rm` (default `dark,light,dark-rm`;
light-rm is stills only), `--clip-scale 0.5` (clips at 1512x982, dpr 1),
`--bitrate 3000000`, `--budget-mb 150` (stops once the output folder passes it),
`--work-dir`. A re-run with `--only` keeps the other directions' entries in the
existing manifest.

Disk: the flow is captured once per variant and every happy-path state clip is
encoded from the same frames in that pass. Check `df -h /` before a full run.

Live, with the picker (keys 1–3 or arrows switch, R replays):

    cd gallery/redesign/tracker && corepack pnpm install && corepack pnpm dev

`?scenario=fail` plays the failure path, `?hold=<ms>` freezes the script.

## How it works

- **One scripted clock.** `src/script.ts` and `src/timeline.json` hold the
  fixture script: the tracker's 3x3 "standard" points plus the verify pass's
  four held-out points, paced faster than a real 10 fps run. No camera, worker
  or model. React only re-renders on phase and point changes; positions and
  dwell are Motion values (the ET-5 fix).
- **Deterministic frames.** The renderer injects
  `gallery/tracker/fixture/bootstrap.js` unmodified (manual `Date`,
  `performance.now`, timers, rAF and CSS animations) and hides
  `Element.prototype.animate` so Motion runs its springs on the manual rAF clock
  rather than WAAPI, which the manual clock can step but never finish.
- **Headless Chrome** over `--remote-debugging-pipe` with a throwaway profile,
  1512x982 CSS px at deviceScaleFactor 2, same flags as gallery/tracker plus
  `--disable-features=…,MacAppCodeSignClone` so a launch doesn't leave a 1.5 GB
  code-sign clone in `/private/var/folders`.
- **The desktop** is the gallery's flat fixture desktop with placeholder menu
  bar items and the notch (185x37 pt) drawn at the top centre.
- **Performance** is measured in real time with no fixture clock: 3.6 s of the
  point run traced (main-thread script, style and layout, paint, raster per
  frame) and renderer and GPU process CPU from `SystemInfo.getProcessInfo`,
  then 3 s holding at the invitation as the idle cost. Raw numbers go to
  `<dir>/perf.json`. Headless Chrome on the Mac isn't the Electron app on a
  display, and the cards say so. Each trace also records the 1-minute load
  average and the number of Swift build processes running, because the
  shared build lane is rarely idle; the cards show the load next to every
  figure and label it as measured while other builds were running.

Files: `src/main.tsx` (picker and stage), `src/stage.tsx` (desktop, notch,
Stop), `src/pursuit.ts` (point springs and dwell), `src/directions/` (A, B, C),
`directions.mjs` (cards and captions for the manifest), `render.mjs`.
Libraries and licences: [REUSE.md](REUSE.md).
