# Screen Eye Tracking

> **Note:** this file is upstream-derived reference documentation — CLI
> flags, API endpoints, model layout. Where it disagrees with the current
> code, the code wins.

This workspace copy of [PINTO0309/screen-eye-tracking](https://github.com/PINTO0309/screen-eye-tracking)
at source commit `48b7e37` includes the local calibration and projection changes.
The upstream license is preserved in `LICENSE`. Its macOS trial scripts
package the app under this workspace's `build/` directory. Setup and the
Conductor run commands live in `AGENTS.md` and `.conductor/settings.toml` at the
workspace root.

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20771714.svg)](https://doi.org/10.5281/zenodo.20771713)

A desktop application that estimates where the user is looking on the selected display and renders a red gaze marker at the estimated hit position. It uses RetinaFace or YOLO WholeBody28 for eye position detection and an ONNX gaze model for gaze estimation.

The application is built as an Electron + React transparent overlay running onnxruntime-web inside a dedicated inference worker. (The Python backend and LiteRT path were removed — one runtime, one calibration pipeline.)

MediaPipe dependency-free.

- Tested on a 31.5-inch display - The display size can be changed using CLI parameters

  https://github.com/user-attachments/assets/7eff8143-2417-4459-8e63-de97868e3ff0

- Webcam and dGPU/iGPU only

  <img width="843" height="458" alt="image" src="https://github.com/user-attachments/assets/c3e192f0-9cb2-4ab8-ae31-9c93ce0647eb" />

## Arch

<img width="1600" height="730" alt="framework-architecture" src="https://github.com/user-attachments/assets/133e5969-55bc-40c2-89cb-207ace82677c" />

## Setup

```bash
# Installing pnpm
## Linux / Mac
curl -fsSL https://get.pnpm.io/install.sh | sh -
## Windows
Invoke-WebRequest https://get.pnpm.io/install.ps1 -UseBasicParsing | Invoke-Expression

# Installing npm packages
pnpm install
```

Download the model files from the [release](https://github.com/PINTO0309/screen-eye-tracking/releases/tag/onnx), then place the required models under `public/models/`.

Place under `public/models/`:

```text
public/models/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx
public/models/yolomit_t_wholebody28_1x3x480x640.onnx
public/models/vsdlm_l.onnx
public/models/gaze_1x3x160x160.onnx
```

Optional appearance-ensemble model (adds a second gaze signal fused into the
calibration map; the app runs fine without it and warns once at startup):

```text
public/models/mobileone_s0_gaze.onnx
```

An archive of CoreML models is also available from the same release, but I don't have demo code because I don't own an iPhone.

- [coreml_retinaface.tar.gz](https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx/coreml_retinaface.tar.gz)
- [coreml_gaze.tar.gz](https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx/coreml_gaze.tar.gz)
- [coreml_yolo.tar.gz](https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx/coreml_yolo.tar.gz)
- [coreml_vsdlm_l.tar.gz](https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx/coreml_vsdlm_l.tar.gz)

## Run

- `display-size-inch = diagonal length (cm) / 2.54`
- The diagonal length does not include the bezel.

  <img width="600" alt="inches" src="https://github.com/user-attachments/assets/e3b3e637-283e-4d3c-ab08-72ada5e950af" />

### Running

All inference runs inside Electron on onnxruntime-web — there is no Python backend.
The runtime defaults to the wasm execution provider for reliability — on
Electron 42/macOS the WebGPU provider can wedge silently (`InferenceSession.run()`
never returns, 0% CPU, no error). WebGPU remains available as an explicit opt-in
via `--web-accelerator webgpu` pending an upstream fix.

```bash
# Recommended
pnpm dev -- \
--calibrate \
--gaze-projection-mode binocular-screen \
--display-size-inch 31.5

# Selecting the gaze estimation mode
pnpm dev -- \
--calibrate \
--display-size-inch 31.5

pnpm dev -- \
--calibrate \
--gaze-projection-mode legacy \
--display-size-inch 31.5

pnpm dev -- \
--calibrate \
--gaze-projection-mode binocular-screen \
--display-size-inch 31.5

pnpm dev -- \
--calibrate \
--gaze-projection-mode binocular-convergence \
--display-size-inch 31.5
```

`--backend` is accepted for compatibility but ignored — the onnxruntime-web
runtime selects its own accelerator (`--web-accelerator webgpu|wasm` pins it;
the `auto` default resolves to wasm).

When a web runtime is selected, Electron uses the selected model files in `public/models/` during dev runs and copies them to `dist/models/` for production runs. It also copies the required runtime wasm assets from `node_modules/` to `public/` during dev runs, or to `dist/` for production runs. The renderer loads both models and wasm assets as normal public assets.

## Lip Motion

If you specify `yolo` for `--detector` and also specify `--enable-lip-motion`, you can try out a feature that emulates a left mouse click action by opening and closing your mouth. Your gaze moves frequently and unconsciously, so clicking in the exact right position will require miraculous skill.

```bash
pnpm dev -- \
--detector yolo \
--enable-lip-motion \
--calibrate \
--gaze-projection-mode binocular-screen \
--display-size-inch 31.5
```

<img width="600" alt="LipMotion" src="https://github.com/user-attachments/assets/9f256287-cf8e-4b1b-9770-3b3c04373911" />

https://github.com/user-attachments/assets/0d761f22-047a-4f5a-b83a-6200f11897eb

## Main Options

```bash
pnpm dev -- \
--detector retinaface \
--display-index 0 \
--display-size-inch 31.5 \
--camera 0 \
--score-threshold 0.50 \
--preview-fps 8
```

- `--runtime onnxweb`: Inference runtime (onnxweb is the only runtime; other values log a warning and are ignored).
- `--detector retinaface|yolo`: Eye position detector. Default: `retinaface`.
- `--retinaface-model`: RetinaFace model path. Default: `public/models/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx`.
- `--yolo-model`: YOLO WholeBody28 model path. Default: `public/models/yolomit_t_wholebody28_1x3x480x640.onnx`.
- `--lip-motion-model`: Lip motion model path. Default: `public/models/vsdlm_l.onnx`.
- `--appearance-model`: Appearance-ensemble gaze model path. Default: `public/models/mobileone_s0_gaze.onnx`.
- `--no-appearance-model`: Disable the appearance-model ensemble signal.
- `--detector-model`: Directly overrides the selected detector model path.
- `--display-index`: Target monitor index for the overlay marker. This uses the display order reported by Electron.
- `--debug-overlay`: Starts as a normal opaque window instead of a transparent overlay and opens DevTools.
- `--debug`: Enables the renderer's debug affordances (verbose panels/logging). Unlike `--debug-overlay` the window stays a transparent overlay.
- `--show-camera-marker`: Shows the camera-position marker (arrow + `Camera position` label) on startup. Hidden by default.
- `--no-tray`: Suppresses the menu-bar tray icon and its menu (including the standalone `Quit` item). Host apps that embed the tracker always pass this.
- `--shape-overlay`: On Linux/Windows, restricts the transparent window shape to the visible overlay elements. This is a fallback for environments where normal click-through does not work. Do not use it if the gaze marker flickers.
- `--display-size-inch`: Target monitor diagonal size in inches. Any positive finite value is accepted. Default: `31.5`.
- `--camera`: Browser video input index or `deviceId`. Default: `0`.
- `--camera-resolution`: Camera capture resolution preset or `WIDTHxHEIGHT`. Default: `HD`/`720p` (`1280x720`); if the camera refuses the exact constraints the tracker warns and falls back to `VGA` (`640x480`). An explicit `--camera-resolution` request is exact-or-fail (no fallback). Accepted presets are `QQVGA`, `QVGA`, `VGA`, `SVGA`, `XGA`, `HD`/`720p`, `SXGA`, `UXGA`, `Full HD`/`1080p`, `3MP`, `QHD`/`WQHD`/`1440p`, `5MP`, `6MP`, `4K UHD`, `DCI 4K`, `12MP`, `5K`, `6K`, `8K UHD`, and `12K`. `2MP`, `4MP`, and `8MP` aliases are rejected; use `1920x1080`, `2560x1440`, or `3840x2160` instead.
- `--camera-fov`: Horizontal camera FOV in degrees. Must be greater than `0` and less than `180`. Default: `90`.
- `--score-threshold`: Detection score threshold. For YOLO, this applies to Head and Mouth; Eye uses a fixed `0.20` threshold.
- `--calibration-file`: Path for the calibration result. Default: `.gaze_calibration.json`.
- `--calibrate`: Runs the pursuit calibration tour followed by a verification sweep, then saves the best fit.
- `--calibration-tier full|standard|quick`: Calibration coverage. `full` (default) is a 17-point 4×4 tour that reaches the screen corners; `standard` is a 9-point 3×3 tour; `quick` is corners + center (~10s) for patching a drifted or moved setup. `⌘⇧G` (global hotkey) runs the `quick` tier at any time; `⌘⇧P` toggles tracking pause.
- `--accuracy-test`: After calibration, runs a 9-point held-out accuracy test and writes `accuracy_report.json`.
- `--gaze-filter saccade|oneeuro|ema`: Gaze marker filter. `saccade` (default) passes fast glances through unfiltered, eases fixations, and anchors sustained fixations (dwell lock). `oneeuro` is speed-adaptive; `ema` is fixed-alpha smoothing.
- `--filter-mincutoff`: One Euro filter minimum cutoff frequency in Hz. Larger values track faster but jitter more. Default: `1.0`.
- `--filter-beta`: One Euro filter speed coefficient. Larger values respond faster to quick glances. Default: `0.7`.
- `--filter-dcutoff`: One Euro filter derivative cutoff frequency in Hz. Default: `1.0`.
- `--no-iris-distance`: Disables iris-diameter distance estimation and always uses the head-width distance estimate.
- `--smoothing-alpha`: Horizontal gaze marker smoothing when `--gaze-filter ema` is used. Larger values are steadier but slower. Default: `0.65`.
- `--smoothing-alpha-y`: Vertical gaze marker smoothing when `--gaze-filter ema` is used. Larger values are steadier but slower. Default: `0.45`.
- `--preview-fps`: PiP camera preview update FPS. Default: `8`.
- `--enable-inference-time`: Shows total inference time in the top-left corner as `xx.xx ms`.
- `--web-inference-worker off|ort-proxy|dedicated`: Inference worker mode. Default: `dedicated` — inference runs in a dedicated Worker so capture, preprocessing, and model time never block overlay rendering. `off` and `ort-proxy` remain as debug escape hatches.
- `--external-api`: Starts a read-only local HTTP/WebSocket API for external applications. Disabled by default.
- `--external-api-host`: Host for `--external-api`. Default: `127.0.0.1`.
- `--external-api-port`: Port for `--external-api`. Default: `47892`.
- `--show-preview`: Shows the PiP camera preview (diagnostic; hidden by default in the product shell).
- `--no-flip-x`: Disables horizontal gaze point flip correction. By default the screen x coordinate is flipped.
- `--no-flip-y`: Disables vertical pitch flip correction for the gaze model output. The parallel translation correction from the face/eye camera-space Y position is not flipped.
- `--camera-screen-x`: Camera position on the target screen, normalized horizontally. Left `0.0`, center `0.5`, right `1.0`. Default: `0.5`.
- `--camera-screen-y`: Camera position on the target screen, normalized vertically. Top `0.0`, center `0.5`, bottom `1.0`. Default: `0.0`.
- `--eye-position-weight-x`: Weight for the parallel translation correction from the face/eye bbox X position. Default: `1.0`.
- `--eye-position-weight-y`: Weight for the parallel translation correction from the face/eye bbox Y position. Default: `0.25`. Lower this if posture changes make the marker stick to the top or bottom edge.
- `--retinaface-head-face-ratio`: Static ratio used with RetinaFace to convert Face width to Head-equivalent width. Default: `1.545`.
- `--gaze-projection-mode legacy|binocular-screen|binocular-convergence`: Screen projection mode. Default: `legacy`.
- `--enable-lip-motion`: With `--detector yolo`, estimates Mouth class id `19` with `vsdlm_l`; opening the mouth sends a left click at the current gaze point, and a quick open-close-open sequence sends the second click for a normal OS double-click. With RetinaFace this option is ignored with a warning.
- `--gaze-model`: Gaze model path. Default: `public/models/gaze_1x3x160x160.onnx`.
- `--gaze-max-fps`: Caps the inference frame rate (per-second processing budget on low-end machines). Default: `20`.
- `--host-pid`: PID of the owning host app (Jarvis passes its own). The tracker polls it every 2s and self-quits when the host dies, so a crashed or force-quit host can't orphan the tracker. Absent in standalone runs — no watchdog by design.
- `--web-accelerator auto|webgpu|wasm`: Pin the onnxruntime-web execution provider. Default: `auto`, which resolves to `wasm` — the WebGPU provider can wedge inference silently on Electron 42/macOS, so `webgpu` is opt-in pending an upstream fix.

If vertical tracking feels too slow while horizontal tracking is acceptable with `--gaze-filter ema`, lower `--smoothing-alpha-y`, for example `--smoothing-alpha-y 0.30`. If vertical movement is too small rather than too slow, try increasing `--eye-position-weight-y` gradually, for example `0.35` or `0.45`. With the default `saccade` filter the marker passes real glances through unfiltered and locks while dwelling; `--gaze-filter oneeuro` restores the speed-adaptive filter (raise `--filter-beta` for faster glances or lower `--filter-mincutoff` for a steadier marker).

With `--show-preview`, the PiP preview in the upper-right corner shows the camera image and detection state. The Head/Face-equivalent bbox is drawn in green, Eye detections are drawn in yellow, and Mouth is drawn with the same margin-adjusted bbox used for lip motion input. When gaze estimation succeeds, green line segments are drawn from both eye centers toward the estimated gaze direction. `Head OK / Eyes 2` means the current detection is usable for gaze estimation.

## External API

External API access is disabled unless `--external-api` is passed. When enabled, the Electron main process exposes the latest internal state for local applications, plus a small control endpoint:

https://github.com/user-attachments/assets/345e7fd9-540b-47b5-a2e6-69a25d1e7a54

```bash
pnpm dev -- \
--external-api \
--calibrate \
--gaze-projection-mode binocular-screen \
--display-size-inch 31.5 \
--web-inference-worker dedicated

pnpm dev -- \
--external-api \
--calibrate \
--gaze-projection-mode binocular-screen \
--display-size-inch 31.5
```

HTTP endpoints:

```text
GET http://127.0.0.1:47892/health
GET http://127.0.0.1:47892/ready
GET http://127.0.0.1:47892/snapshot
GET http://127.0.0.1:47892/snapshot/gaze
GET http://127.0.0.1:47892/snapshot/display
GET http://127.0.0.1:47892/snapshot/camera
GET http://127.0.0.1:47892/snapshot/calibration
GET http://127.0.0.1:47892/snapshot/runtime
GET http://127.0.0.1:47892/snapshot/models
GET http://127.0.0.1:47892/snapshot/status
GET http://127.0.0.1:47892/snapshot/paused
GET http://127.0.0.1:47892/snapshot/calibration_status
GET http://127.0.0.1:47892/snapshot/settings
POST http://127.0.0.1:47892/control
```

`GET /health` is liveness only — the process serves. `GET /ready` is the honest readiness signal `make local` polls: `200 {"ready": true}` once the pipeline produces, `503 {"ready": false, "reason": <string>}` otherwise. Reasons in precedence order: `status_error` (the served status is `level:"error"`), `runtime_not_started`, `models_not_loaded`, `no_recent_gaze`. A paused tracker counts as ready — pausing stops the stream on purpose — and fresh gaze means `gaze.updated_at` within the last 3s.

The GET endpoints are read-only; `POST /control` is the single write path. Its JSON body is `{"action": "<name>", "value": <any>}` where `action` is one of `pause_toggle`, `recalibrate`, `dot_scale`, `dwell_lock`, `preview_toggle`, `status_toggle`, `inference_time_toggle`, `show_marker`, `implicit_sample`, or `quit`. Response codes:

- `200 {"ok": true}` — a valid non-lifecycle action forwarded to the renderer (`recalibrate` runs the same path as the `⌘⇧G` hotkey).
- `202 {"ok": true}` — `quit` only: acknowledged API-side, then the app quits on the next tick; it is never forwarded to the renderer.
- `400` — `bad_request` (unparseable request target), `unknown_action`, `invalid_json`, `invalid_body`, or `invalid_value`. `invalid_value` is specific to `implicit_sample`: its `value` must be a normalized screen point `{"x_norm": 0..1, "y_norm": 0..1}` — a malformed point is rejected here rather than clamped into a bogus calibration label.
- `409 {"error": "tracking_inactive"}` — `implicit_sample` declined because no live inference can consume the label (renderer down, modal UI owning the screen, tracker paused, or models never reported loaded). On accept it lands as the same `cursor_idle` message the idle sampler emits.
- `405` — non-POST on `/control`, non-GET elsewhere. `403` — requests carrying an `Origin` header are rejected: the API is unauthenticated, so only originless local clients may call it. `413` — body over 64 KiB. `503 control_unavailable` — no control/quit handler wired (e.g. `quit` without an `onQuit` callback). Handlers may also return their own `{status, error}` 4xx/5xx result.

`gaze` sample.

```json
{
  "x_norm": 0.00046604398934387703,
  "y_norm": 0.958942713790909,
  "raw_x_norm": 0,
  "raw_y_norm": 0.27114625325864034,
  "x_px": 2561.1930726127202,
  "y_px": 1380.877507858909,
  "confidence": 0.9944654703140259,
  "distance_m": 0.4017150043171776,
  "head_face_width_ratio": 1.545,
  "eye_position_weight_x": 1,
  "eye_position_weight_y": 0.25,
  "gaze_projection_mode": "binocular-screen",
  "detect_inference_ms": 4.2,
  "gaze_inference_ms": 12.5,
  "inference_ms": 16.7,
  "yaw_deg": 45.64941204243133,
  "pitch_deg": -12.357516307166726,
  "updated_at": "2026-06-21T13:47:46.399Z"
}
```

WebSocket updates are available at:

```text
ws://127.0.0.1:47892/events
```

Testing how to retrieve all status information in real time using WebSocket.

```bash
websocat ws://127.0.0.1:47892/events | jq .
```

Result sample.

```json
{
  "type": "update",
  "changed": [
    "preview"
  ],
  "snapshot": {
    "schema_version": 1,
    "started_at": "2026-06-21T13:47:11.321Z",
    "updated_at": "2026-06-21T13:49:54.535Z",
    "runtime": {
      "name": "onnxweb",
      "updated_at": "2026-06-21T13:47:13.297Z",
      "accelerator": "wasm"
    },
    "display": {
      "display_index": 1,
      "requested_display_index": 1,
      "display_count": 2,
      "bounds": {
        "x": 2560,
        "y": 0,
        "width": 2560,
        "height": 1440
      },
      "invalid_display": false,
      "display_size_inch": 31.5,
      "display_width": 2560,
      "display_height": 1440,
      "updated_at": "2026-06-21T13:47:11.515Z"
    },
    "camera": {
      "camera": "0",
      "camera_resolution_name": "VGA",
      "camera_width": 640,
      "camera_height": 480,
      "camera_fov_deg": 90,
      "camera_screen_x": 0.5,
      "camera_screen_y": 0,
      "eye_position_weight_x": 1,
      "eye_position_weight_y": 0.25,
      "updated_at": "2026-06-21T13:47:13.297Z"
    },
    "gaze": {
      "x_norm": 0.17188336409460786,
      "y_norm": 0.5195849356182066,
      "raw_x_norm": 0.40830238024351473,
      "raw_y_norm": 0.06745025281012713,
      "x_px": 3000.021412082196,
      "y_px": 748.2023072902175,
      "confidence": 0.9993162155151367,
      "distance_m": 0.35452647209083504,
      "head_face_width_ratio": 1.545,
      "eye_position_weight_x": 1,
      "eye_position_weight_y": 0.25,
      "gaze_projection_mode": "binocular-screen",
      "detect_inference_ms": 4.2,
      "gaze_inference_ms": 12.5,
      "inference_ms": 16.7,
      "yaw_deg": -0.5973023779724806,
      "pitch_deg": -3.642409505603852,
      "updated_at": "2026-06-21T13:49:54.453Z"
    },
    "calibration": {
      "path": "/home/xxxxx/git/screen-eye-tracking/.gaze_calibration.json",
      "affine": [
        [
          4.7702737155679955,
          -0.16037419549669352
        ],
        [
          -0.1617891579496593,
          8.48930676701609
        ],
        [
          -1.7831292403376189,
          0.03883337028363698
        ]
      ],
      "source_bounds": {
        "min": [
          0.3911222626423193,
          0.01679723168253273
        ],
        "max": [
          0.5708666378962844,
          0.1091656248711355
        ],
        "margin": 0.08
      },
      "samples": [
        {
          "raw": [
            0.47425021214696883,
            0.06281074167161842
          ],
          "target": [
            0.5,
            0.5
          ]
        },
        {
          "raw": [
            0.3911222626423193,
            0.01679723168253273
          ],
          "target": [
            0.12,
            0.12
          ]
        },
        {
          "raw": [
            0.5708666378962844,
            0.02074244710003301
          ],
          "target": [
            0.88,
            0.12
          ]
        },
        {
          "raw": [
            0.5491286581713097,
            0.1091656248711355
          ],
          "target": [
            0.88,
            0.88
          ]
        },
        {
          "raw": [
            0.4184644907591354,
            0.10751170352506421
          ],
          "target": [
            0.12,
            0.88
          ]
        }
      ],
      "updated_at": "2026-06-21T13:47:24.147Z",
      "status": "saved",
      "saved_path": "/home/xxxxx/git/screen-eye-tracking/.gaze_calibration.json"
    },
    "models": {
      "detector": {
        "runtime": "onnxweb",
        "accelerator": "webgpu",
        "detector": "retinaface",
        "model": "/home/xxxxx/git/screen-eye-tracking/public/models/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx",
        "providers": [
          "webgpu"
        ],
        "updated_at": "2026-06-21T13:47:13.297Z"
      },
      "gaze": {
        "runtime": "onnxweb",
        "accelerator": "webgpu",
        "providers": [
          "webgpu"
        ],
        "updated_at": "2026-06-21T13:47:13.297Z"
      }
    },
    "status": {
      "level": "info",
      "message": "Models loaded",
      "updated_at": "2026-06-21T13:47:13.297Z"
    },
    "preview": {
      "head_detected": true,
      "eye_count": 2,
      "width_ratio": 1.545,
      "updated_at": "2026-06-21T13:49:54.535Z"
    }
  }
}
```

When you want to reference only the value of `snapshot.gaze`.

```bash
websocat ws://127.0.0.1:47892/events | jq ".snapshot.gaze"
```

Result sample.

```json
{
  "x_norm": 0.11871259729371653,
  "y_norm": 0.9999610338958298,
  "raw_x_norm": 0.3875164253126151,
  "raw_y_norm": 0.19849362020119093,
  "x_px": 2863.9042490719144,
  "y_px": 1439.9438888099949,
  "confidence": 0.9965733289718628,
  "distance_m": 0.4088227492034837,
  "head_face_width_ratio": 1.545,
  "eye_position_weight_x": 1,
  "eye_position_weight_y": 0.25,
  "gaze_projection_mode": "binocular-screen",
  "detect_inference_ms": 26,
  "gaze_inference_ms": 15.600000001490116,
  "inference_ms": 41.600000001490116,
  "yaw_deg": 6.016508449224943,
  "pitch_deg": -7.327657436482831,
  "updated_at": "2026-07-02T23:43:06.135Z"
}
```

The WebSocket sends a `snapshot` event on connect and `update` events after state changes. The snapshot uses `schema_version: 1` and includes latest-known `runtime`, `display`, `camera`, `gaze`, `calibration`, `models`, `status`, and preview metadata. Preview image data is intentionally omitted from the external snapshot.
Browser-originated WebSocket handshakes are rejected; connect with an originless local native or command-line client such as `websocat`.

Snapshot fields are latest-known values. Slices can be `null` before the app has enough data, and fields that are not known yet are omitted from JSON responses.

```ts
type ExternalSnapshot = {
  schema_version: 1;
  started_at: string; // ISO timestamp
  updated_at: string; // ISO timestamp
  runtime: RuntimeState | null;
  display: DisplayState | null;
  camera: CameraState | null;
  gaze: GazeState | null;
  calibration: CalibrationState | null;
  models: {
    detector: ModelState | null;
    gaze: ModelState | null;
  };
  status: StatusState | null;
  preview: PreviewState | null;
  paused: boolean; // renderer-reported pause flag (⌘⇧P / pause_toggle)
  calibration_status: string | null; // renderer-reported calibration phase
  settings: Record<string, unknown> | null; // live settings.json contents
};

type RuntimeState = {
  name?: "onnxweb";
  accelerator?: "webgpu" | "wasm" | string;
  updated_at: string;
};

type DisplayState = {
  display_index?: number;
  requested_display_index?: number;
  display_count?: number;
  bounds?: { x?: number; y?: number; width?: number; height?: number };
  invalid_display: boolean;
  display_size_inch?: number;
  display_width?: number;
  display_height?: number;
  updated_at: string;
};

type CameraState = {
  camera?: string;
  camera_resolution_name?: string;
  camera_width?: number;
  camera_height?: number;
  camera_fov_deg?: number;
  camera_screen_x?: number;
  camera_screen_y?: number;
  eye_position_weight_x?: number;
  eye_position_weight_y?: number;
  updated_at: string;
};

type GazeState = {
  x_norm?: number;
  y_norm?: number;
  raw_x_norm?: number;
  raw_y_norm?: number;
  x_px?: number;
  y_px?: number;
  confidence?: number;
  distance_m?: number;
  iris_distance_m?: number;
  distance_source?: "iris" | "head";
  eye_open?: number;
  blink?: boolean;
  head_turned?: boolean; // head rotated past the tracking envelope — frames held
  gaze_filter?: "saccade" | "oneeuro" | "ema" | string;
  gaze_state?: "saccade" | "dwell" | "fixation"; // saccade filter only
  tracking_source?: "detector" | "iris";
  held_reason?: string; // why output is held: "head_turned", "no_face", "eye_<validity>"
  filter_velocity_deg_s?: number; // saccade-filter eye velocity
  capture_ms?: number;
  preview_ms?: number;
  processed_fps?: number;
  frame_interval_ms?: number;
  head_face_width_ratio?: number;
  eye_position_weight_x?: number;
  eye_position_weight_y?: number;
  gaze_projection_mode?:
    | "legacy"
    | "binocular-screen"
    | "binocular-convergence";
  detect_inference_ms?: number;
  gaze_inference_ms?: number;
  inference_ms?: number;
  yaw_deg?: number; // metric head pose vs session baseline (Kabsch fit);
  pitch_deg?: number; // absent when the mesh fit degenerates — no fallback,
                    // eye angles are not head pose
  updated_at: string;
};

type CalibrationState = {
  path?: string;
  status?: string;
  count?: number;
  saved_path?: string;
  message?: string;
  raw_projection?: "unclipped-v1" | "unclipped-v2" | "featuremap-v3";
  legacy_calibration?: boolean;
  affine?: number[][];
  rbf?: {
    sigma: number;
    centers: [number, number][];
    weights: [number, number][];
  } | null;
  geometry?: {
    eye_position_weight_x: number;
    eye_position_weight_y: number;
  } | null;
  source_bounds?: {
    min?: [number, number];
    max?: [number, number];
    margin?: number;
  };
  samples?: Array<{
    raw: [number, number];
    target: [number, number];
  }>;
  validation?: Array<{
    raw: [number, number];
    target: [number, number];
    error: number;
  }>;
  read_error?: string;
  updated_at: string;
};

type ModelState = {
  runtime?: "onnxweb";
  accelerator?: "webgpu" | "wasm" | string;
  detector?: "retinaface" | "yolo" | string;
  model?: string;
  providers?: string[];
  updated_at: string;
};

type StatusState = {
  level?: "info" | "warning" | "error";
  message?: string;
  updated_at: string;
};

type PreviewState = {
  head_detected: boolean;
  eye_count?: number;
  width_ratio?: number;
  updated_at: string;
};
```

`x_norm` and `y_norm` are normalized gaze-marker coordinates on the selected display. `x_px` and `y_px` are desktop pixel coordinates computed from the selected display bounds, so multi-monitor offsets are included. `raw_x_norm` and `raw_y_norm` are the unclipped projection result before calibration correction and smoothing; they can fall outside 0–1. The `preview` slice is available in the full `/snapshot` response and WebSocket events, but there is no `/snapshot/preview` endpoint.

WebSocket message shapes:

```ts
type SnapshotEvent = {
  type: "snapshot";
  snapshot: ExternalSnapshot;
};

type UpdateEvent = {
  type: "update";
  changed: Array<
    | "runtime"
    | "display"
    | "camera"
    | "gaze"
    | "calibration"
    | "models"
    | "status"
    | "preview"
    | "paused"
    | "calibration_status"
    | "settings"
  >;
  snapshot: ExternalSnapshot;
};
```

When RetinaFace is used, distance estimation still needs the `16cm` Head-width assumption. RetinaFace Face width is narrower than Head width, so the static source constant `RETINAFACE_HEAD_FACE_WIDTH_RATIO = 1.545` converts Face width to Head-equivalent width before distance estimation. The current ratio is shown in the lower-right status area and the PiP preview.

Experimental binocular projection modes can be selected with `--gaze-projection-mode`. `legacy` keeps the original behavior, averaging the left/right eye gaze angles before projection. `binocular-screen` projects each eye separately to the screen plane and averages the two hit points. `binocular-convergence` estimates the closest point between the left/right gaze rays and uses that point as the screen hit position; if the rays are unstable, it falls back to `legacy`.

These binocular modes are approximations from the model's per-eye yaw/pitch and 2D eye positions, not a true optical vergence measurement. Because the raw point distribution can change between modes, use a separate calibration file when comparing them:

```bash
pnpm dev -- --gaze-projection-mode binocular-screen --calibration-file .gaze_calibration.binocular-screen.json
pnpm dev -- --gaze-projection-mode binocular-convergence --calibration-file .gaze_calibration.binocular-convergence.json
```

## Tray & Settings

In standalone runs (no `--no-tray`), a menu-bar tray icon shows the tracker state (`Tracking` / `Paused` / `No face` / `Calibrating` / `Needs calibration`) and offers `Recalibrate` (same path as `⌘⇧G`), a `Pause Tracking` / `Resume Tracking` toggle (same as `⌘⇧P`), dot-size and dwell-lock controls, diagnostic toggles (preview, status panel, inference time), and `Quit`.

User-facing toggles persist to `settings.json`, written next to the calibration file (so a custom `--calibration-file` puts settings beside it). The file is created on first write; a missing or corrupt file is treated as `{}`. Shape:

```json
{
  "version": 1,
  "dot_scale": 1.0,
  "dwell_lock": false,
  "show_camera_marker_on_start": false,
  "diagnostics": {
    "preview": false,
    "status": false,
    "inference_time": false
  }
}
```

The renderer reads it through the `getSettings`/`setSettings` bridge and reports live state (`paused`, `calibration_status`, `settings`) back through `reportState`, which is what the `/snapshot` slices above expose.

## If Nothing Appears

`pnpm dev` uses Vite on port `5173`. If an old dev server is still running, startup is stopped to avoid connecting to the wrong renderer. Stop the old process first.

Because the default window is transparent, renderer load failures or display selection mistakes can be hard to see. First verify with a normal window:

```bash
pnpm dev -- --debug-overlay
```

In the normal transparent overlay, mouse events pass through to the application behind it. Clicks pass through even when the red gaze marker, PiP, status panel, or camera position marker is visible. The camera position marker is shown as an upward arrow with the `Camera position` label. To avoid gaze-marker flicker, the OS window shape is not updated by default. Try `--shape-overlay` only in environments where normal click-through does not work. `--debug-overlay` is the only mode where the overlay receives normal window input.

Startup logs include display entries such as `Display 0` and `Display 1`. If the overlay appears on the wrong monitor, specify `--display-index`. When `--display-index` is omitted, the primary display is used.

## Pursuit Calibration

The app can run without calibration. To calibrate, start it with `--calibrate` — or press `⌘⇧G` at any time for a quick patch.

```bash
pnpm dev -- --calibrate
```

Calibration is a *pursuit* tour: a target glides through waypoints while the app continuously samples the gaze feature stream and tags each frame with the target's interpolated position — no hold-still-and-stare per point. Three tiers trade coverage for time (`--calibration-tier`):

- `full` (default): 17-waypoint 4×4 grid including deep corners — the corners are where iris signal is thinnest, so they get real training data rather than extrapolation.
- `standard`: 9-waypoint 3×3 grid.
- `quick`: corners + center, ~10s. This is what `⌘⇧G` runs — a patch for a drifted or moved setup, refitted against the persisted sample pool rather than the 5 new points alone.

After the tour, a verification sweep samples a second pass and gates the fit on median / p90 reprojection error; a failing gate retries without replacing a previous saved calibration.

The fit itself runs a regularized linear map over a ~40-dim feature vector (eye angles, head-pose proxies, iris-in-box offsets, mesh geometry, head-frame position, jaw-delta, and the optional appearance-model yaw/pitch), falling back to affine+RBF when the feature map doesn't earn its complexity on leave-one-out error. The choice is stored in the calibration file (`featuremap-v3` format) along with fitted geometry weights, raw input bounds, verify verdict, an optional drift offset, and up to ~800 feature samples.

**Continuous learning**: when the OS cursor sits idle while your gaze dwells on it, the tracker treats that agreement as a trusted label and refits silently in the background — the map keeps improving the longer you use it, and the sample pool persists across restarts.

**Drift self-healing**: consistent one-directional rejection of implicit labels is read as a camera/laptop move; the measured offset is applied as a persistent `output_offset` so tracking stays correct without a recalibration prompt, then absorbed into the map by the next implicit refit. Only a saturated correction (something beyond a reposition) surfaces the `⌘⇧G` notice.

**Exit**: during calibration or the accuracy test, the `×` button (top-right) or `Escape` cancels cleanly — nothing partial is written.

The live marker gates out blink frames (freezing at the last position while eyes are closed and ~140ms after reopening), passes saccades through unfiltered, and anchors sustained fixations — the default `saccade` filter. `--gaze-filter oneeuro`/`ema` restore the older filters. The calibration flow follows [Tobii's calibration guidance](https://www.developer.tobiipro.com/commonconcepts/calibration.html).

## Estimation Assumptions

- Camera input defaults to `HD`/`720p` (`1280x720`) with a warned `VGA` (`640x480`) fallback when the device refuses, and can be changed with `--camera-resolution`. Horizontal FOV defaults to `90°` and can be changed with `--camera-fov`.
- The camera is assumed to be mounted at the top center of the target display.
- For the vertical direction, the app estimates eye height relative to the camera center from the face/eye bbox Y position and projects it to screen coordinates assuming the camera is at the top center of the display. If the face moves upward in the camera frame, the marker moves upward; if the face moves downward, the marker moves downward.
- Adult average Head width is assumed to be `16cm`. The eye-to-display distance is estimated from the detected face/head bbox width.
- When the gaze model resolves a plausible iris diameter, distance is instead estimated from a nominal `11.7mm` iris diameter (the MediaPipe iris technique), which removes most of the head-width assumption error; the head-width estimate remains the fallback. Distance is EMA-smoothed across frames (`alpha 0.35`). `--no-iris-distance` disables this.
- With RetinaFace, Face width is converted to Head-equivalent width using the static Head/Face ratio `1.545`.
- Eye openness is estimated per frame from the eyeball mesh eyelid contours; frames below the open threshold are treated as blinks and excluded from the marker update and calibration samples.
- By default, RetinaFace left/right eye landmarks are used to compute the gaze-model crop center.
- `--gaze-projection-mode binocular-screen` and `binocular-convergence` use left/right gaze angles separately; they are experimental approximations and should be calibrated separately from `legacy`.
- With `--detector yolo`, WholeBody28 class id `7` is Head, class id `17` is Eye, and class id `19` is Mouth. Head and Mouth use `--score-threshold`; Eye uses a fixed score threshold of `0.20`.
- With `--enable-lip-motion`, Mouth crops include pixel margins of top `2`, bottom `6`, left `2`, and right `2`, are resized to `48x30`, converted to RGB `0.0-1.0`, and passed to `vsdlm_l`; `prob_open >= 0.50` is treated as open.

## Known Limitations

- Absolute position accuracy degrades without calibration if the camera is far from the top center of the display.
- Iris-diameter distance estimation assumes a `11.7mm` iris and a plausible camera FOV; implausible estimates (closer than `0.15m` or farther than `3m`) fall back to the head-width estimate, which still drifts when the user's actual Head width differs from the `16cm` assumption.
- Glasses, strong backlight, dark scenes, or large face rotation can destabilize Eye/Head detection or gaze estimation.
- When multiple people are visible, the highest-score Head is selected.

## Verification

```bash
pnpm build
npx vitest run
```

## Citation

If you find this project useful, please consider citing:

```bibtex
@software{katsuya_hyodo_2026_20771714,
  author    = {Katsuya Hyodo},
  title     = {screen-eye-tracking},
  year      = {2026},
  month     = {jun},
  publisher = {Zenodo},
  version   = {1.0.0},
  doi       = {10.5281/zenodo.20771714},
  url       = {https://github.com/PINTO0309/screen-eye-tracking},
  abstract  = {A desktop application that estimates where the user is looking on the selected display and renders a red gaze marker at the estimated hit position.},
}
```
