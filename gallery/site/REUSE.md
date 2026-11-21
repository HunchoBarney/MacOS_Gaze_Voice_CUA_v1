# Gallery site: reused libraries

The gallery site follows the project's library-first rule: every visual or interaction library below is on the owner's approved list (`ui-libraries.md` in the project drive) or Emil Kowalski's `pick-ui-library` list, and each licence was read from the installed package on 2026-11-20. Versions are pinned exactly in `package.json` and `pnpm-lock.yaml`.

| Library | Version | Licence | What it does here |
| --- | --- | --- | --- |
| [motion](https://motion.dev) | 14.14.0 | MIT | Shared-layout (`layoutId`) pills for the state tabs and segmented controls, critically damped springs (`bounce: 0`), and `MotionConfig reducedMotion="user"` so layout motion drops out under Reduce Motion. |
| [cmdk](https://github.com/dip/cmdk) | 1.1.1 | MIT | The ⌘K palette that jumps to any component, state, finding or scene. Loaded lazily on first use. |
| [Lenis](https://lenis.darkroom.engineering) | 1.3.27 | MIT | Smooth wheel scrolling on pointer devices. Never started under `prefers-reduced-motion` or on touch, and torn down if the setting changes. Loaded as its own chunk. |
| [@number-flow/react](https://number-flow.barvian.me) | 0.6.2 | MIT | Counts on the home stats and the audit filters, so a filter change rolls the digits instead of swapping them. Honours Reduce Motion itself. |
| [Sonner](https://sonner.emilkowal.ski) | 2.0.8 | MIT | The "Link copied" toast when a finding's anchor is copied. |
| [@paper-design/shaders-react](https://shaders.paper.design) | 0.0.82 | Apache-2.0 | A low-contrast `MeshGradient` behind the home hero only. It is still under Reduce Motion, pauses when the hero scrolls out of view, caps its pixel count, and loads as a lazy chunk. |
| [React](https://react.dev) / react-dom | 19.2.7 | MIT | Rendering. |
| [Vite](https://vite.dev) + @vitejs/plugin-react | 8.0.16 / 6.3.0 | MIT | Dev server and static build. |
| [TypeScript](https://www.typescriptlang.org) | 6.0.3 | Apache-2.0 | Type checking (`tsc --noEmit`). |

## What is custom, and why

- **Router.** About thirty lines over the History API (`src/router.tsx`). The site has five routes and no data loading, so a routing library would add weight without adding anything.
- **Icons.** Inline SVG drawn for the site in an SF Symbols style (`src/components/Icons.tsx`). Lucide and Phosphor are on the cut list.
- **Compare slider and clip controls.** Each is a thin layer over a platform primitive: `clip-path` with pointer capture for the swipe (1:1 tracking, keyboard operable as a `slider`), and `<video>` with a range input for scrubbing. No approved library covers either.
- **Palette shell.** A native `<dialog>` hosts cmdk's `Command`, so focus trapping, Escape and the inert background come from the platform.

## Transitive dependency to know about

cmdk 1.1.1 depends on four `@radix-ui` packages (dialog, primitive, id, compose-refs), and part of that code ends up in the lazily loaded palette chunk. The site doesn't use Radix directly, and none of its styling reaches the page. Radix is on the cut list as a component kit to build with; this is an internal of cmdk, the approved command-menu library.
