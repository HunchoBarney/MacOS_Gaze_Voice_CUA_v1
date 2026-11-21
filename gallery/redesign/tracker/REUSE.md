# Libraries used by the calibration prototype

All pinned exactly in package.json, installed with pnpm. Licences were read
from each installed package's LICENSE or package.json.

| Library | Version | Licence | What it does here | Directions |
|---|---|---|---|---|
| [Motion](https://motion.dev) (`motion`) | 14.14.0 | MIT | Springs for the point position (independent X and Y), the island morph, dwell progress as motion values, SVG line drawing (pathLength), AnimatePresence crossfades, Reduce Motion via MotionConfig | A, B, C |
| [border-beam](https://libraries.dev/beam) (libraries.dev Beam) | 1.4.1 | MIT | The beam that runs round the island while you look at the camera (A); the beam that circles the screen edge during the verify pass (B) | A, B |
| [thinking-orbs](https://libraries.dev/orbs) (libraries.dev Orb) | 0.3.2 | MIT | "searching" orb in the island while it checks (A); "connecting" orb the constellation folds into (C) | A, C |
| [voice-glow](https://libraries.dev) (libraries.dev Voice glow) | 0.5.0 | MIT | The light gathered under the notch, driven by a fixed level (never the microphone) | B |
| [Paper Shaders](https://shaders.paper.design) (`@paper-design/shaders-react`) | 0.0.82 | Apache-2.0 | PulsingBorder: the full-screen edge glow for the invitation, success and the warm failure; static under Reduce Motion | B |
| React, React DOM | 19.2.7 | MIT | UI | all |
| Vite, @vitejs/plugin-react | 8.0.16, 6.3.0 | MIT | Build | all |
| TypeScript | 6.0.3 | Apache-2.0 | Typecheck | all |

Checked and not used: voice-ring 0.2.0 (MIT) is a voice-reactive ring for
speech UIs; nothing in calibration listens, so it would be decoration.

Custom code is the adapter: the scripted clock, the island shell and lens
ring (A), the focus-pull target and perimeter line (B), the stars, ticks and
lines (C). Named gaps: border-beam's halo is tuned for cards and barely reads
round a 37 pt black notch, and no library draws a constellation that grows
with progress.
