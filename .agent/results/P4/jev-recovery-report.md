# P4 Evidence Recovery

Recovery date: 2026-11-10.

## Result

The current signed baselines and the evidence needed to resume D9b preparation
are recovered. No archive destination or cause of the disappearance is confirmed.
Recovery uses local editor history and unchanged local iCloud upload-cache copies,
not reconstructed test outcomes.

The isolated D9b candidate pair now builds and passes strict signing and frozen
payload checks. Neither candidate is installed or desktop-qualified.
The pilot stops before a Jev command. P4 remains open.

## Verified

- Both baseline apps pass `codesign --verify --deep --strict` on owned temporary
  copies outside the synced checkout. Only those temporary copies have metadata
  cleared. The source cache is not modified.
- Both complete manifests match their original saved hashes: 5,592 entries each,
  including file bytes, modes, and symlinks.
- The baseline stage receipt matches saved SHA256
  `2e627fcb985cf5f3fe3632becaec3b2d5bbf6f83f9809adc2bc705a284adff54`.
- All 104 production-source hashes match the recovered canonical D9b record.
- The original source review and 317-test log match the hashes recorded in the
  recovered native admission. These remain historical source/test evidence,
  not new live-app results.
- The four original unsigned native driver/SDK artifacts and both original
  vendor pins are restored without an upgrade or binary substitution.
- The restored build guard passes its three original checks. Its 5 GiB start
  floor and 1 GiB stop floor are unchanged.
- All 52 restored harness checks pass. The first run failed one check because
  an old stage receipt was still missing. Restoring the actual cached receipt
  makes the unchanged check pass; the failed run remains recorded.
- With explicit network approval, locked FluidAudio 0.17.5 is restored at
  `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`. `Package.resolved` is unchanged.
- The complete Cua checkout is restored at the pinned upstream commit. Its
  actual binary diff reproduces reviewed patch SHA256
  `a55c1bc4df40cc1e960500a4b2a60cf362b65615b39ebda6680462daa3037b30`.
  Neither of the two surviving files is overwritten.
- The guarded release build completes in 424.82 seconds. Both new signed apps
  retain their original driver, SDK, and other nested runtime payloads.

## Locations

Canonical apps, manifests, and receipt:

`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/staging/vision-pinned-owner-20261110.artifacts/native-ancestor-frozen-stage`

Recovery inventories, immutable objects, verification, and restoration records:

`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/recovery-20261110`

Key records there are `baseline-full-manifest-check.json`,
`baseline-signature-check.json`, `exact-reference-restoration.json`,
`harness-history-restoration.json`, `reference-recovery-graph.json`,
`pinned-vendor-restoration.json`, and `recovered-harness-tests-r2.log`.

Files are created only where missing. Surviving work is not overwritten.
Editor snapshots are labelled as the latest available snapshot unless a separate
receipt authenticates the version.

## Current Preflight Failure

The single pilot fails while starting the unchanged captured-native driver.
The separate read-only diagnostic also fails on the unchanged coordinate
driver. Neither reaches Jev or sends desktop input. Both clean up their owned
processes.

The diagnostic sample is taken about 10.244 seconds after process launch. All
806 samples remain in `_dyld_start`; the process footprint is 112 KiB and no
driver binary images are available. The daemon reports listening later.
This identifies a pre-code-entry loader delay, not a D9b completion result.
The 10-second readiness guard is unchanged; the startup cause still needs
qualification rather than repeated retries until green.

Evidence lives under
`completion-research-20261110/delivery-recovered-startup-diagnostic/before/`,
including `startup.stack.txt`, `startup.stderr`, and `results.json`.

The original synthetic TextEdit window's disk fixture was also missing.
Only that fixture's disk baseline is newly materialized from the recorded
marker and unchanged runner recipe. This is labelled new fixture preparation,
not a recovered historical artifact. The original process birth matches its
recorded lease. Live window, path, and complete body checks remain mandatory
before input; startup failure means they have not run yet.

## Remaining Gaps

- Some superseded bundle-delta archives and an old module-cache backup remain
  missing. They are not reported as recovered or recreated.
- A compatible visual fixture source is preserved from the upload cache at
  SHA256 `27ba1284dbc3949bc1b738e8ca17e84d89351472bfaca17c16b22b745285bde1`.
  Its historical source receipt is not found; visual qualification needs a
  fresh, explicitly identified fixture build.
- Controlled desktop qualification, reliability/latency budgets, human
  evidence, and the final independent P4 verdict remain unproven.

The daily app, other documents and windows, playback state, and shared unrelated
source changes are untouched. No original evidence is replaced by a reconstructed
test outcome.
