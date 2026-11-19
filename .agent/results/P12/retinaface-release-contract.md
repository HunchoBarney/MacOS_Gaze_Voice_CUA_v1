# KAR-30: portable RetinaFace release profile — decision and G2

Decision (2026-11-17): a future portable release may admit RetinaFace and
the single-image gaze estimator only. This is not a waiver on the existing
four-model development profile or the immutable C1 overlay. The earlier
tracker package contract cannot be used to declare the new profile ready.

Default FAIL. Before provisioning, staging, signing or archiving, the two
exact weight digests and their upstream grants/notices must be reviewed;
review of code licensing is not review of the trained weights. The tracker
release, Node, Electron/Chromium, ONNX Runtime distribution (WebGPU and
WASM variants), native module and transitive notices require independent
attribution review. Unknown rights or archive identity blocks distribution.

| Required model | Exact SHA-256 |
| --- | --- |
| retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx | 8a481f206b150e41b311f2176fd8c5d1ab4afa2ab0cbcbbfb037007b5260c023 |
| gaze_1x3x160x160.onnx | 5010f28c53d18100f067b129e4afca31d574a877d022e4eaebcf8e32e7b9654a |

Provision and copy only these entries from a reviewed source. In the final
tracker model directory require exactly two regular files, no nested
directory or symlink, and both digests. Elsewhere in the payload reject
hidden aliases, alternate ONNX files and copies of excluded model bytes
under unrelated names. Preserve the expected internal public/models alias,
not a host/developer lookup. Reject YOLO, lip, appearance and model-path
overrides for release only; do not attempt even an unused lip/appearance
copy. Retain calibration and the existing WebGPU → WASM/CPU recovery.

Use a release-owned app marker outside the tracker payload so removing or
corrupting the tracker never falls back to a development profile. Resolve
only the bundled tracker, launcher, Node, Electron and compiled renderer;
decline an unrelated responder rather than adopt it. Preserve standalone
development's experiments. Verify the generated Vite manifest, HTML entry,
CSS, static and dynamic chunks and worker from one fresh build, then check
the same subject after archive extraction. Never modify the old gaze seal.

Owned consumers: P12 provisioning/staging and archive checker, release
Info/marker, TrackerHost resolution/adoption, tracker launcher/main and
the renderer's model configuration. Tests: missing/corrupt/extra/symlinked
weights, renamed YOLO copy, malformed or absent marker, experiment args,
missing worker/manifest/chunk, mixed build, external source/runtime/Node
decoys, preserved CPU fallback and development behavior. A fixture is not
a signed archive, M1 resource result, real launch or calibration outcome.

Reuse the existing Vite/ORT, published strict checker, native packaging
tools, pinned model hashes and existing app profile machinery. No new
download service, inference model, physical launch or signing authority.
G2 for a distributable profile remains **held** until exact rights and
consumer review are recorded. Pure comparisons and negative fixtures
may run without copying model weights.

**G2 findings and decision.** Independent reviews 36/37 held distribution.
GitHub tracker release assets
[452847814](https://api.github.com/repos/PINTO0309/screen-eye-tracking/releases/assets/452847814)
and [452847635](https://api.github.com/repos/PINTO0309/screen-eye-tracking/releases/assets/452847635)
identify the two files; neither asset supplies a weight-specific grant.
The [tracker license](https://github.com/PINTO0309/screen-eye-tracking/blob/48b7e37/LICENSE)
is a software license, not established provenance for either checkpoint.
The possible [InsightFace lineage](https://github.com/deepinsight/insightface#license)
for gaze is a restriction warning, not a proven license assignment. Lip
VSDLM and YOLO are excluded: the development release asset IDs are
454748513 and 455040336. MobileOne appearance is not an admitted weight.

ORT 1.30.0 needs its MIT license and applicable compiled-in
[third-party notices](https://cdn.jsdelivr.net/gh/microsoft/onnxruntime@v1.30.0/ThirdPartyNotices.txt).
Electron 42.4.1 carries LICENSE and LICENSES.chromium.html, nut-js/libnut
and its native module carry Apache notices, and node-mac-permissions has an
MIT notice. Verify the whole actual binary/notice inventory, including the
bundled Node upstream identity and matching full license, before approval.
A local hash alone is not a portable Node provenance or license receipt.

The source release preflight currently refuses before any dependency
fetch, copy, signature or archive, including direct release bundler calls.
The prepared profile stamps the app and package, permits only hosted
arguments, and excludes development roots/host Node and endpoint overrides.
A phase beyond this checkpoint must also authenticate post-spawn readiness
and gaze events to the same process generation: localhost, a surviving
Process handle or a successful /health response does not establish that.
This producer/consumer invariant needs a versioned contract and review of
TrackerHost, GazeClient, GazeStream and the tracker API before activation.
