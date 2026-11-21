#!/usr/bin/env node
// Records the redesign section's placeholder clips once, from a canvas in headless Chrome
// (MediaRecorder, H.264), into sample/clips/redesign/. The output is committed, so pnpm sample
// never needs Chrome. Rerun only to change the placeholders:
//   node scripts/record-sample-clips.mjs
// Fixture art only: abstract shapes on an invented desktop, no real screen content.
// Chrome runs headless with a throwaway profile over --remote-debugging-pipe (no port), the
// same pattern as gallery/tracker/render.mjs.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "..", "sample", "clips", "redesign");
const W = 480;
const H = 300;
const FPS = 30;

const CLIPS = [
  ...["A", "B", "C"].flatMap((d) => ["listening", "thinking", "speaking"].map((s) => ({ id: d + "-" + s, direction: d, state: s, seconds: 2 }))),
  ...["A", "B", "C"].map((d) => ({ id: d + "-flow", direction: d, state: "flow", seconds: 3 })),
  ...["listening", "thinking", "speaking"].map((s) => ({ id: "B-" + s + "-rm", direction: "B", state: s, rm: true, seconds: 2 })),
  { id: "scene-desk", direction: "scene", state: "scene", seconds: 3 },
];

// Runs in the page. t is seconds; every loop is periodic in its clip length so it loops cleanly.
function pageSetup(W, H, FPS) {
  const canvas = document.createElement("canvas");
  canvas.width = W;
  canvas.height = H;
  document.body.append(canvas);
  const ctx = canvas.getContext("2d");
  const TAU = Math.PI * 2;
  const NAMES = { A: "Island", B: "Aurora", C: "Orb", scene: "Scene" };

  function desktop() {
    const g = ctx.createLinearGradient(0, 0, W, H);
    g.addColorStop(0, "#151a2e");
    g.addColorStop(0.6, "#2a2850");
    g.addColorStop(1, "#4b2f4a");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    ctx.fillStyle = "rgba(0,0,0,0.35)";
    ctx.fillRect(0, 0, W, 14);
    ctx.fillStyle = "#000";
    roundRect(W / 2 - 46, -8, 92, 22, 8);
    ctx.fill();
    ctx.fillStyle = "rgba(30,30,34,0.92)";
    roundRect(70, 60, 340, 200, 10);
    ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,0.08)";
    for (let i = 0; i < 6; i += 1) {
      roundRect(92, 100 + i * 22, 220 - (i % 3) * 50, 8, 4);
      ctx.fill();
    }
    ["#ff5f57", "#febc2e", "#28c840"].forEach((c, i) => {
      ctx.fillStyle = c;
      ctx.beginPath();
      ctx.arc(86 + i * 13, 74, 4, 0, TAU);
      ctx.fill();
    });
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
  }

  function level(t, state, period) {
    const p = (t / period) * TAU;
    if (state === "thinking") return 0.25;
    if (state === "speaking") return 0.55 + 0.35 * Math.abs(Math.sin(p * 3)) * (0.6 + 0.4 * Math.sin(p));
    return 0.3 + 0.45 * Math.abs(Math.sin(p * 2)) * (0.5 + 0.5 * Math.sin(p * 1 + 1));
  }

  function island(t, state, period, rm) {
    const lv = rm ? 0.4 : level(t, state, period);
    const width = state === "speaking" ? 200 : state === "thinking" ? 150 : 170;
    const x = W / 2 - width / 2;
    ctx.fillStyle = "#000";
    roundRect(x, -10, width, 40, 16);
    ctx.fill();
    const tint = state === "thinking" ? "#bf5af2" : state === "speaking" ? "#30d158" : "#0a84ff";
    ctx.fillStyle = tint;
    ctx.beginPath();
    ctx.arc(x + 20, 15, 5, 0, TAU);
    ctx.fill();
    if (state === "thinking") {
      for (let i = 0; i < 3; i += 1) {
        const a = rm ? 0.7 : 0.35 + 0.65 * (0.5 + 0.5 * Math.sin((t / period) * TAU * 2 - i * 0.9));
        ctx.fillStyle = "rgba(255,255,255," + a + ")";
        ctx.beginPath();
        ctx.arc(x + width - 46 + i * 12, 15, 3, 0, TAU);
        ctx.fill();
      }
      return;
    }
    for (let i = 0; i < 7; i += 1) {
      const h = 4 + 16 * lv * (0.5 + 0.5 * Math.sin((t / period) * TAU * (state === "speaking" ? 4 : 3) + i * 1.3));
      ctx.fillStyle = "#fff";
      roundRect(x + width - 70 + i * 7, 15 - h / 2, 3, h, 1.5);
      ctx.fill();
    }
  }

  function aurora(t, state, period, rm) {
    const lv = rm ? 0.45 : level(t, state, period);
    const spin = rm ? 0 : (t / period) * TAU * (state === "thinking" ? 1 : 0.5);
    const g = ctx.createConicGradient(spin, W / 2, H / 2);
    ["#ff6ec7", "#ffb35c", "#5ee7ff", "#8a7dff", "#ff6ec7"].forEach((c, i, all) => g.addColorStop(i / (all.length - 1), c));
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    for (const [blur, alpha, width] of [[18, 0.55, 10], [6, 0.9, 3]]) {
      ctx.filter = "blur(" + blur + "px)";
      ctx.strokeStyle = g;
      ctx.globalAlpha = alpha * (0.45 + 0.55 * lv);
      ctx.lineWidth = width + (state === "speaking" ? 6 * lv : 0);
      roundRect(2, 2, W - 4, H - 4, 18);
      ctx.stroke();
    }
    ctx.restore();
  }

  function orb(t, state, period, rm, cx = W - 64, cy = H - 60) {
    const lv = rm ? 0.4 : level(t, state, period);
    const r = 18 + 10 * lv;
    const hue = state === "thinking" ? 280 : state === "speaking" ? 150 : 210;
    const g = ctx.createRadialGradient(cx - r * 0.3, cy - r * 0.3, 2, cx, cy, r * 1.8);
    g.addColorStop(0, "hsla(" + hue + ",100%,85%,1)");
    g.addColorStop(0.35, "hsla(" + (hue + 30) + ",95%,60%,0.95)");
    g.addColorStop(0.7, "hsla(" + (hue + 60) + ",90%,50%,0.35)");
    g.addColorStop(1, "hsla(" + (hue + 60) + ",90%,50%,0)");
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(cx, cy, r * 1.8, 0, TAU);
    ctx.fill();
  }

  function label(text) {
    ctx.font = "600 10px -apple-system, system-ui, sans-serif";
    ctx.fillStyle = "rgba(255,255,255,0.55)";
    ctx.fillText("SAMPLE · " + text, 10, H - 10);
  }

  function frame(clip, t) {
    desktop();
    const { direction, state, rm, seconds } = clip;
    if (direction === "scene") {
      island(t, t < 1.5 ? "listening" : "speaking", seconds, false);
      const pulse = 0.5 + 0.5 * Math.sin((t / seconds) * TAU * 2);
      ctx.strokeStyle = "rgba(255,214,10," + (0.5 + 0.5 * pulse) + ")";
      ctx.lineWidth = 2;
      roundRect(318, 196, 72, 30, 9);
      ctx.stroke();
      ctx.fillStyle = "#0a84ff";
      roundRect(324, 202, 60, 18, 6);
      ctx.fill();
      label("Scene · Island + gaze ring");
      return;
    }
    const states = ["listening", "thinking", "speaking"];
    const current = state === "flow" ? states[Math.min(2, Math.floor(t))] : state;
    const draw = { A: island, B: aurora, C: orb }[direction];
    draw(t, current, state === "flow" ? 1 : seconds, rm);
    label(NAMES[direction] + " · " + current + (state === "flow" ? " (flow)" : "") + (rm ? " · Reduce Motion" : ""));
  }

  async function record(clip) {
    frame(clip, 0);
    const poster = canvas.toDataURL("image/jpeg", 0.8);
    const stream = canvas.captureStream(FPS);
    const type = "video/mp4;codecs=avc1.42E01E";
    if (!MediaRecorder.isTypeSupported(type)) throw new Error("MediaRecorder can't write " + type);
    const recorder = new MediaRecorder(stream, { mimeType: type, videoBitsPerSecond: 180000 });
    const chunks = [];
    recorder.ondataavailable = (e) => chunks.push(e.data);
    const stopped = new Promise((resolve) => (recorder.onstop = resolve));
    recorder.start();
    const start = performance.now();
    await new Promise((resolve) => {
      const timer = setInterval(() => {
        const t = (performance.now() - start) / 1000;
        if (t >= clip.seconds) {
          clearInterval(timer);
          resolve();
          return;
        }
        frame(clip, t);
      }, 1000 / FPS);
    });
    recorder.stop();
    await stopped;
    const blob = new Blob(chunks, { type: "video/mp4" });
    const video = document.createElement("video");
    video.muted = true;
    video.src = URL.createObjectURL(blob);
    await new Promise((resolve, reject) => {
      video.onloadedmetadata = resolve;
      video.onerror = () => reject(new Error("recorded clip does not decode"));
    });
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return { video: btoa(binary), poster: poster.split(",")[1], duration: video.duration };
  }
  window.recordClip = record;
}

function launchChrome(chromePath, profileDir) {
  const args = [
    "--headless",
    "--remote-debugging-pipe",
    "--user-data-dir=" + profileDir,
    "--use-mock-keychain",
    "--password-store=basic",
    "--deny-permission-prompts",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-sync",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--mute-audio",
    "--force-color-profile=srgb",
    // Without this, every launch of the signed app copies it (about 1.5 GB) into
    // /private/var/folders/.../com.google.Chrome.code_sign_clone and never cleans up.
    "--disable-features=MacAppCodeSignClone",
    "about:blank",
  ];
  const child = spawn(chromePath, args, { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
  const writer = child.stdio[3];
  let nextId = 1;
  const pending = new Map();
  let buffered = Buffer.alloc(0);
  child.stdio[4].on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    let end;
    while ((end = buffered.indexOf(0)) >= 0) {
      const message = JSON.parse(buffered.subarray(0, end).toString("utf8"));
      buffered = buffered.subarray(end + 1);
      const waiter = message.id && pending.get(message.id);
      if (!waiter) continue;
      pending.delete(message.id);
      if (message.error) waiter.reject(new Error(waiter.method + ": " + message.error.message));
      else waiter.resolve(message.result);
    }
  });
  const exited = new Promise((resolve) => child.on("exit", resolve));
  return {
    child,
    exited,
    send(method, params = {}, sessionId) {
      const id = nextId++;
      writer.write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject, method }));
    },
  };
}

const chromePath = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"].find((p) => existsSync(p));
if (!chromePath) throw new Error("Google Chrome not found");
const profileDir = mkdtempSync(join(os.tmpdir(), "jarvis-gallery-clips-"));
const chrome = launchChrome(chromePath, profileDir);
try {
  const { targetId } = await chrome.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await chrome.send("Target.attachToTarget", { targetId, flatten: true });
  const evaluate = async (expression) => {
    const result = await chrome.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);
    return result.result.value;
  };
  await evaluate("(" + pageSetup.toString() + ")(" + W + "," + H + "," + FPS + ")");
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  const index = {};
  for (const clip of CLIPS) {
    const result = await evaluate("recordClip(" + JSON.stringify(clip) + ")");
    writeFileSync(join(out, clip.id + ".mp4"), Buffer.from(result.video, "base64"));
    writeFileSync(join(out, clip.id + ".jpg"), Buffer.from(result.poster, "base64"));
    index[clip.id] = { width: W, height: H, fps: FPS, duration: Number.isFinite(result.duration) ? Math.round(result.duration * 1000) / 1000 : clip.seconds };
    console.log("recorded", clip.id, Math.round(Buffer.byteLength(result.video, "base64") / 1024) + " KB", "duration", result.duration);
  }
  writeFileSync(join(out, "clips.json"), JSON.stringify(index, null, 2) + "\n");
} finally {
  await chrome.send("Browser.close").catch(() => undefined);
  const closed = await Promise.race([chrome.exited.then(() => true), new Promise((r) => setTimeout(() => r(false), 15000))]);
  if (closed) rmSync(profileDir, { recursive: true, force: true });
  else console.warn("Chrome is still closing; left it to exit on its own (profile " + profileDir + ")");
}
