#!/usr/bin/env node
// Writes the redesign fixture into sample/renders: manifest.redesign.native.json and
// manifest.redesign.tracker.json in the contract's shape, the placeholder clips recorded by
// record-sample-clips.mjs, and SVG stills for the components that have no clips. Run after
// make-sample.mjs (which clears sample/renders). Every string and number here is invented.
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "sample");
const out = join(root, "renders");
const clipsDir = join(root, "clips", "redesign");
const clipIndex = JSON.parse(readFileSync(join(clipsDir, "clips.json"), "utf8"));
const W = 480;
const H = 300;

function write(rel, content) {
  mkdirSync(dirname(join(out, rel)), { recursive: true });
  writeFileSync(join(out, rel), content);
  return rel;
}

function clip(id, rel) {
  mkdirSync(dirname(join(out, rel)), { recursive: true });
  copyFileSync(join(clipsDir, id + ".mp4"), join(out, rel + ".mp4"));
  copyFileSync(join(clipsDir, id + ".jpg"), join(out, rel + ".jpg"));
  const { width, height, fps, duration } = clipIndex[id];
  return { kind: "clip", src: rel + ".mp4", poster: rel + ".jpg", width, height, fps, duration };
}

const FONT = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
const palette = {
  dark: { a: "#151a2e", b: "#2a2850", c: "#4b2f4a", win: "#1e1e22", line: "#ffffff14", text: "#f5f5f7", sub: "#ffffff8c" },
  light: { a: "#c9d6f2", b: "#dcd3ee", c: "#efd2df", win: "#ffffff", line: "#0000000f", text: "#1d1d1f", sub: "#0000008c" },
};

function desk(scheme, body, label) {
  const p = palette[scheme];
  let s = '<svg xmlns="http://www.w3.org/2000/svg" width="' + W * 2 + '" height="' + H * 2 + '" viewBox="0 0 ' + W + " " + H + '" font-family="' + FONT + '">';
  s += '<defs><linearGradient id="d" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="' + p.a + '"/><stop offset="0.6" stop-color="' + p.b + '"/><stop offset="1" stop-color="' + p.c + '"/></linearGradient>';
  s += '<filter id="g" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter></defs>';
  s += '<rect width="' + W + '" height="' + H + '" fill="url(#d)"/><rect width="' + W + '" height="14" fill="#00000040"/>';
  s += '<rect x="' + (W / 2 - 46) + '" y="-8" width="92" height="22" rx="8" fill="#000"/>';
  s += '<rect x="70" y="60" width="340" height="200" rx="10" fill="' + p.win + '"/>';
  for (let i = 0; i < 4; i += 1) s += '<rect x="92" y="' + (100 + i * 22) + '" width="' + (220 - (i % 3) * 50) + '" height="8" rx="4" fill="' + p.line + '"/>';
  s += '<rect x="324" y="202" width="60" height="18" rx="6" fill="#0a84ff"/><text x="354" y="215" fill="#fff" font-size="9" font-weight="600" text-anchor="middle">Send</text>';
  s += body;
  s += '<text x="10" y="' + (H - 10) + '" fill="' + p.sub + '" font-size="10" font-weight="600">SAMPLE · ' + label + "</text></svg>\n";
  return s;
}

function stills(base, make, schemes = ["dark", "light"]) {
  const set = {};
  for (const scheme of schemes) set[scheme] = { kind: "still", src: write(base + "." + scheme + ".svg", make(scheme)), width: W * 2, height: H * 2 };
  return set;
}

const gaze = {
  A: (state) => (scheme) =>
    desk(
      scheme,
      '<rect x="316" y="194" width="76" height="34" rx="11" fill="none" stroke="#5ee7ff" stroke-width="' + (state === "locked" ? 3 : 1.5) + '" opacity="' + (state === "locked" ? 1 : 0.6) + '"/>' +
        (state === "locked" ? '<rect x="316" y="194" width="76" height="34" rx="11" fill="none" stroke="#5ee7ff" stroke-width="6" opacity="0.5" filter="url(#g)"/>' : ""),
      "Halo ring · " + state,
    ),
  B: (state) => (scheme) =>
    desk(
      scheme,
      '<rect x="' + (state === "locked" ? 320 : 322) + '" y="' + (state === "locked" ? 198 : 200) + '" width="' + (state === "locked" ? 68 : 64) + '" height="' + (state === "locked" ? 26 : 22) + '" rx="8" fill="#ffffff" opacity="0.18"/>' +
        '<circle cx="354" cy="240" r="' + (state === "locked" ? 4 : 6) + '" fill="#ffd60a" opacity="0.9"/>',
      "Lift · " + state,
    ),
};

const flash = {
  A: (state) => (scheme) => desk(scheme, '<circle cx="354" cy="211" r="' + (state === "this" ? 30 : 46) + '" fill="none" stroke="#30d158" stroke-width="2" opacity="0.7"/>', "Ripple · " + state),
  B: (state) => (scheme) => desk(scheme, '<rect x="322" y="200" width="64" height="22" rx="7" fill="#ffffff" opacity="' + (state === "this" ? 0.5 : 0.3) + '" filter="url(#g)"/>', "Glint · " + state),
  C: (state) => (scheme) => desk(scheme, '<rect x="3" y="3" width="474" height="294" rx="16" fill="none" stroke="#30d158" stroke-width="' + (state === "this" ? 2 : 4) + '" opacity="0.7" filter="url(#g)"/>', "Edge pulse · " + state),
};

function calibrationSvg(name, state) {
  let s = '<svg xmlns="http://www.w3.org/2000/svg" width="' + W * 2 + '" height="' + H * 2 + '" viewBox="0 0 ' + W + " " + H + '" font-family="' + FONT + '"><rect width="' + W + '" height="' + H + '" fill="#050506"/>';
  if (state === "camera-marker") {
    s += '<rect x="' + (W / 2 - 46) + '" y="-8" width="92" height="22" rx="8" fill="#111"/><circle cx="' + W / 2 + '" cy="5" r="3" fill="#30d158"/>';
    s += '<path d="M' + (W / 2) + " 22 l-8 14 h16 z" + '" fill="#ffffff8c"/><text x="' + W / 2 + '" y="60" fill="#ffffffb3" font-size="12" text-anchor="middle">Camera is here</text>';
  } else {
    const pts = [];
    for (let r = 0; r < 3; r += 1) for (let c = 0; c < 3; c += 1) pts.push([60 + c * 180, 50 + r * 100]);
    pts.forEach(([x, y], i) => {
      const active = state === "calibrating" && i === 4;
      const seen = state === "complete" || i < 4;
      if (name === "Single dot" && !active && state === "calibrating") return;
      if (active) s += '<circle cx="' + x + '" cy="' + y + '" r="' + (name === "Breath" ? 26 : 18) + '" fill="#64d2ff" opacity="0.2"/>';
      s += '<circle cx="' + x + '" cy="' + y + '" r="' + (active ? 8 : 4) + '" fill="' + (active ? "#64d2ff" : seen ? "#ffffff8c" : "#ffffff2e") + '"/>';
    });
    if (name === "Constellation" && state === "complete") s += '<path d="M60 50 L240 150 L420 250" stroke="#64d2ff" stroke-width="1" opacity="0.4" fill="none"/>';
  }
  s += '<text x="10" y="' + (H - 10) + '" fill="#ffffff8c" font-size="10" font-weight="600">SAMPLE · ' + name + " · " + state + "</text></svg>\n";
  return s;
}

const lib = (name, version, license, url, role) => ({ name, version, license, url, role });
const sampleSkills = [
  { skill: "apple-design", change: "Sample: the shape grows from the hardware instead of floating." },
  { skill: "animate", change: "Sample: critically damped spring, no bounce on state changes." },
];
const perf = (cpu, gpu, idle) => ({ cpu, gpu, idle, note: "Sample numbers, not a measurement." });

const voiceStates = [
  { id: "listening", title: "Listening" },
  { id: "thinking", title: "Thinking" },
  { id: "speaking", title: "Speaking" },
];

function voiceDirection(id, name, axis, pitch, cost, libraries, perfNumbers, withRm = false) {
  return {
    id,
    name,
    axis,
    pitch,
    cost,
    libraries,
    custom: "Sample: the adapter that maps the voice level to the shape.",
    skills: sampleSkills,
    perf: perfNumbers,
    states: voiceStates.map((s) => ({
      ...s,
      caption: "Sample caption for " + name + ", " + s.title.toLowerCase() + ".",
      media: {
        dark: clip(id + "-" + s.id, "redesign/voice-island/" + id + "/" + s.id + ".dark"),
        ...(withRm ? { "dark-rm": clip(id + "-" + s.id + "-rm", "redesign/voice-island/" + id + "/" + s.id + ".dark-rm") } : {}),
      },
    })),
    flow: { dark: clip(id + "-flow", "redesign/voice-island/" + id + "/flow.dark") },
  };
}

const native = {
  generatedAt: "2026-11-21T00:00:00Z",
  commit: "sample",
  components: [
    {
      id: "voice-island",
      batch: 1,
      title: "Voice surface",
      summary: "Sample summary. What Jarvis shows while it listens, thinks and speaks.",
      current: { componentIds: ["listening-indicator"], note: "Sample note: today’s capsule with a label." },
      directions: [
        voiceDirection("A", "Island", "Grows out of the notch", "Sample: wins on a MacBook with a notch.", "Sample: needs a fallback on external displays.", [lib("DynamicNotchKit", "1.0.0", "MIT", "https://github.com/MrKai77/DynamicNotchKit", "Sample role: the notch-anchored window.")], perf("1.2%", "0.4 ms/frame", "0.0%")),
        voiceDirection("B", "Aurora", "Light around the screen edge", "Sample: wins when the middle of the screen must stay clear.", "Sample: a full-screen layer to composite.", [lib("Inferno", "1.0.0", "MIT", "https://github.com/twostraws/Inferno", "Sample role: the glow shader.")], perf("2.4%", "1.1 ms/frame", "0.1%"), true),
        voiceDirection("C", "Orb", "A small companion near the work", "Sample: wins when Jarvis should feel like a presence.", "Sample: competes with the cursor for attention.", [lib("Orb", "1.0.0", "MIT", "https://github.com/metasidd/Orb", "Sample role: the orb itself.")], perf("1.6%", "0.7 ms/frame", "0.0%")),
      ],
    },
    {
      id: "gaze-highlight",
      batch: 1,
      title: "Gaze highlight and orb",
      summary: "Sample summary. How Jarvis shows what you are looking at before it acts.",
      current: { componentIds: ["target-overlay"] },
      directions: ["A", "B"].map((id) => ({
        id,
        name: id === "A" ? "Halo ring" : "Lift",
        axis: id === "A" ? "Outline the target" : "Raise the target, mark the eye",
        pitch: "Sample pitch.",
        cost: "Sample cost.",
        libraries: [],
        custom: "Sample: drawn natively, no library covers a gaze target.",
        skills: sampleSkills,
        states: ["dwell", "locked"].map((s) => ({
          id: s,
          title: s === "dwell" ? "Dwell" : "Locked",
          media: stills("redesign/gaze-highlight/" + id + "/" + s, gaze[id](s)),
        })),
      })),
    },
    {
      id: "flashes",
      batch: 1,
      title: "Confirmation flashes",
      summary: "Sample summary. The flash that confirms an action and the “this” marker.",
      current: { componentIds: [], note: "Sample note: today’s flashes aren’t in the gallery yet." },
      directions: ["A", "B", "C"].map((id) => ({
        id,
        name: { A: "Ripple", B: "Glint", C: "Edge pulse" }[id],
        axis: { A: "Out from the click", B: "On the control itself", C: "Around the whole screen" }[id],
        pitch: "Sample pitch.",
        cost: "Sample cost.",
        libraries: [lib("Pow", "1.0.0", "MIT", "https://github.com/EmergeTools/Pow", "Sample role: the transition.")],
        skills: sampleSkills,
        perf: perf("0.3%", "0.2 ms/frame", "0.0%"),
        states: [
          { id: "confirm", title: "Confirm", media: stills("redesign/flashes/" + id + "/confirm", flash[id]("confirm")) },
          { id: "this", title: "“This”", media: stills("redesign/flashes/" + id + "/this", flash[id]("this")) },
        ],
      })),
    },
  ],
  scenes: [
    {
      id: "desk-island",
      title: "Asking about a draft",
      caption: "Sample caption. The island listens while the gaze ring marks Send.",
      picks: { "voice-island": "A", "gaze-highlight": "B" },
      media: { dark: clip("scene-desk", "redesign/scenes/desk-island.dark") },
    },
  ],
};

const tracker = {
  generatedAt: "2026-11-21T00:00:00Z",
  commit: "sample",
  components: [
    {
      id: "calibration",
      batch: 1,
      title: "Calibration and camera marker",
      summary: "Sample summary. The calibration the eye tracker runs before gaze is used, and the marker that shows where the camera is.",
      current: { componentIds: ["tracker-calibration"], note: "Sample note: always dark." },
      directions: ["Constellation", "Single dot", "Breath"].map((name, i) => ({
        id: ["A", "B", "C"][i],
        name,
        axis: ["Show all nine points", "Only ever one point", "A breathing target"][i],
        pitch: "Sample pitch.",
        cost: "Sample cost.",
        libraries: [lib("motion", "14.14.0", "MIT", "https://motion.dev", "Sample role: the dot’s travel.")],
        skills: sampleSkills,
        perf: perf("0.8%", "0.3 ms/frame", "0.0%"),
        states: ["calibrating", "complete", "camera-marker"].map((s) => ({
          id: s,
          title: { calibrating: "Calibrating", complete: "Complete", "camera-marker": "Camera marker" }[s],
          media: stills("redesign/calibration/" + ["A", "B", "C"][i] + "/" + s, () => calibrationSvg(name, s), ["dark"]),
        })),
      })),
    },
  ],
  scenes: [],
};

writeFileSync(join(out, "manifest.redesign.native.json"), JSON.stringify(native, null, 2) + "\n");
writeFileSync(join(out, "manifest.redesign.tracker.json"), JSON.stringify(tracker, null, 2) + "\n");
console.log("redesign sample written to", out);
