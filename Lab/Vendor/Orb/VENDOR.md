# Orb

- Upstream: metasidd/Orb (https://github.com/metasidd/Orb)
- Commit: a48fc33 (2024-11-11)
- Path: Sources/Orb
- Licence: MIT, Copyright (c) 2024 Siddhant Mehta
- Used by: the Jarvis UI Lab only (Package.swift builds it when JARVIS_LAB=1). The shipping app does not link it.

## Patches (each marked `JARVIS PATCH` in the source)

- OrbClock.swift (new): an injectable `orbClock` environment value; WavyBlobView and RotatingGlowView read it instead of TimelineView's wall clock when set, so clips are frame-exact.
- OrbView.swift: ParticlesView is not built (it is UIKit/SpriteKit-only upstream).
- #Preview blocks removed.
