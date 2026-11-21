# Jarvis UI Lab

The redesign of every visible Jarvis surface, as native SwiftUI with real libraries, two or three directions per
component. The owner picks on the public gallery site (Redesign section); this folder is what those clips are
rendered from, so what he picks is what ships.

- `make lab` opens the internal tuning app: components in the sidebar, directions A/B/C, ← → to step states, F to
  play the flow, space to pause, 1×/½×/¼× speed, Dark/Light, Reduce Motion, Reduce Transparency.
- `make redesign` renders every component × direction × state (plus the whole flow) at 60 fps in dark, light,
  dark-rm and light-rm into `build/gallery/renders/redesign/` (or `$JARVIS_GALLERY_OUT`) and writes
  `manifest.redesign.native.json`; `make gallery-site` merges it into the site.
- `JarvisRedesignRender probe <dir> [component]` writes ten stills per direction for a quick look.

## How it is built

- `Redesign/Core`: `MotionBank` (named values driven by SwiftUI's `Spring.update`, so retargets keep velocity),
  `Stage` (clock, state, flow), the `Direction` protocol and `StageView` on the fixture MacBook desktop.
- `Redesign/<Component>`: a fixture script (states, captions, flow) and one file per direction.
- `Vendor`: the libraries at pinned commits (REUSE.md). Their clocks are injected (`orbClock`, `beamFrozenTime`,
  `voiceClock`, `auroraTimes`) because ImageRenderer never advances a TimelineView and rebuilds `@State` each
  frame; the same injected clock makes ½× and ¼× in the lab exact.
- Clips are captured with ImageRenderer (`cacheDisplay` drops shaders and blur) and streamed into AVFoundation's
  H.264 encoder, so no frame folders touch the disk.
- SwiftPM copies .metal files without compiling them; `scripts/lab-metallib.sh` compiles each bundle's
  default.metallib after a build. It needs the Metal Toolchain.

Fixtures only: nothing here opens the microphone, camera or Keychain, and the renderer never shows a window
(activation policy `.prohibited`).
