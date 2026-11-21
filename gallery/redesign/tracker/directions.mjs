// The three calibration directions: the cards the gallery site shows, the
// captions per state, and how render.mjs turns a measurement into the card's
// perf line. Timings come from src/timeline.json, shared with the prototype.
import { readFileSync } from "node:fs";

const timeline = JSON.parse(readFileSync(new URL("./src/timeline.json", import.meta.url), "utf8"));

const LIB = {
  motion: { name: "Motion", version: "14.14.0", license: "MIT", url: "https://motion.dev" },
  beam: { name: "border-beam (libraries.dev Beam)", version: "1.4.1", license: "MIT", url: "https://libraries.dev/beam" },
  orbs: { name: "thinking-orbs (libraries.dev Orb)", version: "0.3.2", license: "MIT", url: "https://libraries.dev/orbs" },
  glow: { name: "voice-glow (libraries.dev Voice glow)", version: "0.5.0", license: "MIT", url: "https://libraries.dev" },
  paper: { name: "Paper Shaders (@paper-design/shaders-react)", version: "0.0.82", license: "Apache-2.0", url: "https://shaders.paper.design" }
};
const lib = (key, role) => ({ ...LIB[key], role });

const pct = (v) => (v < 0.05 ? "<0.1%" : v.toFixed(1) + "%");
const ms = (v) => (v < 0.05 ? "<0.1" : v.toFixed(1));
function perfCard(m) {
  const p = m.pursuit;
  return {
    cpu: pct(p.rendererCpu) + " renderer",
    gpu: ms(p.gpuMsPerFrame) + " ms/frame GPU process",
    idle: pct(m.idle.rendererCpu + m.idle.gpuCpu) + " waiting at the invitation",
    note:
      "Headless Chrome on an M1, real time, 3.6 s of the point run: " + Math.round(p.fps) + " fps, main thread per frame " +
      ms(p.scriptMs) + " ms script, " + ms(p.styleLayoutMs) + " ms style and layout, " + ms(p.paintMs) + " ms paint, " +
      ms(p.rasterMs) + " ms raster; GPU process " + pct(p.gpuCpu) + " CPU. Not the Electron app on a display."
  };
}

// Skills that changed every direction, then each direction's own.
const SHARED_SKILLS = [
  { skill: "ask-emil", change: "Routed the work: prototype for the three directions, then animate and choreograph to build, then review-animations, animation-performance and break-ui to check." },
  { skill: "prototype", change: "Three named directions on three different axes behind the PICKER.md picker; no two share an axis position." },
  { skill: "animate", change: "Calibration is a rare moment, so it gets the delight budget, but every motion names its purpose; the 3 s countdown and the 0.4 Hz breathing loop failed the gate and are gone." },
  { skill: "apple-design", change: "Independent X and Y critically damped springs that retarget mid-flight, no overshoot on anything the person didn't throw, and Reduce Motion as crossfades with no travel." },
  { skill: "emil-design-eng", change: "Nothing enters from scale(0); entrances use opacity plus a 4–6 px blur, exits are faster than entrances, buttons press to 0.97." },
  { skill: "remove-animations", change: "Cut the yellow arrow, the countdown numeral and idle pulsing; nothing animates while a point is simply waiting." },
  { skill: "animation-performance", change: "Point position and dwell live in Motion values, not React state (ET-5); motion is transform and opacity; heavy layers unmount when hidden." },
  { skill: "animate-expo", change: "Principles only: springs for anything that can be interrupted, timing curves for scripted fades, and per-frame work kept out of the render tree." },
  { skill: "break-ui", change: "Copy checked at its longest (no orphans in the failure text); Reduce Transparency swaps blur for solid fills; the light theme gets its own inks rather than inverted glows." },
  { skill: "review-animations", change: "UI motion stays under 300 ms except the deliberate travel and the 8 s auto-dismiss timer, which is linear on purpose." },
  { skill: "find-animation-opportunities", change: "Added motion only where it carries state: the dwell fill, the progress, and the hand-off from camera to first point." }
];

const states = (captions) => timeline.states.map((s) => ({ ...s, caption: captions[s.id] }));
const flowMs = timeline.T.end;

export const COMPONENT = {
  id: "calibration",
  batch: 1,
  title: "Calibration",
  summary:
    "The whole eye-tracker calibration, start to finish: invitation, the camera cue that replaces the yellow arrow, ready, the nine points with dwell progress, verifying, success, and a recoverable failure. Three directions on three different axes, rendered from one scripted fixture clock (no camera, no model).",
  current: {
    componentIds: ["tracker-calibration", "tracker-camera-marker", "tracker-onboarding"],
    note: "Today: the first-run card on an opaque scrim, the yellow camera arrow, a 120 px countdown, the point run and raw verification errors (ET-1 to ET-4, ET-10, ET-13, ET-14)."
  }
};

export const DIRECTIONS = [
  {
    id: "A",
    flowMs,
    perfCard,
    card: {
      id: "A",
      name: "Island",
      axis: "Contained: everything lives in and comes out of the notch",
      pitch: "Wins if calibration should feel like part of Jarvis's voice island: one black object that never leaves the notch's orbit and keeps the desktop in view.",
      cost: "Small type in a 476 pt island is the whole explanation, and the notch beam only reads as \"camera\" once you know the camera is there.",
      libraries: [
        lib("motion", "Island morph (size springs), content crossfades, the point's X/Y springs and dwell ring"),
        lib("beam", "The light that runs around the notch while you look at the camera"),
        lib("orbs", "The 'Checking' indicator inside the island while the verify pass runs")
      ],
      custom: "The island shell (width, height and radius on one black layer), the notch fillets, the lens ring and the dwell ring are thin adapter code around Motion. Gap named: border-beam's halo is tuned for cards and barely reads round a 37 pt black notch, so the lens ring carries the camera cue and the beam is decoration.",
      skills: [
        ...SHARED_SKILLS,
        { skill: "choreograph", change: "One object carries the flow: the lens ring is point zero, the drop that leaves it is the target, and it flies back into the island to check. The island's content crossfades 40–70 ms after the shell starts moving." },
        { skill: "gestures", change: "Track versus settle: the drop settles at each point on a critically damped spring and the island morph is a spring so it can be interrupted mid-grow." }
      ]
    },
    states: states({
      intro: "The island grows out of the notch to ask. No scrim: the desktop stays as it is.",
      look: "The notch itself lights up (a beam runs round it) and a second bubble splits off: Look at the camera. Replaces the yellow arrow.",
      ready: "No countdown: a drop of the island falls to the first point, and that fall is the get-ready.",
      capture: "Each point fills a ring while you look; it turns green as it lands and the drop glides on. The island keeps a tiny progress ring.",
      verify: "Four quick check points with no ring, then the drop flies back up into the island, which says Checking.",
      success: "The island opens once to say it worked, then folds back into the notch.",
      failure: "Plain words, what to try, and that the old calibration still works. Try again, or it closes itself after 8 s."
    })
  },
  {
    id: "B",
    flowMs,
    perfCard,
    card: {
      id: "B",
      name: "Edge light",
      axis: "Ambient: the display's edge is the light, with no panels or objects",
      pitch: "Wins if calibration should feel like Apple Intelligence: light that lives in the screen's edge, pools under the camera and focuses where you look.",
      cost: "A full-screen shader runs while it's on screen, the costliest of the three on the GPU, and the light needs a calm desktop to read.",
      libraries: [
        lib("paper", "The full-screen edge glow (PulsingBorder) for the invitation, success and the warm failure"),
        lib("glow", "Light gathered under the notch: the camera cue"),
        lib("beam", "The beam that circles the screen edge while the verify pass checks"),
        lib("motion", "Focus pull at each point, the perimeter progress line, crossfades")
      ],
      custom: "The focus-pull target (a soft bloom that tightens to a point) and the perimeter progress path are adapter code over Motion values. The edge light, notch light and verify beam are the libraries as shipped, tuned by props.",
      skills: [
        ...SHARED_SKILLS,
        { skill: "choreograph", change: "Light is conserved: the edge glow drains into the notch, falls to the first point and focuses; the perimeter line and the focus share one progress value." },
        { skill: "gestures", change: "The focus follows a spring of the dwell value, so moving defocuses and holding sharpens, with no hard reset between points." }
      ]
    },
    states: states({
      intro: "The screen's edge glows and the words sit straight on the desktop, with no card.",
      look: "The edge light drains and gathers under the notch, so the camera is where the light is.",
      ready: "The pooled light drops from the camera to the centre and focuses there.",
      capture: "Each point arrives soft and sharpens as you hold your gaze: focus is the progress. A hairline grows round the screen edge as points land.",
      verify: "A beam circles the screen edge while four quick points are checked.",
      success: "The edge blooms once and the light leaves the screen.",
      failure: "The edge turns warm, the words say what to try, and the glow recedes over 8 s as it closes itself."
    })
  },
  {
    id: "C",
    flowMs,
    perfCard,
    card: {
      id: "C",
      name: "Constellation",
      axis: "Spatial and playful: the whole task is a map you complete",
      pitch: "Wins if people should see the whole job up front and enjoy finishing it: nine stars, each one you look at joins the constellation.",
      cost: "The most to look at: a dimmed, blurred desktop and lines across the screen, and it asks more of a first-time user's attention.",
      libraries: [
        lib("motion", "Star entrances, line drawing (pathLength), the star's X/Y springs, the fall from the camera"),
        lib("orbs", "The 'connecting' orb the constellation folds into while it checks")
      ],
      custom: "Star ticks and the constellation lines are SVG driven by Motion values; the camera guide is a short Motion sequence. Named gap: no library draws a constellation that grows with progress.",
      skills: [
        ...SHARED_SKILLS,
        { skill: "choreograph", change: "Stars enter staggered by distance from the centre (a wave, not a metronome); each line draws with the same spring the marker travels on, so they read as one stroke." },
        { skill: "gestures", change: "The reticle closes on a spring with a little bounce, the only bounce in the flow, because it's the playful direction's one flourish." }
      ]
    },
    states: states({
      intro: "All nine stars are there from the start, so the size of the job is visible before you begin.",
      look: "A trail of sparks rises to the camera and a reticle closes round it: look up here.",
      ready: "The camera's star falls to the centre and draws the first line.",
      capture: "Twelve ticks light round the star as you look; when it lands, a line draws to the next.",
      verify: "The lines dim, four test stars light in turn, and the constellation folds into a thinking orb.",
      success: "A check, then the star flies up into the notch, where Jarvis lives.",
      failure: "The constellation shows where it struggled: the two stars that didn't take are hollow, and Retry asks for just those."
    })
  }
];
