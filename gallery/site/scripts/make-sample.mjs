#!/usr/bin/env node
// Generates the tiny fixture render set in sample/renders (SVG placeholders) plus sample/findings.json.
// Fixture data only: every string here is invented.
import { copyFileSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "sample");
const out = join(root, "renders");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif";
const pal = {
  dark: { panel: "#1c1c1ee8", stroke: "#ffffff1f", text: "#f5f5f7", sub: "#a1a1a6", fill: "#2c2c2e", win: "#1e1e20", winBar: "#2a2a2c" },
  light: { panel: "#ffffffeb", stroke: "#0000001a", text: "#1d1d1f", sub: "#6e6e73", fill: "#f2f2f4", win: "#ffffff", winBar: "#ececee" },
};

function svg(w, h, scale, body) {
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + w * scale + '" height="' + h * scale + '" viewBox="0 0 ' + w + " " + h + '" font-family="' + FONT + '">' + body + "</svg>\n";
}
function write(rel, content) {
  const p = join(out, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, content);
  return rel;
}
const shadow = '<defs><filter id="s" x="-30%" y="-30%" width="160%" height="180%"><feDropShadow dx="0" dy="6" stdDeviation="8" flood-opacity="0.28"/></filter></defs>';
const wallpaper = (w, h, id = "wp") =>
  '<defs><linearGradient id="' + id + '" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1b2a4a"/><stop offset="0.55" stop-color="#3b3f73"/><stop offset="1" stop-color="#b0698a"/></linearGradient></defs><rect width="' + w + '" height="' + h + '" fill="url(#' + id + ')"/>';

function bars(x, y, c, rm, n = 5) {
  const hs = rm ? [8, 8, 8, 8, 8, 8] : [8, 16, 22, 14, 18, 10];
  let s = "";
  for (let i = 0; i < n; i++) s += '<rect x="' + (x + i * 6) + '" y="' + (y - hs[i] / 2) + '" width="3" height="' + hs[i] + '" rx="1.5" fill="' + c + '"/>';
  return s;
}

const indicator = (kind) => (scheme, rm) => {
  const p = pal[scheme];
  const W = 260, H = 84;
  const tint = { listening: "#0a84ff", thinking: "#bf5af2", speaking: "#30d158", problem: "#ff453a", proposed: "#64d2ff" }[kind];
  let b = shadow;
  if (kind === "problem") {
    b += '<g filter="url(#s)"><rect x="20" y="10" width="220" height="60" rx="16" fill="' + p.panel + '" stroke="' + p.stroke + '"/></g>';
    b += '<circle cx="46" cy="40" r="11" fill="' + tint + '"/><text x="46" y="44.5" fill="#fff" font-size="13" font-weight="700" text-anchor="middle">!</text>';
    b += '<text x="66" y="36" fill="' + p.text + '" font-size="13" font-weight="600">Can\u2019t hear you</text>';
    b += '<text x="66" y="54" fill="' + p.sub + '" font-size="11.5">Sample input device is muted</text>';
    return svg(W, H, 2, b);
  }
  if (kind === "proposed") {
    b += '<g filter="url(#s)"><rect x="80" y="22" width="100" height="40" rx="20" fill="' + p.panel + '" stroke="' + p.stroke + '"/></g>';
    if (!rm) b += '<circle cx="104" cy="42" r="12" fill="' + tint + '" opacity="0.22"/>';
    b += '<circle cx="104" cy="42" r="7" fill="' + tint + '"/>' + bars(122, 42, p.text, rm, 6);
    return svg(W, H, 2, b);
  }
  const label = { listening: "Listening", thinking: "Thinking", speaking: "Speaking" }[kind];
  b += '<g filter="url(#s)"><rect x="40" y="20" width="180" height="44" rx="22" fill="' + p.panel + '" stroke="' + p.stroke + '"/></g>';
  b += '<circle cx="64" cy="42" r="8" fill="' + tint + '"/>';
  if (kind === "thinking") b += [0, 1, 2].map((i) => '<circle cx="' + (84 + i * 9) + '" cy="42" r="2.6" fill="' + p.sub + '" opacity="' + (rm ? 0.8 : 0.4 + i * 0.25) + '"/>').join("");
  else b += bars(80, 42, tint, rm);
  b += '<text x="120" y="46.5" fill="' + p.text + '" font-size="13.5" font-weight="500">' + label + "</text>";
  return svg(W, H, 2, b);
};

const callout = (done) => (scheme) => {
  const p = pal[scheme];
  let b = shadow + '<g filter="url(#s)"><path d="M24 22 h268 a14 14 0 0 1 14 14 v76 a14 14 0 0 1 -14 14 h-268 a14 14 0 0 1 -14 -14 v-76 a14 14 0 0 1 14 -14 z M282 22 l10 -12 l10 12 z" fill="' + p.panel + '" stroke="' + p.stroke + '"/></g>';
  if (done) {
    b += '<circle cx="42" cy="56" r="11" fill="#30d158"/><path d="M37 56 l3.5 3.5 l6.5 -7" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round"/>';
    b += '<text x="62" y="60" fill="' + p.text + '" font-size="14" font-weight="600">Shared. Nice.</text>';
    b += '<text x="30" y="96" fill="' + p.sub + '" font-size="12">Step 3 of 3</text>';
  } else {
    b += '<text x="30" y="52" fill="' + p.text + '" font-size="14" font-weight="600">Click Share</text>';
    b += '<text x="30" y="72" fill="' + p.sub + '" font-size="12.5">It\u2019s the square with the arrow, top right.</text>';
    b += '<text x="30" y="104" fill="' + p.sub + '" font-size="12">Step 2 of 3</text>';
    b += '<rect x="226" y="88" width="66" height="24" rx="7" fill="' + p.fill + '"/><text x="259" y="104" fill="' + p.text + '" font-size="12" font-weight="500" text-anchor="middle">Skip</text>';
  }
  return svg(320, 136, 2, b);
};

const shelf = (names) => (scheme) => {
  const p = pal[scheme];
  let b = shadow, x = 12;
  const prog = [0.7, 0.35, 1];
  names.forEach((n, i) => {
    const w = 34 + n.length * 7.2;
    b += '<g filter="url(#s)"><rect x="' + x + '" y="16" width="' + w + '" height="32" rx="16" fill="' + p.panel + '" stroke="' + p.stroke + '"/></g>';
    const r = 7, c = 2 * Math.PI * r;
    b += '<circle cx="' + (x + 18) + '" cy="32" r="' + r + '" fill="none" stroke="' + p.stroke + '" stroke-width="2.2"/>';
    b += '<circle cx="' + (x + 18) + '" cy="32" r="' + r + '" fill="none" stroke="#0a84ff" stroke-width="2.2" stroke-dasharray="' + c * prog[i] + " " + c + '" transform="rotate(-90 ' + (x + 18) + ' 32)" stroke-linecap="round"/>';
    b += '<text x="' + (x + 31) + '" y="36.5" fill="' + p.text + '" font-size="12.5" font-weight="500">' + n + "</text>";
    x += w + 8;
  });
  return svg(Math.ceil(x + 4), 64, 2, b);
};

const menubar = (pending) => (scheme) => {
  const dark = scheme === "dark";
  const fg = dark ? "#ffffff" : "#000000d9";
  let b = '<defs><linearGradient id="mb" x1="0" x2="1"><stop offset="0" stop-color="' + (dark ? "#26304d" : "#c9d6f2") + '"/><stop offset="1" stop-color="' + (dark ? "#4a3a5e" : "#e8cfe0") + '"/></linearGradient></defs>';
  b += '<rect width="360" height="28" fill="url(#mb)"/><rect width="360" height="28" fill="' + (dark ? "#00000033" : "#ffffff59") + '"/>';
  b += '<g transform="translate(172 14)">' + [6, 11, 15, 9, 5].map((h, i) => '<rect x="' + (i * 3.4 - 8) + '" y="' + -h / 2 + '" width="2" height="' + h + '" rx="1" fill="' + fg + '"/>').join("") + "</g>";
  if (pending) b += '<text x="183" y="18.5" fill="' + fg + '" font-size="13" font-weight="500">\u00b7' + pending + "</text>";
  b += '<rect x="214" y="9" width="20" height="10" rx="2.5" fill="none" stroke="' + fg + '" stroke-width="1.2"/><rect x="216" y="11" width="13" height="6" rx="1.2" fill="' + fg + '"/>';
  b += '<text x="350" y="18.5" fill="' + fg + '" font-size="13" font-weight="500" text-anchor="end">Thu 9:41</text>';
  return svg(360, 28, 2, b);
};

function windowFrame(p, w, h, title, inner) {
  let b = shadow + '<g filter="url(#s)"><rect x="0.5" y="0.5" width="' + (w - 1) + '" height="' + (h - 1) + '" rx="12" fill="' + p.win + '" stroke="' + p.stroke + '"/></g>';
  b += ["#ff5f57", "#febc2e", "#28c840"].map((c, i) => '<circle cx="' + (20 + i * 20) + '" cy="20" r="6" fill="' + c + '"/>').join("");
  if (title) b += '<text x="' + w / 2 + '" y="24" fill="' + p.sub + '" font-size="13" font-weight="600" text-anchor="middle">' + title + "</text>";
  return b + inner;
}

const firstRun = (step) => (scheme) => {
  const p = pal[scheme];
  let inner = "";
  if (step === "welcome") {
    inner += '<circle cx="280" cy="120" r="34" fill="#0a84ff" opacity="0.16"/><circle cx="280" cy="120" r="20" fill="#0a84ff"/>';
    inner += '<text x="280" y="196" fill="' + p.text + '" font-size="26" font-weight="700" text-anchor="middle" letter-spacing="-0.5">Welcome to Jarvis</text>';
    inner += '<text x="280" y="226" fill="' + p.sub + '" font-size="14" text-anchor="middle">Say the wake phrase, then just talk.</text>';
    inner += '<rect x="220" y="290" width="120" height="36" rx="10" fill="#0a84ff"/><text x="280" y="313" fill="#fff" font-size="14" font-weight="600" text-anchor="middle">Continue</text>';
  } else {
    inner += '<text x="40" y="84" fill="' + p.text + '" font-size="22" font-weight="700" letter-spacing="-0.4">How should Jarvis listen?</text>';
    [["Wake phrase", "Listens on this Mac for its name.", true], ["Off for now", "Turn listening on later in Settings.", false]].forEach(([t, s, on], i) => {
      const y = 112 + i * 84;
      inner += '<rect x="40" y="' + y + '" width="480" height="70" rx="12" fill="' + p.fill + '" stroke="' + (on ? "#0a84ff" : p.stroke) + '" stroke-width="' + (on ? 2 : 1) + '"/>';
      inner += '<circle cx="68" cy="' + (y + 35) + '" r="8" fill="none" stroke="' + (on ? "#0a84ff" : p.sub) + '" stroke-width="2"/>' + (on ? '<circle cx="68" cy="' + (y + 35) + '" r="4" fill="#0a84ff"/>' : "");
      inner += '<text x="90" y="' + (y + 31) + '" fill="' + p.text + '" font-size="15" font-weight="600">' + t + '</text><text x="90" y="' + (y + 51) + '" fill="' + p.sub + '" font-size="13">' + s + "</text>";
    });
    inner += '<rect x="400" y="300" width="120" height="36" rx="10" fill="#0a84ff"/><text x="460" y="323" fill="#fff" font-size="14" font-weight="600" text-anchor="middle">Continue</text>';
  }
  return svg(560, 360, 2, windowFrame(p, 560, 360, "", inner));
};

const calibration = (done) => () => {
  let b = '<rect width="640" height="400" fill="#050506"/>';
  const pts = [];
  for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) pts.push([80 + c * 240, 60 + r * 140]);
  pts.forEach(([x, y], i) => {
    const active = !done && i === 4, seen = done || i < 4;
    if (active) b += '<circle cx="' + x + '" cy="' + y + '" r="22" fill="#64d2ff" opacity="0.18"/>';
    b += '<circle cx="' + x + '" cy="' + y + '" r="' + (active ? 9 : 5) + '" fill="' + (active ? "#64d2ff" : seen ? "#ffffff8c" : "#ffffff2e") + '"/>';
  });
  b += '<text x="320" y="380" fill="#a1a1a6" font-size="13" text-anchor="middle">' + (done ? "Calibrated \u00b7 average error 1.4\u00b0" : "Look at the dot \u00b7 5 of 9") + "</text>";
  return svg(640, 400, 2, b);
};

const target = () => (scheme) => {
  const p = pal[scheme];
  let b = wallpaper(420, 240, "tw") + '<g transform="translate(40 30)">' + windowFrame(p, 340, 180, "Mail", "") + "</g>";
  b += '<rect x="292" y="90" width="64" height="28" rx="7" fill="#0a84ff"/><text x="324" y="108.5" fill="#fff" font-size="13" font-weight="600" text-anchor="middle">Send</text>';
  b += '<rect x="80" y="96" width="180" height="8" rx="4" fill="' + p.fill + '"/><rect x="80" y="114" width="140" height="8" rx="4" fill="' + p.fill + '"/>';
  b += '<rect x="286" y="84" width="76" height="40" rx="11" fill="none" stroke="#ffd60a" stroke-width="2.5"/>';
  b += '<rect x="290" y="134" width="68" height="22" rx="11" fill="#000000b3"/><text x="324" y="149" fill="#fff" font-size="11.5" font-weight="600" text-anchor="middle">Target</text>';
  return svg(420, 240, 2, b);
};

// sample/clips holds a 2.4 s fixture clip recorded once from a canvas in headless Chrome (MediaRecorder, H.264).
function listeningClip() {
  mkdirSync(join(out, "listening-indicator"), { recursive: true });
  for (const name of ["listening.dark.mp4", "listening.dark.poster.png"]) copyFileSync(join(root, "clips", name), join(out, "listening-indicator", name));
  return {
    scheme: "dark",
    reduceMotion: false,
    video: "listening-indicator/listening.dark.mp4",
    poster: "listening-indicator/listening.dark.poster.png",
    width: 520,
    height: 168,
    durationMs: 2400,
    caption: "Level meter and orb pulse while listening (fixture clip).",
  };
}

const schemes = ["dark", "light"];
function variants(id, stateId, make, opts = {}) {
  const list = [];
  for (const scheme of schemes) for (const rm of [false, true]) {
    if (opts.noRm && rm) continue;
    const content = make(scheme, rm);
    const m = content.match(/width="(\d+(?:\.\d+)?)" height="(\d+(?:\.\d+)?)"/);
    const rel = write(id + "/" + stateId + "." + scheme + (rm ? ".rm" : "") + ".svg", content);
    list.push({ scheme, reduceMotion: rm, image: rel, width: Math.round(+m[1]), height: Math.round(+m[2]), scale: 2, backdrop: opts.backdrop ?? "transparent" });
  }
  return list;
}

const native = {
  producer: "native",
  commit: "sample",
  generatedAt: "2026-11-20T00:00:00Z",
  components: [
    {
      id: "listening-indicator",
      title: "Listening indicator",
      area: "Voice",
      summary: "The capsule at the top of the screen that shows Jarvis is listening, thinking or speaking.",
      sources: ["Sources/Jarvis/UI/ListeningIndicator.swift:65", "Sources/Jarvis/UI/ListeningIndicator.swift:170"],
      owner: "JARA-55",
      states: [
        { id: "listening", title: "Listening", variants: variants("listening-indicator", "listening", indicator("listening")), clips: [listeningClip()] },
        { id: "thinking", title: "Thinking", variants: variants("listening-indicator", "thinking", indicator("thinking")) },
        { id: "speaking", title: "Speaking", variants: variants("listening-indicator", "speaking", indicator("speaking")) },
        { id: "problem", title: "Problem", note: "Shown when the input device stops delivering audio.", variants: variants("listening-indicator", "problem", indicator("problem")) },
        { id: "listening-proposed", title: "Listening", kind: "proposed", note: "Label dropped; the orb and level carry the state.", variants: variants("listening-indicator", "listening-proposed", indicator("proposed")) },
      ],
    },
    {
      id: "guide-callout",
      title: "Guide callout",
      area: "Guide",
      summary: "A pointer card that walks the person through a task in another app, one step at a time.",
      sources: ["Sources/Jarvis/UI/GuideCallout.swift:121"],
      states: [
        { id: "pointing", title: "Pointing", variants: variants("guide-callout", "pointing", callout(false), { noRm: false }) },
        { id: "done", title: "Done", variants: variants("guide-callout", "done", callout(true)) },
      ],
    },
    {
      id: "agent-shelf",
      title: "Agent shelf",
      area: "Agents",
      summary: "Chips along the bottom edge for background agents, each with its progress.",
      sources: ["Sources/Jarvis/UI/AgentShelfOverlay.swift:15", "Sources/Jarvis/UI/AgentShelfOverlay.swift:118"],
      states: [
        { id: "one", title: "One agent", variants: variants("agent-shelf", "one", shelf(["Inbox triage"])) },
        { id: "three", title: "Three agents", variants: variants("agent-shelf", "three", shelf(["Inbox triage", "Draft reply", "Calendar check"])) },
      ],
    },
    {
      id: "menu-bar-item",
      title: "Menu bar item",
      area: "Menu bar",
      summary: "The waveform in the menu bar; a dot and count appear when tasks wait for consent.",
      sources: ["Sources/Jarvis/main.swift:58", "Sources/Jarvis/main.swift:593"],
      states: [
        { id: "idle", title: "Idle", variants: variants("menu-bar-item", "idle", menubar(0), { backdrop: "desktop" }) },
        { id: "pending", title: "Pending consent", variants: variants("menu-bar-item", "pending", menubar(2), { backdrop: "desktop" }) },
      ],
    },
    {
      id: "first-run",
      title: "First run",
      area: "Onboarding",
      summary: "The welcome window that sets up listening the first time Jarvis opens.",
      sources: ["Sources/Jarvis/UI/FirstRun.swift:99", "Sources/Jarvis/UI/FirstRun.swift:259"],
      states: [
        { id: "welcome", title: "Welcome", variants: variants("first-run", "welcome", firstRun("welcome"), { backdrop: "window" }) },
        { id: "listening-choice", title: "Listening choice", variants: variants("first-run", "listening-choice", firstRun("choice"), { backdrop: "window" }) },
      ],
    },
    {
      id: "target-overlay",
      title: "Target overlay",
      area: "Gaze",
      summary: "A ring around the control Jarvis is about to act on, so the person can see the target first.",
      sources: ["Sources/Jarvis/UI/TargetOverlay.swift:19"],
      states: [{ id: "targeting", title: "Targeting", variants: variants("target-overlay", "targeting", target(), { backdrop: "desktop" }) }],
    },
  ],
  scenes: [],
};

const tracker = {
  producer: "tracker",
  commit: "sample",
  generatedAt: "2026-11-20T00:00:00Z",
  components: [
    {
      id: "tracker-calibration",
      title: "Calibration",
      area: "Eye tracker",
      summary: "The nine-point calibration the optional eye tracker runs before gaze is used.",
      sources: ["EyeTracking/web/calibration.ts:1"],
      states: [
        { id: "calibrating", title: "Calibrating", note: "Always dark; ignores the system scheme.", variants: variants("tracker-calibration", "calibrating", calibration(false), { backdrop: "window", noRm: true }) },
        { id: "complete", title: "Complete", note: "Always dark; ignores the system scheme.", variants: variants("tracker-calibration", "complete", calibration(true), { backdrop: "window", noRm: true }) },
      ],
    },
  ],
};

function scene(id, title, summary, components, kind, draw) {
  const W = 1440, H = 900;
  let b = wallpaper(W, H, "sw") + '<rect width="' + W + '" height="26" fill="#00000040"/>';
  b += '<text x="20" y="18" fill="#fff" font-size="13" font-weight="600">Notes</text>';
  b += '<g transform="translate(' + (W - 270) + ' 13)">' + [6, 11, 15, 9, 5].map((h, i) => '<rect x="' + (i * 3.4 - 8) + '" y="' + -h / 2 + '" width="2" height="' + h + '" rx="1" fill="#fff"/>').join("") + "</g>";
  b += '<text x="' + (W - 16) + '" y="18" fill="#fff" font-size="13" font-weight="500" text-anchor="end">Thu 9:41</text>';
  const p = pal.dark;
  let lines = "";
  for (let i = 0; i < 9; i++) lines += '<rect x="40" y="' + (90 + i * 30) + '" width="' + (520 - (i % 3) * 90) + '" height="10" rx="5" fill="' + p.fill + '"/>';
  b += '<g transform="translate(260 140)">' + windowFrame(p, 760, 520, "Sample notes", '<text x="40" y="70" fill="' + p.text + '" font-size="22" font-weight="700">Launch checklist</text>' + lines) + "</g>";
  b += draw();
  const rel = write("scenes/" + id + ".svg", svg(W, H, 2, b));
  return { id, title, summary, components, image: rel, width: W * 2, height: H * 2, kind };
}
const inner = (s) => s.replace(/^<svg[^>]*>/, "").replace(/<\/svg>\n$/, "");
native.scenes.push(
  scene("desk-listening", "Listening at the desk", "The indicator over a document while two agents run in the shelf.", ["listening-indicator", "agent-shelf", "menu-bar-item"], "current", () =>
    '<g transform="translate(590 34)">' + inner(indicator("listening")("dark", false)) + "</g>" +
    '<g transform="translate(860 820)">' + inner(shelf(["Inbox triage", "Draft reply"])("dark")) + "</g>"),
  scene("guide-share", "Guide pointing at Share", "A guide step pointing at a toolbar button in a document window.", ["guide-callout", "target-overlay"], "current", () =>
    '<rect x="944" y="146" width="36" height="24" rx="6" fill="none" stroke="#ffd60a" stroke-width="2.5"/>' +
    '<g transform="translate(672 168)">' + inner(callout(false)("dark")) + "</g>"),
  scene("desk-listening-proposed", "Listening at the desk, proposed", "The same moment with the compact indicator from LI-1.", ["listening-indicator", "agent-shelf"], "proposed", () =>
    '<g transform="translate(590 34)">' + inner(indicator("proposed")("dark", false)) + "</g>" +
    '<g transform="translate(860 820)">' + inner(shelf(["Inbox triage", "Draft reply"])("dark")) + "</g>"),
);

writeFileSync(join(out, "manifest.native.json"), JSON.stringify(native, null, 2) + "\n");
writeFileSync(join(out, "manifest.tracker.json"), JSON.stringify(tracker, null, 2) + "\n");

const findings = {
  generatedAt: "2026-11-20T00:00:00Z",
  skills: ["emil-design-eng", "apple-design", "animate", "choreograph", "gestures", "find-animation-opportunities", "animate-expo", "break-ui"],
  findings: [
    { id: "LI-1", component: "listening-indicator", severity: "P1", title: "Label repeats what the orb already says", where: "Sources/Jarvis/UI/ListeningIndicator.swift:65", problem: "Sample finding. The word Listening sits beside an orb whose colour and level already carry the state, so the capsule is twice as wide as it needs to be over the person's work.", fix: "Drop the label from steady states, keep it for Problem, and let the orb and level meter carry the state. VoiceOver keeps the label.", library: "Orb (metasidd), SwiftUI", skills: ["emil-design-eng", "apple-design"], proposedState: "listening-proposed" },
    { id: "LI-2", component: "listening-indicator", severity: "P2", title: "Level bars animate under Reduce Motion", where: "Sources/Jarvis/UI/ListeningIndicator.swift:146", problem: "Sample finding. The bars keep bouncing when Reduce Motion is on, which is high-frequency motion the person asked to avoid.", fix: "Under Reduce Motion, show a static level and crossfade between states in 150 ms.", skills: ["remove-animations", "apple-design"] },
    { id: "LI-3", component: "listening-indicator", severity: "P0", title: "Problem card can cover the menu bar", where: "Sources/Jarvis/UI/ListeningIndicator.swift:170", problem: "Sample finding. On a 13-inch display the card's top edge overlaps the menu bar when the notch is present.", fix: "Anchor the card below NSScreen.safeAreaInsets.top plus 8 pt.", library: "native API: NSScreen.safeAreaInsets", skills: ["break-ui"] },
    { id: "GC-1", component: "guide-callout", severity: "P2", title: "Callout scales in from its centre", where: "Sources/Jarvis/UI/GuideCallout.swift:121", problem: "Sample finding. The card grows from its own centre, so it doesn't read as coming from the control it points at.", fix: "Set the anchor point to the arrow tip and enter from scale 0.96 plus opacity over 200 ms ease-out.", skills: ["animate", "emil-design-eng"] },
    { id: "AS-1", component: "agent-shelf", severity: "P3", title: "Chips enter all at once", where: "Sources/Jarvis/UI/AgentShelfOverlay.swift:118", problem: "Sample finding. When several agents start together the chips pop in on the same frame.", fix: "One entrance for the shelf; new chips after the first slide in 40 ms apart with the siblings closing the gap.", skills: ["choreograph"] },
    { id: "MB-1", component: "menu-bar-item", severity: "P3", title: "Pending count uses a middle dot", where: "Sources/Jarvis/main.swift:593", problem: "Sample finding. A dot and number in the title is easy to miss and reads as a separator.", fix: "Use a badge drawn into the template image so it inverts with the menu bar.", library: "native API: NSImage template", skills: ["apple-design"] },
    { id: "TC-1", component: "tracker-calibration", severity: "P2", title: "Active dot has no lead-in", where: "EyeTracking/web/calibration.ts:1", problem: "Sample finding. The next dot appears instantly, so the eye has to search for it.", fix: "Travel the dot to the next point over 250 ms with a critically damped spring, then pulse once.", library: "motion", skills: ["animate", "gestures"] },
  ],
};
writeFileSync(join(root, "findings.json"), JSON.stringify(findings, null, 2) + "\n");
console.log("sample written to", out);
