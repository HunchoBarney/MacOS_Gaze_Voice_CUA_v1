// Fixture bootstrap for the EyeTracking renderer (gallery only).
// Injected with Page.addScriptToEvaluateOnNewDocument, so it runs before the
// app bundle. It stubs the Electron preload bridge (same shape as
// EyeTracking/electron/preload.cjs), keeps the camera shut, swaps the clock
// for a manual one so every frame is deterministic whatever the machine load,
// and exposes window.__fx for render.mjs to drive the UI from fixture state.
(() => {
  const query = new URLSearchParams(location.search);
  const width = Number(query.get("w") || 1512);
  const height = Number(query.get("h") || 982);

  // ---- Privacy: no camera, no microphone, no persisted state ---------------
  const refuse = () => Promise.reject(new DOMException("Fixture renderer: capture is disabled", "NotAllowedError"));
  try {
    if (navigator.mediaDevices) {
      Object.defineProperty(navigator.mediaDevices, "getUserMedia", { value: refuse, configurable: true });
      Object.defineProperty(navigator.mediaDevices, "enumerateDevices", { value: () => Promise.resolve([]), configurable: true });
    }
  } catch {}
  try {
    localStorage.clear();
  } catch {}

  // ---- Seeded randomness (accuracy grid order, gaze noise) -----------------
  let seed = Number(query.get("seed") || 0x5eed) >>> 0;
  Math.random = () => {
    seed = (seed + 0x6d2b79f5) >>> 0;
    let t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  // ---- Manual clock --------------------------------------------------------
  const RealDate = Date;
  const RealMessageChannel = MessageChannel;
  const EPOCH = Date.UTC(2026, 10, 20, 20, 0, 0);
  const PERF_OFFSET = 1000;
  const FRAME = 1000 / 60;
  let now = 0;
  let lastFrame = 0;
  let seq = 1;
  const timers = new Map();
  const rafs = new Map();
  const errors = [];

  class FixtureDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) super(EPOCH + now);
      else super(...args);
    }
    static now() {
      return EPOCH + now;
    }
  }
  window.Date = FixtureDate;
  performance.now = () => now + PERF_OFFSET;

  const addTimer = (fn, ms, args, interval) => {
    const id = seq++;
    const delay = Math.max(0, Number(ms) || 0);
    timers.set(id, { id, at: now + delay, fn, args, interval: interval ? Math.max(1, delay) : 0, seq: id });
    return id;
  };
  window.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, args, false);
  window.setInterval = (fn, ms, ...args) => addTimer(fn, ms, args, true);
  window.clearTimeout = (id) => void timers.delete(id);
  window.clearInterval = (id) => void timers.delete(id);
  window.requestAnimationFrame = (cb) => {
    const id = seq++;
    rafs.set(id, cb);
    return id;
  };
  window.cancelAnimationFrame = (id) => void rafs.delete(id);

  const call = (fn, args) => {
    try {
      if (typeof fn === "function") fn(...args);
    } catch (error) {
      errors.push(String(error && error.stack ? error.stack : error));
    }
  };

  // Lets React's MessageChannel-scheduled commits and passive effects land.
  const turn = () =>
    new Promise((resolve) => {
      const channel = new RealMessageChannel();
      channel.port1.onmessage = () => resolve();
      channel.port2.postMessage(0);
    });
  const settle = async () => {
    for (let i = 0; i < 5; i += 1) await turn();
  };

  // CSS animations and transitions are paused and stepped on the manual clock.
  // A CSS animation-play-state of paused holds its time, as the browser would.
  const animTime = new WeakMap();
  const syncAnimations = () => {
    for (const animation of document.getAnimations()) {
      let state = animTime.get(animation);
      if (!state) {
        state = { t: 0, last: now };
        animTime.set(animation, state);
        animation.pause();
      }
      let cssPaused = false;
      const effect = animation.effect;
      if (typeof CSSAnimation !== "undefined" && animation instanceof CSSAnimation && effect && effect.target) {
        const style = getComputedStyle(effect.target, effect.pseudoElement || null);
        const names = style.animationName.split(",").map((s) => s.trim());
        const states = style.animationPlayState.split(",").map((s) => s.trim());
        const index = Math.max(0, names.indexOf(animation.animationName));
        cssPaused = states[index % states.length] === "paused";
      }
      if (!cssPaused) state.t += now - state.last;
      state.last = now;
      animation.currentTime = state.t;
    }
  };

  const advanceTo = async (target) => {
    for (;;) {
      let timer = null;
      for (const t of timers.values()) {
        if (!timer || t.at < timer.at || (t.at === timer.at && t.seq < timer.seq)) timer = t;
      }
      const frameIndex = Math.max(lastFrame + 1, Math.floor(now / FRAME + 1e-6) + 1);
      const frameAt = rafs.size ? frameIndex * FRAME : Infinity;
      const timerAt = timer ? timer.at : Infinity;
      if (Math.min(frameAt, timerAt) > target + 1e-6) break;
      if (frameAt <= timerAt) {
        now = Math.max(now, frameAt);
        lastFrame = frameIndex;
        const callbacks = [...rafs.values()];
        rafs.clear();
        for (const cb of callbacks) call(cb, [now + PERF_OFFSET]);
      } else {
        now = Math.max(now, timerAt);
        if (timer.interval) timer.at += timer.interval;
        else timers.delete(timer.id);
        call(timer.fn, timer.args || []);
      }
      await settle();
      syncAnimations();
    }
    now = Math.max(now, target);
    await settle();
    syncAnimations();
  };

  // ---- Fixture config (RendererConfig) -------------------------------------
  const webInference = query.has("noRuntime")
    ? null
    : {
        runtime: "onnxweb",
        webInferenceWorker: "dedicated",
        webAccelerator: "auto",
        detector: "mediapipe",
        backend: "web",
        camera: "fixture",
        cameraWidth: 640,
        cameraHeight: 480,
        cameraFov: 70,
        scoreThreshold: 0.5,
        displaySizeInch: 14.2,
        displayWidth: width,
        displayHeight: height,
        calibrationFile: "calibration.json",
        cameraScreenX: 0.5,
        cameraScreenY: 0
      };
  const config = {
    calibrate: query.has("calibrate"),
    accuracyTest: false,
    hitTest: false,
    calibrateIfMissing: query.has("calibrateIfMissing"),
    learnIfMissing: query.has("learnIfMissing"),
    calibrationTier: query.get("tier") || "full",
    displayIndex: 0,
    requestedDisplayIndex: 0,
    displayCount: 1,
    displayBounds: { x: 0, y: 0, width, height },
    invalidDisplay: false,
    cameraScreenX: 0.5,
    cameraScreenY: 0,
    enableInferenceTime: false,
    debug: query.has("debug"),
    showCameraMarker: false,
    runtime: "onnxweb",
    webInference
  };
  const settings = query.has("markerOff") ? { show_camera_marker_on_start: false } : {};

  // ---- Preload bridge stub (shape of electron/preload.cjs) -----------------
  const listeners = new Set();
  const recalibrate = new Set();
  const fx = {
    errors,
    calls: [],
    hooks: {},
    readyCalled: false,
    runtimeStarted: false,
    phase: null,
    get now() {
      return now;
    },
    FRAME
  };
  const after = (ms, fn) => addTimer(fn, ms, [], false);

  window.gazeBridge = {
    getConfig: () => Promise.resolve(JSON.parse(JSON.stringify(config))),
    readCalibration: () => Promise.resolve({ ok: true, text: null }),
    writeCalibration: (p) => Promise.resolve({ ok: true, path: "fixture/" + p }),
    writeReport: (p) => Promise.resolve({ ok: true, path: "fixture/" + p }),
    ready: () => {
      fx.readyCalled = true;
    },
    setOverlayRegions: (regions) => {
      fx.regions = regions;
    },
    setModalInteractive: (value) => {
      fx.modalInteractive = value;
    },
    setPaused: (value) => {
      fx.paused = value;
    },
    getSettings: () => Promise.resolve({ ...settings }),
    setSettings: () => {},
    reportState: () => {},
    publishBackendMessage: () => {},
    onBackendMessage: (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    onRecalibrate: (cb) => {
      recalibrate.add(cb);
      return () => recalibrate.delete(cb);
    }
  };

  // ---- Web runtime stand-in (gallery/tracker/fixture/webRuntime.fixture.js)
  // No worker, no model, no camera: the controller records calls and lets a
  // scenario answer pursuitEnd the way the real worker would.
  fx.startRuntime = (_config, onMessage) => {
    fx.runtimeStarted = true;
    fx.runtimeMessage = onMessage;
    const delay = Number(query.get("runtimeDelay") || 0);
    const controller = {
      pursuitBegin: (mode = "capture") => {
        fx.phase = mode;
        fx.calls.push(["pursuitBegin", mode, now]);
      },
      pursuitTarget: () => {},
      pursuitEnd: () => {
        const phase = fx.phase;
        fx.calls.push(["pursuitEnd", phase, now]);
        fx.phase = null;
        if (fx.hooks.pursuitEnd) fx.hooks.pursuitEnd(phase, onMessage);
      },
      pursuitAbort: () => {
        fx.calls.push(["pursuitAbort", fx.phase, now]);
        fx.phase = null;
      },
      implicitSample: () => {},
      setPaused: () => {},
      setFilterOptions: () => {},
      setPreviewEnabled: () => {},
      stop: () => {}
    };
    return new Promise((resolve, reject) => {
      const finish = () => {
        if (query.has("runtimeFail")) reject(new Error(query.get("runtimeFail") || "Camera could not start"));
        else resolve(controller);
      };
      if (delay > 0) after(delay, finish);
      else finish();
    });
  };

  // ---- Driving API ---------------------------------------------------------
  fx.settle = settle;
  fx.sync = syncAnimations;
  fx.advance = (ms) => advanceTo(now + ms);
  fx.advanceTo = advanceTo;
  fx.emitSync = (message) => {
    for (const cb of [...listeners]) call(cb, [message]);
  };
  fx.emit = async (message) => {
    fx.emitSync(message);
    await settle();
    syncAnimations();
  };
  fx.recalibrate = async () => {
    for (const cb of [...recalibrate]) call(cb, []);
    await settle();
    syncAnimations();
  };
  fx.menu = (action, value) => fx.emit(value === undefined ? { type: "menu_action", action } : { type: "menu_action", action, value });
  fx.gazeFrame = (x, y, extra = {}) => ({
    type: "gaze",
    x_norm: x,
    y_norm: y,
    confidence: 0.92,
    distance_m: 0.56,
    distance_source: "iris",
    gaze_state: "fixation",
    frame_interval_ms: 100,
    captured_at_ms: Date.now(),
    yaw_deg: 2.4,
    pitch_deg: -3.1,
    inference_ms: 23.41,
    detect_inference_ms: 9.82,
    gaze_inference_ms: 11.37,
    ...extra
  });
  // A gaze stream on the manual clock: path(tMs) -> [x, y, extra] | null.
  // Frames arrive at hz (the owner's tracker measured ~10 fps).
  let streamTimer = 0;
  fx.stream = (path, hz = 10) => {
    fx.stopStream();
    const start = now;
    const tick = () => {
      const sample = path(now - start);
      if (sample) fx.emitSync(fx.gazeFrame(sample[0], sample[1], sample[2] || {}));
      streamTimer = after(1000 / hz, tick);
    };
    tick();
  };
  fx.stopStream = () => {
    if (streamTimer) timers.delete(streamTimer);
    streamTimer = 0;
  };
  fx.noise = (sigma) => {
    const u = Math.max(1e-9, Math.random());
    const v = Math.random();
    return sigma * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };

  // A synthetic detection preview (no camera): an abstract head outline with
  // landmark marks, drawn on a canvas and labelled as a fixture.
  fx.previewImage = (ok = true) => {
    const canvas = document.createElement("canvas");
    canvas.width = 320;
    canvas.height = 240;
    const g = canvas.getContext("2d");
    g.fillStyle = "#1f2633";
    g.fillRect(0, 0, 320, 240);
    g.fillStyle = "#2a3344";
    g.fillRect(0, 170, 320, 70);
    g.strokeStyle = ok ? "#14b8a6" : "#f59e0b";
    g.lineWidth = 2;
    if (ok) {
      g.strokeRect(108, 44, 104, 132);
      g.fillStyle = "#5b6577";
      g.beginPath();
      g.ellipse(160, 110, 44, 56, 0, 0, Math.PI * 2);
      g.fill();
      g.strokeStyle = "#7fd0ff";
      g.strokeRect(130, 92, 22, 12);
      g.strokeRect(168, 92, 22, 12);
      g.fillStyle = "#7fd0ff";
      for (const [x, y] of [[141, 98], [179, 98], [160, 122], [148, 140], [172, 140]]) {
        g.beginPath();
        g.arc(x, y, 2.2, 0, Math.PI * 2);
        g.fill();
      }
    }
    g.fillStyle = "rgba(255,255,255,0.55)";
    g.font = "600 11px -apple-system, system-ui, sans-serif";
    g.fillText("FIXTURE · NO CAMERA", 10, 228);
    return canvas.toDataURL("image/png");
  };

  // Backdrop behind the transparent overlay: nothing (alpha PNG) or a flat
  // fixture desktop with one generic window, light or dark with the scheme.
  const DESKTOP_CSS = [
    "html { background: #c9d3e3 !important; }",
    "body::before { content: ''; position: fixed; z-index: -1; left: 9%; top: 13%; width: 56%; height: 62%; border-radius: 12px;",
    "  background: linear-gradient(#e8ebf0 0 38px, #ffffff 38px);",
    "  box-shadow: 0 0 0 0.5px rgba(0,0,0,0.18), 0 22px 60px rgba(0,0,0,0.22); }",
    "body::after { content: ''; position: fixed; z-index: -1; left: 12%; top: 22%; width: 46%; height: 40%;",
    "  background: repeating-linear-gradient(#d9dee6 0 9px, transparent 9px 26px); }",
    "@media (prefers-color-scheme: dark) {",
    "  html { background: #1b2130 !important; }",
    "  body::before { background: linear-gradient(#2c313b 0 38px, #1e2129 38px);",
    "    box-shadow: 0 0 0 0.5px rgba(255,255,255,0.14), 0 22px 60px rgba(0,0,0,0.5); }",
    "  body::after { background: repeating-linear-gradient(#353b47 0 9px, transparent 9px 26px); }",
    "}"
  ].join("\n");
  fx.setBackdrop = (kind) => {
    let style = document.getElementById("fx-backdrop");
    if (!style) {
      style = document.createElement("style");
      style.id = "fx-backdrop";
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = kind === "desktop" ? DESKTOP_CSS : "";
  };

  // Union of element rects (CSS px) for a tight crop.
  fx.rectOf = (selectors, pad = 24) => {
    let box = null;
    for (const selector of selectors) {
      for (const el of document.querySelectorAll(selector)) {
        const r = el.getBoundingClientRect();
        if (r.width <= 0 && r.height <= 0) continue;
        box = box
          ? { l: Math.min(box.l, r.left), t: Math.min(box.t, r.top), r: Math.max(box.r, r.right), b: Math.max(box.b, r.bottom) }
          : { l: r.left, t: r.top, r: r.right, b: r.bottom };
      }
    }
    if (!box) return null;
    const l = Math.max(0, Math.floor(box.l - pad));
    const t = Math.max(0, Math.floor(box.t - pad));
    const r = Math.min(innerWidth, Math.ceil(box.r + pad));
    const b = Math.min(innerHeight, Math.ceil(box.b + pad));
    return { x: l, y: t, width: r - l, height: b - t };
  };

  window.__fx = fx;
})();
