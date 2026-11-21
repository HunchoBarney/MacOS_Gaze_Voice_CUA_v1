# VoiceCore

- Upstream: Jakubantalik/Libraries.dev, packages/voice-ring (shared core) (https://libraries.dev/voice-ring)
- Commit: 14ae9d2 (2026-11-19)
- Path: packages/voice-ring/swift/VoiceCore
- Licence: MIT, Copyright (c) 2026 Jakub Antalik
- Used by: the Jarvis UI Lab only (Package.swift builds it when JARVIS_LAB=1). The shipping app does not link it.

## Patches (each marked `JARVIS PATCH` in the source)

- View/VoiceClock.swift (new): an injectable clock and engine store. The canvas keeps its engine in @State upstream, which ImageRenderer rebuilds every frame; VoiceCanvas reads the clock when one is set.
