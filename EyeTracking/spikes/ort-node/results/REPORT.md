# P2a — ort-node CoreML spike report

Machine: MacBookPro17,1 / Apple M1 / 8 GB / arm64 / node v26.8.1
Seed 42; generated 2026-10-19T06:14:59.006Z; bar: cadence-weighted effective p50 ≤ 66.7 ms (≥15 FPS).

## Per-model results (ms, p50 / p95; RSS peak MB)

| model | role | cad_hz | coreml p50/p95/RSS | cpu p50/p95/RSS | wasm p50/p95/RSS |
| --- | --- | --- | --- | --- | --- |
| gaze_1x3x160x160.onnx | estimate | 15 | 3.86 / 6.38 / 557 bound | 129.80 / 151.72 / 379 | 456.53 / 530.57 / 625 |
| gaze_Nx3x160x160.onnx | off | 0 | 5.11 / 5.56 / 163 bound | 134.27 / 251.23 / 371 | 460.86 / 597.38 / 742 |
| mobileone_s0_gaze.onnx | appearance | 5 | 1.46 / 1.82 / 204 bound | 35.58 / 41.98 / 308 | 133.60 / 170.17 / 276 |
| retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx | detect | 1 | run_error | 40.26 / 45.13 / 306 | 101.97 / 110.50 / 276 |
| vsdlm_l.onnx | lip | 0 | 0.48 / 0.65 / 227 bound | 2.77 / 4.72 / 297 | 8.04 / 11.66 / 203 |
| yolomit_t_wholebody28_1x3x480x640.onnx | detect | 1 | 9.90 / 15.08 / 308 bound | 111.50 / 128.31 / 304 | 348.49 / 602.59 / 103 |

## CoreML binding (separate --profile pass)

| model | bound_nodes | total_nodes | profile |
|---|---|---|---|
| gaze_1x3x160x160.onnx | 3 | 6 | results/profiles/gaze_1x3x160x160-coreml.json |
| gaze_Nx3x160x160.onnx | 6 | 18 | results/profiles/gaze_Nx3x160x160-coreml.json |
| mobileone_s0_gaze.onnx | 3 | 3 | results/profiles/mobileone_s0_gaze-coreml.json |
| retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx | 7 | 22 | results/profiles/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70-coreml.json |
| vsdlm_l.onnx | 6 | 12 | results/profiles/vsdlm_l-coreml.json |
| yolomit_t_wholebody28_1x3x480x640.onnx | 9 | 18 | results/profiles/yolomit_t_wholebody28_1x3x480x640-coreml.json |

## Chain (cadence-weighted effective per-frame cost @15 FPS target)

| EP | effective_ms | fps | eff_ms (default det.) | strict_ms | weighted p95_ms | RSS max MB |
|---|---|---|---|---|---|---|
| coreml | 5.01 | 199.6 | 4.35 † | 20.82 | 7.99 | 557 |
| cpu | 151.78 | 6.6 | 144.35 | 454.19 | 177.27 | 379 |
| wasm | 531.09 | 1.9 | 507.86 | 1509.49 | 634.83 | 742 |

Bar: weighted effective p50 ≤ **66.7 ms** (15 FPS).

`eff_ms (default det.)` = estimate + retinaface-p50×(1/15) + appearance-p50×(5/15). † default detector not ok on this EP — its term is 0 in that cell; see the caveat below for the honest detector-on-CPU figure.

Caveat: retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx run_error under CoreML (zero-element NMS output rejected: Non-zero status code returned while running 9725669114890332002_CoreML_9725669114890332002_6 node. Name:'CoreMLExecutionProvider_97256691148...). With the default detector on CPU EP instead: effective ≈ 7.03 ms (142.2 FPS) — verdict unchanged.

**Verdict: PROMOTE — coreml weighted effective p50 5.01 ms (199.6 FPS) ≤ 66.7 ms on this machine. load/run errors: retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx@coreml.**

