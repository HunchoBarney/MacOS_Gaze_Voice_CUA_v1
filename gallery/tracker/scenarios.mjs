// Fixture scenarios for every EyeTracking renderer surface. Each run(fx) is
// serialised and executed in the page (window.__fx from fixture/bootstrap.js),
// so it must be self-contained: no closures over this module.
const APP = "EyeTracking/web/src/App.tsx";
const CSS = "EyeTracking/web/src/styles.css";
const UI = "EyeTracking/web/src/uiState.ts";

// Helpers added to __fx after each page load.
export const PRELUDE = `(() => {
  const fx = window.__fx;
  fx.hold = (x, y, extra) => fx.stream(() => [x, y, extra], 10);
  // Steady-state tracking: past the 5 s launch camera hint.
  fx.dotAt = async (x, y, extra) => {
    if (fx.now < 5200) await fx.advanceTo(5200);
    await fx.menu("gaze_dot", true);
    fx.hold(x, y, extra);
    await fx.advance(600);
  };
  fx.until = async (predicate, stepMs = 50, maxMs = 60000) => {
    for (let t = 0; t < maxMs; t += stepMs) {
      if (predicate()) return;
      await fx.advance(stepMs);
    }
    throw new Error("fixture timeout waiting for " + predicate);
  };
  fx.ended = (phase, n = 1) => fx.calls.filter((c) => c[0] === "pursuitEnd" && c[1] === phase).length >= n;
  fx.begun = (phase, n = 1) => fx.calls.filter((c) => c[0] === "pursuitBegin" && c[1] === phase).length >= n;
  fx.verdict = { median: 0.031, p90: 0.058, max: 0.094, samples: 88, regions: { center: 0.021, edge: 0.033, corner: 0.041 } };
})()`;

// Dot at (0.5, 0.46) of 1512x982 is (756, 452) CSS px.
const DOT_BOX = { x: 706, y: 402, width: 100, height: 100 };
const DOT_RECT = { x: 646, y: 362, width: 220, height: 150 };

export const COMPONENTS = [
  {
    id: "tracker-camera-marker",
    title: "Camera position arrow",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "A yellow arrow and \"Camera position\" label under the webcam, shown for 5 s on every tracker launch and through the calibration countdown.",
    sources: [
      [APP, "className={`camera-marker"],
      [APP, "Startup camera hint"],
      [CSS, ".camera-marker {"],
      [CSS, ".camera-arrow-shape {"]
    ],
    states: [
      {
        id: "startup",
        title: "Launch (first 5 s)",
        run: async (fx) => {
          await fx.advance(400);
        },
        expect: ".camera-marker:not(.faded)",
        crop: { selectors: [".camera-marker"], pad: 28 },
        clip: {
          caption: "The 600 ms opacity fade at 5 s after launch",
          run: async (fx) => {
            await fx.advance(4900);
          },
          durationMs: 900,
          rect: { x: 656, y: 0, width: 200, height: 136 }
        }
      }
    ]
  },
  {
    id: "tracker-gaze-dot",
    title: "Gaze dot",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The optional gaze cursor (off by default, Vision Pro style): a white dot that springs after the tracker's gaze estimate, with ghost, held, dwell and paused presences.",
    sources: [
      [APP, "className={`gaze-dot"],
      [APP, "const dotStyle = (() => {"],
      [APP, "The 60fps dot loop runs only"],
      [CSS, ".gaze-dot {"],
      [CSS, ".gaze-dot.dwell::before {"],
      [UI, "export function advanceDotSpring"]
    ],
    states: [
      {
        id: "live",
        title: "Live (fixation)",
        note: "Fixture gaze at 10 Hz, the frame rate the owner's tracker measured.",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
        },
        expect: ".gaze-dot",
        crop: { rect: DOT_BOX },
        clip: {
          caption: "3 s of fixture gaze at 10 Hz: fixation, saccade, fixation, slow pursuit, dwell",
          run: async (fx) => {
            await fx.advanceTo(5200);
            await fx.menu("gaze_dot", true);
            const A = [0.42, 0.44], B = [0.6, 0.42], C = [0.55, 0.57];
            fx.stream((t) => {
              const n = () => fx.noise(0.0035);
              if (t < 800) return [A[0] + n(), A[1] + n()];
              if (t < 900) return [B[0] + n(), B[1] + n(), { gaze_state: "saccade" }];
              if (t < 1700) return [B[0] + n(), B[1] + n()];
              if (t < 2500) {
                const k = (t - 1700) / 800;
                return [B[0] + (C[0] - B[0]) * k + n(), B[1] + (C[1] - B[1]) * k + n()];
              }
              return [C[0] + n() * 0.3, C[1] + n() * 0.3, { gaze_state: "dwell" }];
            }, 10);
            await fx.advance(150);
          },
          durationMs: 3000,
          rect: { x: 456, y: 311, width: 600, height: 360 }
        }
      },
      {
        id: "dwell",
        title: "Dwell (fixation held)",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          fx.hold(0.5, 0.46, { gaze_state: "dwell" });
          await fx.advance(700);
        },
        expect: ".gaze-dot.dwell",
        crop: { rect: DOT_BOX },
        clip: {
          caption: "The 500 ms conic ring sweep when a fixation becomes a dwell",
          run: async (fx) => {
            await fx.dotAt(0.5, 0.46);
            fx.hold(0.5, 0.46, { gaze_state: "dwell" });
          },
          durationMs: 800,
          rect: DOT_BOX
        }
      },
      {
        id: "held",
        title: "Held (dwell lock)",
        note: "held_reason set: the dot drops to 40% opacity.",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          fx.hold(0.5, 0.46, { held_reason: "dwell_lock" });
          await fx.advance(400);
        },
        expect: ".gaze-dot",
        crop: { rect: DOT_BOX }
      },
      {
        id: "ghost",
        title: "Ghost (blink or head turned)",
        note: "blink: the dot drops to 18% opacity.",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          fx.hold(0.5, 0.46, { blink: true });
          await fx.advance(400);
        },
        expect: ".gaze-dot",
        crop: { rect: DOT_BOX }
      },
      {
        id: "paused",
        title: "Paused (frozen ghost)",
        note: "Tracking paused from the menu: the stream stops and the last position stays at 20% opacity.",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          await fx.menu("pause_toggle");
          fx.stopStream();
          await fx.advance(2000);
        },
        expect: ".gaze-dot",
        crop: { rect: DOT_BOX }
      },
      {
        id: "scaled",
        title: "Dot size 2x",
        note: "dot_scale 2 from Settings.",
        run: async (fx) => {
          await fx.menu("dot_scale", 2);
          await fx.dotAt(0.5, 0.46);
        },
        expect: ".gaze-dot",
        crop: { rect: DOT_BOX }
      }
    ]
  },
  {
    id: "tracker-click-effect",
    title: "Lip-click effect",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The burst on the gaze dot when a lip click fires: a green ring and \"Single\" label, or two cyan rings and \"Double\". It only renders while the gaze dot is switched on.",
    sources: [
      [APP, "payload.type === \"lip_click_effect\""],
      [APP, "{clickEffect && <span className=\"gaze-click-label\">"],
      [CSS, ".gaze-dot.single-click-effect {"],
      [CSS, "@keyframes gaze-double-click-ring"]
    ],
    states: [
      {
        id: "single",
        title: "Single click",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          await fx.emit({ type: "lip_click_effect", effect: "single" });
          await fx.advance(140);
        },
        expect: ".gaze-dot.single-click-effect",
        crop: { rect: DOT_RECT },
        clip: {
          caption: "Single lip click, 840 ms",
          run: async (fx) => {
            await fx.dotAt(0.5, 0.46);
            await fx.emit({ type: "lip_click_effect", effect: "single" });
          },
          durationMs: 900,
          rect: DOT_RECT
        }
      },
      {
        id: "double",
        title: "Double click",
        run: async (fx) => {
          await fx.dotAt(0.5, 0.46);
          await fx.emit({ type: "lip_click_effect", effect: "double" });
          await fx.advance(420);
        },
        expect: ".gaze-dot.double-click-effect",
        crop: { rect: DOT_RECT },
        clip: {
          caption: "Double lip click, 1240 ms",
          run: async (fx) => {
            await fx.dotAt(0.5, 0.46);
            await fx.emit({ type: "lip_click_effect", effect: "double" });
          },
          durationMs: 1300,
          rect: DOT_RECT
        }
      }
    ]
  },
  {
    id: "tracker-onboarding",
    title: "Calibration invitation",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The first-run card over a dark scrim when no calibration exists: \"Tune the tracker to your eyes\" with Calibrate and Not now.",
    sources: [
      [APP, "className=\"onboarding-card\""],
      [APP, "First run: no calibration on disk"],
      [CSS, ".onboarding-card {"],
      [CSS, ".onboarding-actions button.primary {"]
    ],
    states: [
      {
        id: "card",
        title: "Invitation",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "calibration", status: "missing" });
          await fx.advance(100);
        },
        expect: ".onboarding-card",
        crop: { selectors: [".onboarding-card"], pad: 40 }
      },
      {
        id: "card-hover",
        title: "Invitation, pointer on Calibrate",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "calibration", status: "missing" });
          await fx.advance(100);
        },
        hover: ".onboarding-actions button.primary",
        expect: ".onboarding-card",
        crop: { selectors: [".onboarding-card"], pad: 40 }
      }
    ]
  },
  {
    id: "tracker-calibration",
    title: "Calibration",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The full-screen calibration: countdown, then a luminous target that glides between points and parks while the tracker samples, a verify pass, notices, and the \"Calibrated\" confirmation.",
    sources: [
      [APP, "className=\"calibration-scrim\""],
      [APP, "className=\"calibration-countdown\""],
      [APP, "className={`pursuit-target"],
      [APP, "className=\"pose-hint\""],
      [APP, "className=\"calibration-notice\""],
      [APP, "className=\"calibrated-card\""],
      [APP, "const CALIBRATION_TIERS"],
      [CSS, ".calibration-scrim {"],
      [CSS, ".pursuit-target {"],
      [CSS, ".calibration-countdown {"],
      [CSS, ".calibrated-card {"]
    ],
    states: [
      {
        id: "countdown",
        title: "Countdown",
        note: "Recalibrate from the menu (quick tier). The camera arrow stays up through the countdown.",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.menu("recalibrate");
          await fx.advance(400);
        },
        expect: ".calibration-countdown",
        clip: {
          caption: "3-2-1 countdown (dark only: the 94-97% scrim hides the desktop)",
          run: async (fx) => {
            await fx.advance(5200);
            await fx.menu("recalibrate");
          },
          durationMs: 2300,
          scale: 0.5
        }
      },
      {
        id: "capture-glide",
        title: "Capture: target gliding",
        note: "Quick tier (centre + corners). The faint ghost marks the waypoint after the next.",
        run: async (fx) => {
          await fx.menu("recalibrate");
          await fx.advance(3000 + 1400 + 420);
        },
        expect: ".pursuit-target:not(.dwell)",
        clip: {
          caption: "Capture: glide, park, ring contracts while sampling, glide on (dark only: the scrim hides the desktop)",
          run: async (fx) => {
            await fx.menu("recalibrate");
            await fx.advance(3000 + 1300);
          },
          durationMs: 2500,
          scale: 0.5
        }
      },
      {
        id: "capture-dwell",
        title: "Capture: parked and sampling",
        run: async (fx) => {
          await fx.menu("recalibrate");
          await fx.advance(3000 + 1400 + 849 + 800);
        },
        expect: ".pursuit-target.dwell"
      },
      {
        id: "pose-hold",
        title: "Capture: head tilted",
        note: "Fixture gaze with 18 degrees of yaw: sampling pauses and the top hint asks for a still head.",
        run: async (fx) => {
          fx.hold(0.5, 0.5, { yaw_deg: 18 });
          await fx.menu("recalibrate");
          await fx.advance(3000 + 1400 + 849 + 800);
        },
        expect: ".pose-hint"
      },
      {
        id: "verify",
        title: "Verify pass",
        run: async (fx) => {
          await fx.menu("recalibrate");
          await fx.until(() => fx.begun("verify"), 100);
          await fx.advance(950);
        },
        expect: ".pursuit-target.verify"
      },
      {
        id: "retry",
        title: "Fit rejected, one more pass",
        note: "The worker rejects the first fit with its real reason string (core.ts rejectFit); 11 samples is what the owner's log showed at 10 fps.",
        run: async (fx) => {
          fx.hooks.pursuitEnd = (phase, send) => {
            if (phase === "capture" && !fx.rejectedOnce) {
              fx.rejectedOnce = true;
              send({ type: "calibration", status: "rejected_fit", message: "Only 11 pursuit samples — follow the dot for the full path" });
            }
          };
          await fx.menu("recalibrate");
          await fx.until(() => fx.begun("capture", 2), 100);
          await fx.advance(700);
        },
        expect: ".calibration-notice"
      },
      {
        id: "rejected",
        title: "Rejected after three passes",
        note: "Three verify passes miss the accuracy gate; the modal closes and the worker's own reason string (core.ts verify gate) stays on screen.",
        run: async (fx) => {
          fx.hooks.pursuitEnd = (phase, send) => {
            if (phase === "verify") send({ type: "calibration", status: "rejected_fit", message: "Verification error median=0.112 p90=0.241 corner=0.301 exceeds gate", verdict: fx.verdict });
          };
          await fx.menu("recalibrate");
          await fx.until(() => fx.ended("verify", 3), 200, 120000);
          await fx.advance(400);
        },
        expect: ".calibration-notice"
      },
      {
        id: "starting-up",
        title: "Waiting for the tracker to start",
        params: { runtimeDelay: "600000" },
        run: async (fx) => {
          await fx.menu("recalibrate");
          await fx.advance(3400);
        },
        expect: ".calibration-notice"
      },
      {
        id: "not-running",
        title: "Tracker not running",
        params: { noRuntime: "1" },
        run: async (fx) => {
          await fx.advance(5200);
          await fx.menu("recalibrate");
          await fx.advance(3300);
        },
        expect: ".calibration-notice",
        crop: { selectors: [".calibration-notice"], pad: 32 }
      },
      {
        id: "save-failed",
        title: "Calibration could not be saved",
        note: "Message shape from core.ts commitPending; the error text is a plausible fixture.",
        run: async (fx) => {
          fx.hooks.pursuitEnd = (phase, send) => {
            if (phase === "verify") send({ type: "calibration", status: "save_failed", message: "Failed to save calibration: EACCES: permission denied" });
          };
          await fx.menu("recalibrate");
          await fx.until(() => fx.ended("verify"), 100);
          await fx.advance(300);
        },
        expect: ".calibration-notice",
        crop: { selectors: [".calibration-notice"], pad: 32 }
      },
      {
        id: "done",
        title: "Calibrated",
        note: "Self-dismissing confirmation, 1.6 s.",
        run: async (fx) => {
          fx.hooks.pursuitEnd = (phase, send) => {
            if (phase === "verify") send({ type: "calibration", status: "saved", count: 88, verdict: fx.verdict });
          };
          await fx.menu("recalibrate");
          await fx.until(() => fx.ended("verify"), 100);
          await fx.advance(260);
        },
        expect: ".calibrated-card",
        crop: { selectors: [".calibrated-card"], pad: 40 },
        clip: {
          caption: "\"Calibrated\" confirmation, 1600 ms",
          run: async (fx) => {
            fx.hooks.pursuitEnd = (phase, send) => {
              if (phase === "verify") send({ type: "calibration", status: "saved", count: 88, verdict: fx.verdict });
            };
            await fx.menu("recalibrate");
            await fx.until(() => fx.ended("verify"), 16);
          },
          durationMs: 1700,
          rect: { x: 586, y: 431, width: 340, height: 120 }
        }
      }
    ]
  },
  {
    id: "tracker-accuracy-check",
    title: "Accuracy check",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "Settings > Check eye-tracking accuracy: a 16-point held-out grid of yellow dots, then 75 circular hit targets, with a step counter.",
    sources: [
      [APP, "className=\"calibration-target accuracy\""],
      [APP, "className=\"hit-target\""],
      [CSS, ".calibration-target.accuracy > div {"],
      [CSS, ".accuracy-progress {"],
      [CSS, ".hit-target {"]
    ],
    states: [
      {
        id: "grid",
        title: "Held-out grid",
        note: "Measure-only run. Grid order is seeded so renders are stable.",
        run: async (fx) => {
          await fx.advance(5200);
          fx.hold(0.5, 0.5);
          await fx.advance(200);
          await fx.menu("accuracy_check", { measure_only: true });
          await fx.advance(300);
          fx.stopStream();
        },
        expect: ".calibration-target.accuracy"
      },
      {
        id: "hit",
        title: "Hit test",
        run: async (fx) => {
          await fx.advance(5200);
          fx.hold(0.5, 0.5);
          await fx.advance(200);
          await fx.menu("accuracy_check", { measure_only: true });
          await fx.advance(300);
          fx.stopStream();
          await fx.until(() => document.querySelector(".hit-target"), 250, 30000);
          await fx.advance(300);
        },
        expect: ".hit-target"
      }
    ]
  },
  {
    id: "tracker-hint-pill",
    title: "Top hint pill",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The pill at the top of the screen: an amber drift warning when tracking slips, or a 4 s hint after Not now or an invalid calibration.",
    sources: [
      [APP, "className=\"drift-notice\""],
      [APP, "const flashHint = useCallback"],
      [APP, "payload.message === \"drift_detected\""],
      [CSS, ".drift-notice {"]
    ],
    states: [
      {
        id: "drift",
        title: "Drift warning",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "status", level: "warning", message: "drift_detected" });
          await fx.advance(100);
        },
        expect: ".drift-notice",
        crop: { selectors: [".drift-notice"], pad: 24 }
      },
      {
        id: "recalibrate-hint",
        title: "Recalibrate hint",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "calibration", status: "invalid" });
          await fx.advance(100);
        },
        expect: ".drift-notice",
        crop: { selectors: [".drift-notice"], pad: 24 }
      }
    ]
  },
  {
    id: "tracker-status-pane",
    title: "Diagnostics status panel",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The bottom-right diagnostics panel (debug or the status toggle): tracker state, distance, head pose, inference times, runtimes and display, with an info, warning or error stripe.",
    sources: [
      [APP, "className={`status ${statusLevel}`}"],
      [CSS, ".status {"],
      [CSS, ".status.warning {"]
    ],
    states: [
      {
        id: "info",
        title: "Tracking (info)",
        params: { debug: "1" },
        run: async (fx) => {
          await fx.emit({ type: "status", level: "info", message: "web runtime ready", runtime: "onnxweb", accelerator: "wasm", detector_providers: ["wasm"], gaze_providers: ["wasm"] });
          fx.hold(0.5, 0.5, { head_face_width_ratio: 1.18, eye_position_weight_x: 0.5, eye_position_weight_y: 0.5, gaze_projection_mode: "binocular-screen" });
          await fx.advance(5200);
        },
        expect: ".status.info",
        crop: { selectors: [".status"], pad: 24 }
      },
      {
        id: "warning",
        title: "Calibration missing (warning)",
        params: { debug: "1", learnIfMissing: "1" },
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "calibration", status: "missing" });
          await fx.advance(100);
        },
        expect: ".status.warning",
        crop: { selectors: [".status"], pad: 24 }
      },
      {
        id: "error",
        title: "Tracker failed to start (error)",
        params: { debug: "1", runtimeFail: "Could not start the camera: NotReadableError (fixture)" },
        allowConsoleErrors: true,
        run: async (fx) => {
          await fx.advance(5200);
        },
        expect: ".status.error",
        crop: { selectors: [".status"], pad: 24 }
      }
    ]
  },
  {
    id: "tracker-inference-time",
    title: "Inference time readout",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "A large red per-frame inference time in the top-left corner, shown by the inference-time diagnostics toggle.",
    sources: [
      [APP, "className=\"inference-time\""],
      [CSS, ".inference-time {"]
    ],
    states: [
      {
        id: "live",
        title: "Live",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.menu("inference_time_toggle", true);
          fx.hold(0.5, 0.5);
          await fx.advance(700);
        },
        expect: ".inference-time",
        crop: { selectors: [".inference-time"], pad: 24 }
      }
    ]
  },
  {
    id: "tracker-preview",
    title: "Camera detection preview",
    area: "Eye tracker",
    owner: "JARA-55",
    summary: "The top-right diagnostics thumbnail of what the detector sees, with a Head/Eyes line. Here it shows a synthetic fixture frame, never the camera.",
    sources: [
      [APP, "className=\"preview\""],
      [CSS, ".preview {"]
    ],
    states: [
      {
        id: "detected",
        title: "Head and both eyes found",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "preview", image: fx.previewImage(true), head_detected: true, eye_count: 2, width_ratio: 0.34 });
          await fx.advance(100);
        },
        expect: ".preview",
        crop: { selectors: [".preview"], pad: 24 }
      },
      {
        id: "no-face",
        title: "No face",
        run: async (fx) => {
          await fx.advance(5200);
          await fx.emit({ type: "preview", image: fx.previewImage(false), head_detected: false, eye_count: 0, width_ratio: null });
          await fx.advance(100);
        },
        expect: ".preview",
        crop: { selectors: [".preview"], pad: 24 }
      }
    ]
  }
];

// JARA-55's own renders (captain drive, renders/JARA-55), shown as references.
export const REFERENCE_STATES = [
  {
    component: "tracker-calibration",
    file: "calibration-orb-points.png",
    id: "orb-points-mockup",
    title: "Proposed: 9-point orb calibration (JARA-55 mockup)",
    note: "JARA-55's mockup of the redesign that replaces the serpentine pursuit. Rendered at 1440x900."
  },
  { component: "gaze-orb-directions", file: "magnet-on-target.png", id: "magnet-on-target", title: "Magnet: on a control", note: "The owner's pick. Rendered by JARA-55 at 1440x900." },
  { component: "gaze-orb-directions", file: "magnet-reading.png", id: "magnet-reading", title: "Magnet: reading", note: "Rendered by JARA-55 at 1440x900." },
  { component: "gaze-orb-directions", file: "lantern-on-target.png", id: "lantern-on-target", title: "Lantern: on a control", note: "Rendered by JARA-55 at 1440x900." },
  { component: "gaze-orb-directions", file: "lantern-reading.png", id: "lantern-reading", title: "Lantern: reading", note: "Rendered by JARA-55 at 1440x900." },
  { component: "gaze-orb-directions", file: "aura-on-target.png", id: "aura-on-target", title: "Aura: on a control", note: "Rendered by JARA-55 at 1440x900." },
  { component: "gaze-orb-directions", file: "aura-reading.png", id: "aura-reading", title: "Aura: reading", note: "Rendered by JARA-55 at 1440x900." }
];

export const SCENES = [
  {
    id: "tracker-first-launch",
    title: "Tracker first launch",
    summary: "The first seconds after the tracker starts with no calibration: camera arrow, invitation card and scrim together.",
    components: ["tracker-camera-marker", "tracker-onboarding"],
    run: async (fx) => {
      await fx.emit({ type: "calibration", status: "missing" });
      await fx.advance(600);
    }
  },
  {
    id: "tracker-calibrating",
    title: "Calibrating with the head tilted",
    summary: "Mid-capture: scrim, progress rail, exit button, parked target, next-point ghost, notice and the pose hint at once.",
    components: ["tracker-calibration"],
    run: async (fx) => {
      fx.hold(0.5, 0.5, { yaw_deg: 18 });
      await fx.menu("recalibrate");
      await fx.advance(3000 + 1400 + 849 + 800);
    }
  },
  {
    id: "tracker-all-diagnostics",
    title: "Tracking with every diagnostic on",
    summary: "Gaze dot mid lip-click, drift pill, inference readout, preview thumbnail and status panel together, the most the overlay ever shows outside a modal.",
    components: ["tracker-gaze-dot", "tracker-click-effect", "tracker-hint-pill", "tracker-inference-time", "tracker-preview", "tracker-status-pane"],
    params: { debug: "1", markerOff: "1" },
    run: async (fx) => {
      await fx.emit({ type: "status", level: "info", message: "web runtime ready", runtime: "onnxweb", accelerator: "wasm", detector_providers: ["wasm"], gaze_providers: ["wasm"] });
      await fx.menu("inference_time_toggle", true);
      await fx.dotAt(0.58, 0.42);
      await fx.emit({ type: "preview", image: fx.previewImage(true), head_detected: true, eye_count: 2, width_ratio: 0.34 });
      await fx.emit({ type: "status", level: "warning", message: "drift_detected" });
      await fx.advance(1500);
      await fx.emit({ type: "preview", image: fx.previewImage(true), head_detected: true, eye_count: 2, width_ratio: 0.34 });
      await fx.emit({ type: "lip_click_effect", effect: "single" });
      await fx.advance(140);
    }
  }
];
