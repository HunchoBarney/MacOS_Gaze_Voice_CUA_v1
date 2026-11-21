# Jarvis UI gallery

Every visible Jarvis surface, rendered from fixture state in each of its
states, light and dark, with Reduce Motion off and on, plus combined desktop
scenes and the audit's proposed directions. The owner's rule (project
AGENTS.md): a PR that adds or changes a visible component updates its gallery
page in the same PR, redeploys the site and links before and after in its body.

    make gallery          # render everything into build/gallery/renders
    make gallery-site     # collect the renders and build gallery/site/dist
    make gallery-deploy   # build, then publish to Cloudflare Pages

## What renders where

- **Native overlays and windows** come from `Tests/JarvisGalleryTests`, an
  XCTest target that only runs when `JARVIS_GALLERY_OUT` is set (so `make
  test` skips it). It hosts the real SwiftUI views and AppKit panels
  (listening indicator, gaze ring, halo, flashes, chips, guide callout, agent
  cursor and shelf, Settings, Agents, first run) offscreen: `VirtualScreen`
  keeps every window off the display and `AnimationClock` steps Core
  Animation to a virtual time, so 60 fps clips are exact on a loaded machine.
  Surfaces whose state is private to the app delegate (the menu-bar item and
  menu) are drawn from replicas in `Replicas.swift` that copy the product code
  line for line and cite it. `Proposals.swift` holds the audit's SwiftUI
  mockups, which render on the same desktop at the same size.
- **Eye tracker** surfaces come from `gallery/tracker`: the unmodified
  `EyeTracking/web` renderer built with a fixture runtime and driven in
  headless Chrome (see its README). No camera, model or worker starts.
- **Findings** live in `gallery/audit/findings.json` (severity, file:line,
  problem, fix, library, skills, proposed state). The site links each finding
  to the component and state it is about.
- **The site** is `gallery/site` (Vite and React, libraries from the project's
  ui-libraries list; see its REUSE.md). `scripts/collect.mjs` merges
  `manifest.native.json` and `manifest.tracker.json` with the findings.

`scripts/gallery.sh` runs both producers. It wipes `build/gallery/renders`
first, runs the Swift harness through `scripts/lane-test.sh` (one heavy build
at a time on the shared Mac) and fails if a manifest is missing or the harness
recorded a failure. `GALLERY_SKIP_TRACKER=1` renders only the native side.

## Rules

- Fixture data only: no personal data, real screen content, microphone,
  camera, Keychain or permission prompts. The site is public.
- Nothing here changes product behaviour. The harness reads product code
  through `@testable import Jarvis` and never edits it.
- Overlay windows use `sharingType = .none`, so screen capture can't see them.
  Render offscreen; don't screenshot the live app.
- A replica must cite the product lines it copies. When those lines change,
  update the replica in the same PR (the harness pixel-compares the replicas
  it can against the real views and records a failure on drift).
