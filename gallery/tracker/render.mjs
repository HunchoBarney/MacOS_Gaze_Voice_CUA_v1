#!/usr/bin/env node
// Renders every EyeTracking (Electron renderer) surface from fixture state for
// the UI gallery. Usage: node gallery/tracker/render.mjs --out <absolute OUT dir>
// See gallery/tracker/README.md. Nothing here runs in CI or touches EyeTracking/.
import { spawn, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, copyFileSync, readdirSync, createWriteStream } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { COMPONENTS, SCENES, PRELUDE, REFERENCE_STATES } from "./scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const ET = path.join(REPO, "EyeTracking");
const VIEW = { width: 1512, height: 982, scale: 2 };
const FRAME_MS = 1000 / 60;

function parseArgs(argv) {
  const args = { only: null, clips: true, workDir: path.join(REPO, "build/gallery-tracker"), refs: path.join(os.homedir(), ".capy/drive/captain-jmos-coding-captain/renders/JARA-55") };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--out") args.out = argv[++i];
    else if (a === "--only") args.only = argv[++i].split(",");
    else if (a === "--no-clips") args.clips = false;
    else if (a === "--work-dir") args.workDir = argv[++i];
    else if (a === "--references") args.refs = argv[++i];
    else if (a === "--chrome") args.chrome = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
    else throw new Error("Unknown argument: " + a);
  }
  return args;
}

const log = (...parts) => console.log("[tracker]", ...parts);

// ---- Sources as file:line, resolved from anchors so they track edits -------
const fileCache = new Map();
function lineOf(rel, needle) {
  if (!fileCache.has(rel)) fileCache.set(rel, readFileSync(path.join(REPO, rel), "utf8").split("\n"));
  const lines = fileCache.get(rel);
  const index = lines.findIndex((line) => line.includes(needle));
  if (index < 0) {
    console.warn("[tracker] anchor not found in " + rel + ": " + needle);
    return rel;
  }
  return rel + ":" + (index + 1);
}

// ---- Build the real renderer with the runtime swapped for the fixture ------
async function buildRenderer(outDir) {
  if (!existsSync(path.join(ET, "node_modules/vite"))) {
    log("EyeTracking/node_modules missing; installing from the lockfile");
    execFileSync("corepack", ["pnpm", "install", "--frozen-lockfile", "--ignore-scripts"], { cwd: ET, stdio: "inherit" });
  }
  const req = createRequire(path.join(ET, "package.json"));
  const vite = await import(pathToFileURL(req.resolve("vite")).href);
  const react = (await import(pathToFileURL(req.resolve("@vitejs/plugin-react")).href)).default;
  const stub = path.join(HERE, "fixture/webRuntime.fixture.js");
  const appPath = path.join(ET, "web/src/App.tsx");
  let aliased = false;
  await vite.build({
    configFile: false,
    root: ET,
    base: "./",
    publicDir: false,
    logLevel: "warn",
    cacheDir: path.join(path.dirname(outDir), "vite-cache"),
    plugins: [
      react(),
      {
        name: "gallery-fixture-web-runtime",
        enforce: "pre",
        resolveId(source, importer) {
          if (importer && path.resolve(importer.split("?")[0]) === appPath && source === "./inference/webRuntime") {
            aliased = true;
            return stub;
          }
          return null;
        }
      }
    ],
    worker: { format: "iife" },
    build: { outDir, emptyOutDir: true, manifest: false, sourcemap: false, reportCompressedSize: false }
  });
  if (!aliased) throw new Error("App.tsx no longer imports ./inference/webRuntime; update the fixture alias");
}

// ---- Static server for the built renderer (loopback, random port) ----------
function serve(root) {
  const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".wasm": "application/wasm", ".json": "application/json" };
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/+/, "") || "index.html";
    const file = path.resolve(root, rel);
    if (!file.startsWith(root) || !existsSync(file)) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
    res.end(readFileSync(file));
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

// ---- Headless Chrome over --remote-debugging-pipe (no network port) --------
function findChrome(explicit) {
  const candidates = [explicit, process.env.CHROME_PATH, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"].filter(Boolean);
  const found = candidates.find((p) => existsSync(p));
  if (!found) throw new Error("Google Chrome not found; pass --chrome <path>");
  return found;
}

function launchChrome(chromePath, profileDir, logFile) {
  const args = [
    "--headless",
    "--remote-debugging-pipe",
    "--user-data-dir=" + profileDir,
    "--use-mock-keychain",
    "--password-store=basic",
    "--use-fake-device-for-media-stream",
    "--deny-permission-prompts",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-sync",
    "--disable-default-apps",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-domain-reliability",
    "--disable-client-side-phishing-detection",
    "--disable-features=MediaRouter,DialMediaRouteProvider,Translate,OptimizationHints,AutofillServerCommunication",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows",
    "--metrics-recording-only",
    "--no-pings",
    "--mute-audio",
    "--hide-scrollbars",
    "--force-color-profile=srgb",
    "--window-size=" + VIEW.width + "," + VIEW.height,
    "about:blank"
  ];
  const child = spawn(chromePath, args, { stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"] });
  child.stderr.pipe(createWriteStream(logFile));
  const writer = child.stdio[3];
  const reader = child.stdio[4];
  let nextId = 1;
  const pending = new Map();
  const handlers = new Map();
  let buffered = Buffer.alloc(0);
  reader.on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    let end;
    while ((end = buffered.indexOf(0)) >= 0) {
      const message = JSON.parse(buffered.subarray(0, end).toString("utf8"));
      buffered = buffered.subarray(end + 1);
      if (message.id && pending.has(message.id)) {
        const { resolve, reject, method } = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) reject(new Error(method + ": " + message.error.message));
        else resolve(message.result);
      } else if (message.method) {
        for (const fn of handlers.get(message.method) || []) fn(message.params, message.sessionId);
      }
    }
  });
  const exited = new Promise((resolve) => child.on("exit", resolve));
  child.on("exit", () => {
    for (const { reject, method } of pending.values()) reject(new Error(method + ": Chrome exited"));
    pending.clear();
  });
  return {
    child,
    exited,
    send(method, params = {}, sessionId) {
      const id = nextId++;
      writer.write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject, method }));
    },
    on(method, fn) {
      if (!handlers.has(method)) handlers.set(method, []);
      handlers.get(method).push(fn);
    }
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function pngSize(buffer) {
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.out) {
    console.log("usage: node gallery/tracker/render.mjs --out <absolute OUT dir> [--only id[/state],...] [--no-clips] [--work-dir dir] [--references dir] [--chrome path]");
    process.exit(args.help ? 0 : 2);
  }
  if (!path.isAbsolute(args.out)) throw new Error("--out must be an absolute path");
  const OUT = args.out;
  mkdirSync(OUT, { recursive: true });
  mkdirSync(args.workDir, { recursive: true });
  const started = Date.now();

  const distDir = path.join(args.workDir, "dist");
  log("building the renderer (vite) into " + distDir);
  await buildRenderer(distDir);

  const server = await serve(distDir);
  const base = "http://127.0.0.1:" + server.address().port + "/index.html";
  const profileDir = mkdtempSync(path.join(args.workDir, "chrome-profile-"));
  const chrome = launchChrome(findChrome(args.chrome), profileDir, path.join(args.workDir, "chrome.log"));
  let failures = [];
  const cleanup = async () => {
    try {
      await chrome.send("Browser.close");
    } catch {}
    const timeout = sleep(3000).then(() => chrome.child.kill("SIGKILL"));
    await Promise.race([chrome.exited, timeout]);
    server.close();
    rmSync(profileDir, { recursive: true, force: true });
  };
  process.on("SIGINT", () => cleanup().then(() => process.exit(130)));

  try {
    const { targetId } = await chrome.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await chrome.send("Target.attachToTarget", { targetId, flatten: true });
    const cdp = (method, params) => chrome.send(method, params, sessionId);
    const pageErrors = [];
    chrome.on("Runtime.exceptionThrown", (p, sid) => {
      if (sid === sessionId) pageErrors.push(p.exceptionDetails.exception?.description || p.exceptionDetails.text);
    });
    const consoleErrors = [];
    chrome.on("Runtime.consoleAPICalled", (p, sid) => {
      if (sid === sessionId && p.type === "error") consoleErrors.push(p.args.map((a) => a.value ?? a.description ?? "").join(" "));
    });
    let loaded = null;
    chrome.on("Page.loadEventFired", (_p, sid) => {
      if (sid === sessionId && loaded) loaded();
    });
    await cdp("Page.enable");
    await cdp("Runtime.enable");
    await cdp("Emulation.setDeviceMetricsOverride", { width: VIEW.width, height: VIEW.height, deviceScaleFactor: VIEW.scale, mobile: false });
    await cdp("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
    await cdp("Page.addScriptToEvaluateOnNewDocument", { source: readFileSync(path.join(HERE, "fixture/bootstrap.js"), "utf8") });

    const evaluate = async (expression) => {
      const result = await cdp("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (result.exceptionDetails) throw new Error("page: " + (result.exceptionDetails.exception?.description || result.exceptionDetails.text));
      return result.result.value;
    };
    const setMedia = (scheme, reduceMotion) =>
      cdp("Emulation.setEmulatedMedia", {
        features: [
          { name: "prefers-color-scheme", value: scheme },
          { name: "prefers-reduced-motion", value: reduceMotion ? "reduce" : "no-preference" }
        ]
      });
    const load = async (params = {}) => {
      pageErrors.length = 0;
      consoleErrors.length = 0;
      const url = base + "?" + new URLSearchParams({ w: String(VIEW.width), h: String(VIEW.height), ...params }).toString();
      const done = new Promise((resolve) => (loaded = resolve));
      await cdp("Page.navigate", { url });
      await Promise.race([done, sleep(20000)]);
      for (let i = 0; i < 400; i += 1) {
        if (await evaluate("Boolean(window.__fx && window.__fx.readyCalled && document.querySelector('main.overlay'))")) break;
        await sleep(25);
      }
      await evaluate("window.__fx.settle()");
      await evaluate(PRELUDE);
    };
    const run = (fn) => evaluate("(" + fn.toString() + ")(window.__fx).then(() => window.__fx.settle()).then(() => window.__fx.sync())");
    const hover = async (selector) => {
      const point = await evaluate("(() => { const r = document.querySelector(" + JSON.stringify(selector) + ").getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()");
      await cdp("Input.dispatchMouseEvent", { type: "mouseMoved", x: point.x, y: point.y });
      await evaluate("window.__fx.advance(250)");
    };
    const shot = async (file, rect, scale = 1) => {
      const clip = rect ? { ...rect, scale } : { x: 0, y: 0, width: VIEW.width, height: VIEW.height, scale };
      const { data } = await cdp("Page.captureScreenshot", { format: "png", clip, captureBeyondViewport: false });
      const buffer = Buffer.from(data, "base64");
      mkdirSync(path.dirname(file), { recursive: true });
      writeFileSync(file, buffer);
      return pngSize(buffer);
    };
    const checkErrors = (label, allow) => {
      const errs = [...pageErrors];
      if (errs.length) throw new Error(label + ": page exception: " + errs.join(" | "));
      if (consoleErrors.length && !allow) throw new Error(label + ": console error: " + consoleErrors.join(" | "));
    };
    const fxErrors = async (label) => {
      const errs = await evaluate("window.__fx.errors.slice()");
      if (errs.length) throw new Error(label + ": callback error: " + errs.join(" | "));
    };
    const rmName = (rm) => (rm ? "reduced" : "motion");
    const wanted = (componentId, stateId) =>
      !args.only || args.only.some((o) => o === componentId || o === componentId + "/" + stateId || (stateId === undefined && o.startsWith(componentId + "/")));

    const manifest = {
      producer: "tracker",
      commit: execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: REPO }).toString().trim(),
      generatedAt: new Date().toISOString(),
      components: [],
      scenes: []
    };
    let shots = 0;

    for (const component of COMPONENTS) {
      if (!wanted(component.id)) continue;
      const entry = {
        id: component.id,
        title: component.title,
        area: component.area,
        summary: component.summary,
        sources: component.sources.map(([rel, needle]) => lineOf(rel, needle)),
        owner: component.owner,
        states: []
      };
      for (const state of component.states) {
        if (!wanted(component.id, state.id)) continue;
        const label = component.id + "/" + state.id;
        const stateEntry = { id: state.id, title: state.title, note: state.note, kind: "current", variants: [], clips: [] };
        try {
          for (const rm of [false, true]) {
            await setMedia("dark", rm);
            await load(state.params);
            await run(state.run);
            if (state.hover) await hover(state.hover);
            checkErrors(label, state.allowConsoleErrors);
            await fxErrors(label);
            let crop = null;
            if (state.crop) {
              crop = state.crop.rect || (await evaluate("window.__fx.rectOf(" + JSON.stringify(state.crop.selectors) + ", " + (state.crop.pad ?? 24) + ")"));
              if (!crop) throw new Error(label + ": nothing to crop (" + state.crop.selectors.join(", ") + " not rendered)");
            }
            if (state.expect) {
              const ok = await evaluate("Boolean(document.querySelector(" + JSON.stringify(state.expect) + "))");
              if (!ok) throw new Error(label + ": expected " + state.expect + " to be rendered");
            }
            for (const scheme of ["light", "dark"]) {
              await setMedia(scheme, rm);
              for (const backdrop of ["transparent", "desktop"]) {
                await evaluate("window.__fx.setBackdrop(" + JSON.stringify(backdrop) + ")");
                const rel = component.id + "/" + state.id + "." + scheme + "." + rmName(rm) + "." + backdrop + ".png";
                const rect = backdrop === "transparent" ? crop : null;
                const size = await shot(path.join(OUT, rel), rect);
                shots += 1;
                stateEntry.variants.push({ scheme, reduceMotion: rm, image: rel, width: size.width, height: size.height, scale: VIEW.scale, backdrop });
              }
            }
          }
          if (state.clip && args.clips) {
            for (const rm of [false, true]) {
              await setMedia("dark", rm);
              await load(state.clip.params ?? state.params);
              await run(state.clip.run);
              await evaluate("window.__fx.setBackdrop('desktop')");
              const t0 = await evaluate("window.__fx.now");
              const frames = Math.round((state.clip.durationMs / 1000) * 60);
              const scale = state.clip.scale ?? 1;
              const names = {};
              const schemes = state.clip.rect ? ["light", "dark"] : ["dark"];
              for (const scheme of schemes) {
                names[scheme] = component.id + "/" + state.id + "." + scheme + "." + rmName(rm);
                rmSync(path.join(OUT, names[scheme] + ".frames"), { recursive: true, force: true });
              }
              let size = null;
              for (let i = 0; i < frames; i += 1) {
                await evaluate("window.__fx.advanceTo(" + (t0 + i * FRAME_MS) + ")");
                for (const scheme of schemes) {
                  await setMedia(scheme, rm);
                  size = await shot(path.join(OUT, names[scheme] + ".frames", String(i).padStart(4, "0") + ".png"), state.clip.rect, scale);
                  shots += 1;
                }
              }
              checkErrors(label + " clip", state.allowConsoleErrors);
              await fxErrors(label + " clip");
              for (const scheme of schemes) {
                writeFileSync(path.join(OUT, names[scheme] + ".frames", "clip.json"), JSON.stringify({ fps: 60 }) + "\n");
                stateEntry.clips.push({
                  scheme,
                  reduceMotion: rm,
                  video: names[scheme] + ".mp4",
                  poster: names[scheme] + ".poster.png",
                  width: size.width,
                  height: size.height,
                  durationMs: Math.round((frames * 1000) / 60),
                  caption: state.clip.caption
                });
              }
            }
          }
          if (!stateEntry.clips.length) delete stateEntry.clips;
          if (!stateEntry.note) delete stateEntry.note;
          entry.states.push(stateEntry);
          log("rendered " + label + " (" + stateEntry.variants.length + " stills" + (stateEntry.clips ? ", " + stateEntry.clips.length + " clips" : "") + ")");
        } catch (error) {
          failures.push(String(error.message || error));
          console.error("[tracker] FAILED " + label + ": " + (error.message || error));
        }
      }
      for (const ref of REFERENCE_STATES.filter((r) => r.component === component.id)) {
        const refEntry = copyReference(ref, args.refs, OUT);
        if (refEntry) entry.states.push(refEntry);
      }
      if (entry.states.length) manifest.components.push(entry);
    }

    // JARA-55's own direction renders, as a reference component.
    const orbRefs = REFERENCE_STATES.filter((r) => r.component === "gaze-orb-directions");
    if (wanted("gaze-orb-directions") && orbRefs.length) {
      const states = orbRefs.map((ref) => copyReference(ref, args.refs, OUT)).filter(Boolean);
      if (states.length) {
        manifest.components.push({
          id: "gaze-orb-directions",
          title: "Gaze orb directions",
          area: "Gaze",
          summary: "JARA-55's three orb directions for the gaze highlight (Magnet, Lantern, Aura); the owner picked Magnet.",
          sources: ["renders/JARA-55/gaze-orb-prototype.html (captain drive)", "reports/JARA-55-diagnosis.md (captain drive)"],
          owner: "JARA-55",
          states
        });
      }
    }

    for (const scene of SCENES) {
      if (!wanted(scene.id)) continue;
      try {
        await setMedia("dark", false);
        await load(scene.params);
        await run(scene.run);
        checkErrors(scene.id, scene.allowConsoleErrors);
        await fxErrors(scene.id);
        await evaluate("window.__fx.setBackdrop('desktop')");
        const rel = "tracker-scenes/" + scene.id + ".png";
        const size = await shot(path.join(OUT, rel), null);
        shots += 1;
        manifest.scenes.push({ id: scene.id, title: scene.title, summary: scene.summary, components: scene.components, image: rel, width: size.width, height: size.height, kind: "current" });
        log("rendered scene " + scene.id);
      } catch (error) {
        failures.push(String(error.message || error));
        console.error("[tracker] FAILED scene " + scene.id + ": " + (error.message || error));
      }
    }
    if (!manifest.scenes.length) delete manifest.scenes;

    const manifestPath = path.join(OUT, "manifest.tracker.json");
    if (args.only && existsSync(manifestPath)) {
      log("--only: leaving the existing manifest.tracker.json alone; partial manifest at manifest.tracker.partial.json");
      writeFileSync(path.join(OUT, "manifest.tracker.partial.json"), JSON.stringify(manifest, null, 2) + "\n");
    } else {
      writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
    }
    log(shots + " screenshots in " + Math.round((Date.now() - started) / 1000) + " s; manifest: " + manifestPath);
  } finally {
    await cleanup();
  }
  if (failures.length) {
    console.error("[tracker] " + failures.length + " failure(s)");
    process.exit(1);
  }
}

function copyReference(ref, refsDir, OUT) {
  const source = path.join(refsDir, ref.file);
  if (!existsSync(source)) {
    console.warn("[tracker] reference render missing, skipped: " + source);
    return null;
  }
  const rel = ref.component + "/reference-" + ref.file;
  mkdirSync(path.join(OUT, ref.component), { recursive: true });
  copyFileSync(source, path.join(OUT, rel));
  const size = pngSize(readFileSync(source));
  // A reference is one fixed render, so both appearances point at the same file.
  return {
    id: ref.id,
    title: ref.title,
    note: ref.note,
    kind: "reference",
    variants: ["light", "dark"].map((scheme) => ({ scheme, reduceMotion: false, image: rel, width: size.width, height: size.height, scale: 1, backdrop: "desktop" }))
  };
}

main().catch((error) => {
  console.error("[tracker] " + (error.stack || error));
  process.exit(1);
});
