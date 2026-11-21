#!/usr/bin/env node
// Renders the three calibration directions (gallery/redesign/tracker) in
// headless Chrome on the gallery's manual clock, measures each one's cost, and
// writes manifest.redesign.tracker.json. See README.md.
//
//   node gallery/redesign/tracker/render.mjs --out /absolute/OUT
//
// Chrome launch, the static server and the manual clock come from
// gallery/tracker (render.mjs and fixture/bootstrap.js, read unmodified).
import { spawn, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import { existsSync, linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, createWriteStream, statSync, readdirSync } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DIRECTIONS, COMPONENT } from "./directions.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");
const VIEW = { width: 1512, height: 982, scale: 2 };
const FRAME_MS = 1000 / 60;
const VARIANTS = ["dark", "light", "dark-rm", "light-rm"];
const log = (...parts) => console.log("[calibration]", ...parts);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parseArgs(argv) {
  const args = { only: null, states: null, clips: true, perf: true, stills: true, clipVariants: ["dark", "light", "dark-rm"], clipScale: 0.5, workDir: path.join(REPO, "build/gallery-redesign-tracker") };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--out") args.out = argv[++i];
    else if (a === "--only") args.only = argv[++i].split(",");
    else if (a === "--states") args.states = argv[++i].split(",");
    else if (a === "--no-clips") args.clips = false;
    else if (a === "--no-perf") args.perf = false;
    else if (a === "--no-stills") args.stills = false;
    else if (a === "--clip-variants") args.clipVariants = argv[++i].split(",");
    else if (a === "--clip-scale") args.clipScale = Number(argv[++i]);
    else if (a === "--work-dir") args.workDir = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
    else throw new Error("Unknown argument: " + a);
  }
  return args;
}

// ---- Build the prototype with its own pinned packages ----------------------
async function build(outDir) {
  if (!existsSync(path.join(HERE, "node_modules/vite"))) {
    log("node_modules missing; installing from the lockfile");
    execFileSync("corepack", ["pnpm", "install", "--frozen-lockfile", "--ignore-scripts"], { cwd: HERE, stdio: "inherit" });
  }
  const req = createRequire(path.join(HERE, "package.json"));
  const vite = await import(pathToFileURL(req.resolve("vite")).href);
  const react = (await import(pathToFileURL(req.resolve("@vitejs/plugin-react")).href)).default;
  await vite.build({
    configFile: false,
    root: HERE,
    base: "./",
    publicDir: false,
    logLevel: "warn",
    cacheDir: path.join(path.dirname(outDir), "vite-cache"),
    plugins: [react()],
    build: { outDir, emptyOutDir: true, sourcemap: false, reportCompressedSize: false }
  });
}

// ---- Static server (loopback, random port), as gallery/tracker/render.mjs --
function serve(dir) {
  const root = path.resolve(dir);
  const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".wasm": "application/wasm", ".json": "application/json" };
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/+/, "") || "index.html";
    const file = path.resolve(root, rel);
    if ((file !== root && !file.startsWith(root + path.sep)) || !existsSync(file) || statSync(file).isDirectory()) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
    res.end(readFileSync(file));
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

// ---- Headless Chrome over --remote-debugging-pipe, throwaway profile -------
function findChrome() {
  const candidates = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"];
  const found = candidates.find((p) => existsSync(p));
  if (!found) throw new Error("Google Chrome not found at " + candidates.join(", "));
  return found;
}

function launchChrome(chromePath, profileDir, logFile) {
  const args = [
    "--headless", "--remote-debugging-pipe", "--user-data-dir=" + profileDir, "--use-mock-keychain", "--password-store=basic",
    "--use-fake-device-for-media-stream", "--deny-permission-prompts", "--no-first-run", "--no-default-browser-check",
    "--disable-extensions", "--disable-sync", "--disable-default-apps", "--disable-background-networking", "--disable-component-update",
    "--disable-domain-reliability", "--disable-client-side-phishing-detection",
    "--disable-features=MediaRouter,DialMediaRouteProvider,Translate,OptimizationHints,AutofillServerCommunication,MacAppCodeSignClone",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    "--metrics-recording-only", "--no-pings", "--mute-audio", "--hide-scrollbars", "--force-color-profile=srgb",
    "--window-size=" + VIEW.width + "," + VIEW.height, "about:blank"
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

const pngSize = (buffer) => ({ width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) });

// One page (CDP session). Fixture pages get the gallery's bootstrap (manual
// clock, no camera) plus a shim that hides Element.animate, so Motion runs its
// springs on the manual rAF clock instead of WAAPI, which the manual clock can
// step but never finish. Perf pages get neither and run in real time.
async function openPage(chrome, { fixture }) {
  const { targetId } = await chrome.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await chrome.send("Target.attachToTarget", { targetId, flatten: true });
  const cdp = (method, params) => chrome.send(method, params, sessionId);
  const errors = [];
  chrome.on("Runtime.exceptionThrown", (p, sid) => {
    if (sid === sessionId) errors.push(p.exceptionDetails.exception?.description || p.exceptionDetails.text);
  });
  chrome.on("Runtime.consoleAPICalled", (p, sid) => {
    if (sid === sessionId && p.type === "error") errors.push("console: " + p.args.map((a) => a.value ?? a.description ?? "").join(" "));
  });
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Emulation.setDeviceMetricsOverride", { width: VIEW.width, height: VIEW.height, deviceScaleFactor: VIEW.scale, mobile: false });
  if (fixture) {
    await cdp("Page.addScriptToEvaluateOnNewDocument", { source: readFileSync(path.join(REPO, "gallery/tracker/fixture/bootstrap.js"), "utf8") });
    await cdp("Page.addScriptToEvaluateOnNewDocument", { source: "delete Element.prototype.animate;" });
  }
  const evaluate = async (expression) => {
    const result = await cdp("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error("page: " + (result.exceptionDetails.exception?.description || result.exceptionDetails.text));
    return result.result.value;
  };
  const setMedia = (variant) =>
    cdp("Emulation.setEmulatedMedia", {
      features: [
        { name: "prefers-color-scheme", value: variant.startsWith("dark") ? "dark" : "light" },
        { name: "prefers-reduced-motion", value: variant.endsWith("-rm") ? "reduce" : "no-preference" },
        { name: "prefers-reduced-transparency", value: "no-preference" }
      ]
    });
  const load = async (url) => {
    errors.length = 0;
    await cdp("Page.navigate", { url });
    for (let i = 0; i < 800; i += 1) {
      if (await evaluate("Boolean(window.__cal && window.__cal.mounted)").catch(() => false)) break;
      await sleep(25);
    }
    if (fixture) await evaluate("window.__fx.settle()");
  };
  const advanceTo = (ms) => evaluate("window.__fx.advanceTo(" + ms + ")");
  const shot = async (scale) => {
    const { data } = await cdp("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: VIEW.width, height: VIEW.height, scale }, captureBeyondViewport: false });
    return Buffer.from(data, "base64");
  };
  const close = () => chrome.send("Target.closeTarget", { targetId }).catch(() => {});
  return { cdp, evaluate, setMedia, load, advanceTo, shot, errors, close };
}

function write(file, buffer) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, buffer);
}

// A frame identical to the one before is hard-linked, not written again.
function frameWriter(dir) {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  let last = null;
  let lastFile = null;
  let count = 0;
  return {
    add(buffer) {
      const file = path.join(dir, String(count).padStart(4, "0") + ".png");
      const hash = createHash("sha1").update(buffer).digest("hex");
      if (hash === last) linkSync(lastFile, file);
      else writeFileSync(file, buffer);
      last = hash;
      lastFile = file;
      count += 1;
      return file;
    },
    finish() {
      writeFileSync(path.join(dir, "clip.json"), JSON.stringify({ fps: 60 }) + "\n");
      return count;
    }
  };
}

// A state clip cut from the flow: hard links into its own frame folder.
function cutClip(flowDir, dir, from, to) {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  let n = 0;
  for (let i = from; i < to; i += 1) {
    const source = path.join(flowDir, String(i).padStart(4, "0") + ".png");
    if (!existsSync(source)) break;
    linkSync(source, path.join(dir, String(n).padStart(4, "0") + ".png"));
    n += 1;
  }
  writeFileSync(path.join(dir, "clip.json"), JSON.stringify({ fps: 60 }) + "\n");
  return n;
}

// ---- Performance: real time, no fixture clock ------------------------------
const TRACE_CATEGORIES = ["devtools.timeline", "disabled-by-default-devtools.timeline", "disabled-by-default-devtools.timeline.frame", "blink", "cc", "gpu", "viz"];
const SCRIPT_EVENTS = new Set(["FunctionCall", "FireAnimationFrame", "EvaluateScript", "TimerFire", "EventDispatch", "RunMicrotasks", "V8.Execute"]);
const STYLE_EVENTS = new Set(["UpdateLayoutTree", "RecalculateStyles", "Layout", "PrePaint"]);
const PAINT_EVENTS = new Set(["Paint", "PaintImage", "Layerize", "UpdateLayer", "CompositeLayers", "Commit"]);

async function processCpu(chrome) {
  const { processInfo } = await chrome.send("SystemInfo.getProcessInfo");
  const sum = (type) => processInfo.filter((p) => p.type === type).reduce((a, p) => a + p.cpuTime, 0);
  return { renderer: sum("renderer"), gpu: sum("GPU") };
}

const tracing = { events: [], done: null };
function listenForTraces(chrome) {
  chrome.on("Tracing.dataCollected", (p) => tracing.events.push(...p.value));
  chrome.on("Tracing.tracingComplete", () => tracing.done && tracing.done());
}

async function trace(chrome, page, ms) {
  const events = (tracing.events = []);
  const done = new Promise((resolve) => (tracing.done = resolve));
  const before = await processCpu(chrome);
  await page.cdp("Tracing.start", { transferMode: "ReportEvents", traceConfig: { includedCategories: TRACE_CATEGORIES } });
  const t0 = Date.now();
  await sleep(ms);
  await page.cdp("Tracing.end");
  const wall = (Date.now() - t0) / 1000;
  const after = await processCpu(chrome);
  await done;
  const main = events.find((e) => e.name === "thread_name" && e.args?.name === "CrRendererMain");
  const onMain = (e) => main && e.pid === main.pid && e.tid === main.tid;
  let script = 0, style = 0, paint = 0, raster = 0;
  // Count only top-level slices so nested events are not double-counted.
  const top = events.filter((e) => e.ph === "X" && onMain(e)).sort((a, b) => a.ts - b.ts);
  let openUntil = -1;
  for (const e of top) {
    if (e.ts < openUntil) continue;
    if (SCRIPT_EVENTS.has(e.name)) { script += e.dur / 1000; openUntil = e.ts + e.dur; }
    else if (STYLE_EVENTS.has(e.name)) { style += e.dur / 1000; openUntil = e.ts + e.dur; }
    else if (PAINT_EVENTS.has(e.name)) { paint += e.dur / 1000; openUntil = e.ts + e.dur; }
  }
  for (const e of events) {
    if (e.ph === "X" && e.name === "RasterTask" && main && e.pid === main.pid) raster += e.dur / 1000;
  }
  const frameCount = Math.max(1, events.filter((e) => e.name === "DrawFrame").length || Math.round(wall * 60));
  return {
    seconds: wall,
    frames: frameCount,
    fps: frameCount / wall,
    rendererCpu: ((after.renderer - before.renderer) / wall) * 100,
    gpuCpu: ((after.gpu - before.gpu) / wall) * 100,
    scriptMs: script / frameCount,
    styleLayoutMs: style / frameCount,
    paintMs: paint / frameCount,
    rasterMs: raster / frameCount,
    gpuMsPerFrame: ((after.gpu - before.gpu) * 1000) / frameCount
  };
}

async function measure(chrome, base, dir) {
  const page = await openPage(chrome, { fixture: false });
  try {
    await page.setMedia("dark");
    await page.load(base + "?dir=" + dir.id + "&render=1");
    for (let i = 0; i < 400; i += 1) {
      if ((await page.evaluate("window.__cal.now()")) >= 5150) break;
      await sleep(25);
    }
    const pursuit = await trace(chrome, page, 3600);
    await page.load(base + "?dir=" + dir.id + "&render=1&hold=1100");
    await sleep(800);
    const idle = await trace(chrome, page, 3000);
    const errors = [...page.errors];
    return { pursuit, idle, errors };
  } finally {
    await page.close();
  }
}

// ---- Main ------------------------------------------------------------------
async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.out) {
    console.log("usage: node gallery/redesign/tracker/render.mjs --out <absolute OUT dir> [--only A,B] [--states intro,look] [--no-stills] [--no-clips] [--no-perf] [--clip-variants dark,light,dark-rm] [--clip-scale 0.5] [--work-dir dir]");
    process.exit(args.help ? 0 : 2);
  }
  if (!path.isAbsolute(args.out)) throw new Error("--out must be an absolute path");
  const OUT = args.out;
  const REL = "redesign/calibration";
  mkdirSync(OUT, { recursive: true });
  mkdirSync(args.workDir, { recursive: true });
  const started = Date.now();
  const distDir = path.join(args.workDir, "dist");
  log("building the prototype (vite) into " + distDir);
  await build(distDir);
  const server = await serve(distDir);
  const base = "http://127.0.0.1:" + server.address().port + "/index.html";
  const profileDir = mkdtempSync(path.join(os.tmpdir(), "jarvis-redesign-chrome-"));
  const chrome = launchChrome(findChrome(), profileDir, path.join(args.workDir, "chrome.log"));
  listenForTraces(chrome);
  const failures = [];
  const cleanup = async () => {
    try { await chrome.send("Browser.close"); } catch {}
    await Promise.race([chrome.exited, sleep(3000).then(() => chrome.child.kill("SIGKILL"))]);
    server.close();
    rmSync(profileDir, { recursive: true, force: true });
  };
  process.on("SIGINT", () => cleanup().then(() => process.exit(130)));

  const manifestPath = path.join(OUT, "manifest.redesign.tracker.json");
  const previous = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, "utf8")) : null;
  const component = { ...COMPONENT, directions: [] };
  try {
    for (const dir of DIRECTIONS) {
      const prevDir = previous?.components?.[0]?.directions?.find((d) => d.id === dir.id);
      if (args.only && !args.only.includes(dir.id)) {
        if (prevDir) component.directions.push(prevDir);
        continue;
      }
      const dirOut = path.join(OUT, REL, dir.id);
      const states = dir.states.filter((s) => !args.states || args.states.includes(s.id));
      const media = Object.fromEntries(dir.states.map((s) => [s.id, { ...(prevDir?.states?.find((p) => p.id === s.id)?.media || {}) }]));
      let flow = { ...(prevDir?.flow || {}) };
      const page = await openPage(chrome, { fixture: true });
      try {
        // Stills: every state, four variants, at deviceScaleFactor 2.
        if (args.stills) {
          for (const variant of VARIANTS) {
            for (const scenario of ["happy", "fail"]) {
              const wanted = states.filter((s) => s.scenario === scenario).sort((a, b) => a.still - b.still);
              if (!wanted.length) continue;
              await page.setMedia(variant);
              await page.load(base + "?dir=" + dir.id + "&scenario=" + scenario + "&render=1");
              for (const state of wanted) {
                await page.advanceTo(state.still);
                const buffer = await page.shot(1);
                const rel = REL + "/" + dir.id + "/" + state.id + "." + variant + ".png";
                write(path.join(OUT, rel), buffer);
                const size = pngSize(buffer);
                if (!media[state.id][variant] || media[state.id][variant].kind === "still") media[state.id][variant] = { kind: "still", src: rel, width: size.width, height: size.height };
              }
              if (page.errors.length) throw new Error(dir.id + " " + variant + " " + scenario + ": " + page.errors.join(" | "));
            }
            log(dir.id + " stills " + variant);
          }
        }
        // Clips: the flow once per variant, state clips cut from it by hard
        // link, and the failure path from its own run.
        if (args.clips) {
          for (const variant of args.clipVariants) {
            await page.setMedia(variant);
            await page.load(base + "?dir=" + dir.id + "&scenario=happy&render=1");
            const flowName = "flow." + variant;
            const flowDir = path.join(dirOut, flowName + ".frames");
            const writer = frameWriter(flowDir);
            const total = Math.round((dir.flowMs / 1000) * 60);
            let size = null;
            for (let i = 0; i < total; i += 1) {
              await page.advanceTo(i * FRAME_MS);
              const buffer = await page.shot(args.clipScale);
              size = size || pngSize(buffer);
              writer.add(buffer);
            }
            writer.finish();
            if (page.errors.length) throw new Error(dir.id + " flow " + variant + ": " + page.errors.join(" | "));
            const clipMedia = (name, frames) => ({ kind: "clip", src: REL + "/" + dir.id + "/" + name + ".mp4", poster: REL + "/" + dir.id + "/" + name + ".poster.png", width: size.width, height: size.height, fps: 60, duration: Math.round((frames / 60) * 100) / 100 });
            flow[variant] = clipMedia(flowName, total);
            for (const state of states.filter((s) => s.scenario === "happy")) {
              const name = state.id + "." + variant;
              const n = cutClip(flowDir, path.join(dirOut, name + ".frames"), Math.round(state.clip[0] / FRAME_MS), Math.round(state.clip[1] / FRAME_MS));
              media[state.id][variant] = clipMedia(name, n);
            }
            for (const state of states.filter((s) => s.scenario === "fail")) {
              await page.load(base + "?dir=" + dir.id + "&scenario=fail&render=1");
              const name = state.id + "." + variant;
              const failWriter = frameWriter(path.join(dirOut, name + ".frames"));
              const first = Math.round(state.clip[0] / FRAME_MS);
              const last = Math.round(state.clip[1] / FRAME_MS);
              for (let i = first; i < last; i += 1) {
                await page.advanceTo(i * FRAME_MS);
                failWriter.add(await page.shot(args.clipScale));
              }
              media[state.id][variant] = clipMedia(name, failWriter.finish());
              if (page.errors.length) throw new Error(dir.id + " " + state.id + " " + variant + ": " + page.errors.join(" | "));
            }
            log(dir.id + " clips " + variant + " (" + total + " flow frames)");
          }
        }
      } catch (error) {
        failures.push(String(error.message || error));
        console.error("[calibration] FAILED " + dir.id + ": " + (error.message || error));
      } finally {
        await page.close();
      }
      let perf = prevDir?.perf;
      if (args.perf) {
        try {
          const m = await measure(chrome, base, dir);
          writeFileSync(path.join(dirOut, "perf.json"), JSON.stringify(m, null, 2) + "\n");
          perf = dir.perfCard(m);
          log(dir.id + " perf " + JSON.stringify(perf));
        } catch (error) {
          failures.push("perf " + dir.id + ": " + (error.message || error));
        }
      }
      component.directions.push({
        ...dir.card,
        ...(perf ? { perf } : {}),
        states: dir.states.map((s) => ({ id: s.id, title: s.title, caption: s.caption, media: media[s.id] })),
        ...(Object.keys(flow).length ? { flow } : {})
      });
    }
  } finally {
    await cleanup();
  }
  component.directions.sort((a, b) => a.id.localeCompare(b.id));
  const fragment = {
    generatedAt: new Date().toISOString(),
    commit: execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: REPO }).toString().trim(),
    components: [component],
    scenes: []
  };
  writeFileSync(manifestPath, JSON.stringify(fragment, null, 2) + "\n");
  log("done in " + Math.round((Date.now() - started) / 1000) + " s; manifest: " + manifestPath);
  if (failures.length) {
    console.error("[calibration] " + failures.length + " failure(s)");
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("[calibration] " + (error.stack || error));
  process.exit(1);
});
