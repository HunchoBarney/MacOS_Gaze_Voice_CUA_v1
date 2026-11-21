# BorderBeamKit

- Upstream: Jakubantalik/Libraries.dev, packages/border-beam (SwiftUI build) (https://libraries.dev/beam)
- Commit: 14ae9d2 (2026-11-19)
- Path: packages/border-beam/swift
- Licence: MIT, Copyright (c) 2026 Jakub Antalik
- Used by: the Jarvis UI Lab only (Package.swift builds it when JARVIS_LAB=1). The shipping app does not link it.

## Patches (each marked `JARVIS PATCH` in the source)

- BeamFrozenTime.swift: `beamFrozenTime` made public so the renderer can drive the beam's clock.
