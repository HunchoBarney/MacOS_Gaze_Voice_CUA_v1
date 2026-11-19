# FluidVoice attribution

Selected visual and panel patterns are adapted from [FluidVoice](https://github.com/altic-dev/FluidVoice), commit `0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b`, under GPL-3.0. Copyright remains with the FluidVoice contributors; see [LICENSE](LICENSE).

Sources: `Sources/Fluid/Views/BottomOverlayView.swift` (panel configuration and center-weighted waveform), `Sources/Fluid/Theme/Components/ThemedCard.swift` (card shape/material treatment), and `Sources/Fluid/Theme/AppTheme.swift` (spacing and corner scales).

Adapted into `Sources/Jarvis/VoiceStyle.swift` and `Sources/Jarvis/VoiceWindows.swift`. Application services, speech engines, persistence, analytics, updates, and model code were not imported. The shortcut state machine is a separate implementation informed by the upstream event-tap approach.
