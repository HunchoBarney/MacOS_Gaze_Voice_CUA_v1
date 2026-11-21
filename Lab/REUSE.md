# Reuse record: Jarvis UI Lab

Every library the redesign directions use, vendored under Lab/Vendor at a pinned commit. Lab targets build only with
`JARVIS_LAB=1`; the shipping Jarvis target links none of them until the owner picks a direction. The site's own
dependencies are in gallery/site/REUSE.md, the calibration prototype's in gallery/redesign/tracker/REUSE.md.

| Library | Upstream, commit | Licence | Capability | Used by | Patch |
|---|---|---|---|---|---|
| ThinkingOrbsKit | libraries.dev Orb (Jakubantalik/Libraries.dev 14ae9d2) | MIT | Dot-lattice thinking orb, SwiftUI Canvas | Voice A Island, Gaze A Beam, Chips A Island, Ask cards A | none |
| BorderBeamKit | libraries.dev Beam (14ae9d2) | MIT | Light that runs a border, Metal + SwiftUI | Gaze A Beam, Flashes A Beam, Chips A Island | `beamFrozenTime` made public |
| VoiceRingKit + VoiceCore | libraries.dev Voice ring (14ae9d2) | MIT | Ring of light that bends with voice level | Voice A Island, Voice C Lumen, Ask cards A and C | injectable clock and engine store (VoiceClock.swift) |
| Aurora | tornikegomareli/Aurora a3f9296 | MIT (README; no LICENSE file upstream, so Lab/Vendor/Aurora/LICENSE carries the grant) | Apple Intelligence edge glow, Metal | Voice B Aurora, Gaze B Aura, Flashes B Siri, Chips B Aura, Sheet B Aurora, Ask cards B | injectable `auroraTimes`; metallib loaded from the module bundle |
| Orb | metasidd/Orb a48fc33 | MIT | Glowing gradient orb | Gaze C Lens, Chips C Quiet | injectable `orbClock`; ParticlesView not built (UIKit-only) |
| DynamicNotchKit | MrKai77/DynamicNotchKit cd0b3e5 | MIT | Notch geometry (silhouette reference) | Voice A, C; Sheet A, C; Ask cards A, C | not vendored: geometry redrawn so it can morph |
| SwiftUI Spring, MeshGradient | Apple, macOS 26 SDK | Platform | Interruptible springs (`Spring.update`), mesh wallpaper | every direction | n/a |

Each Lab/Vendor/<name>/VENDOR.md has the full record and the patch, and every patched line is marked `JARVIS PATCH`.

Considered and not used: twostraws/Inferno (MIT; no direction needed a stock shader once Aurora covered the glow),
libraries.dev Voice glow (MIT; Aurora's palette matched Apple's better), EmergeTools/Pow (MIT; its effects are
UIKit-flavoured transitions, not the continuous springs these surfaces need), Livsy90/IntelligenceGlow (MIT; Aurora is
the more faithful port), Lakr233/ColorfulX, twostraws/Vortex, joogps/Glur, b3ll/Motion, jtrivedi/Wave (SwiftUI's own
`Spring` does what Wave and Motion do, with velocity carry).

Shipping any of the Metal-backed libraries (BorderBeamKit, VoiceCore, Aurora) needs the Metal Toolchain on the
release builder and in CI (`xcodebuild -downloadComponent MetalToolchain`), because SwiftPM copies .metal files
without compiling them; the lab compiles them with scripts/lab-metallib.sh.
