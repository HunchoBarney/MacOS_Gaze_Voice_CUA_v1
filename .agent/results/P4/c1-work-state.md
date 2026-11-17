# C1 continuation record

Implementation remains active. User approved all C1, unlimited Jev,
read-only G2/G4 reviewers one at a time. No commit/push/merge/distribution
or daily-app replacement. Do not stop at this source milestone.

## Finished

- Concrete contract `c1-implementation-contract.md`, G2 PASS from
  reviewer `1ccd62bc` after consolidated corrections. Same reviewer
  approved the narrow GazeService defaults-store amendment.
- Initial fingerprint: `c1-baseline-source.json`, 208 source/test/build
  files, 345 inherited status entries. Preserve inherited dirt.
- Authority repairs in VisualGoalProof/JevVisualDecision:
  raw requirement scores stay independent; native literals cannot bypass
  completion/hidden-state gates; native/pixel/open scroll and click
  authorization is independent; weak/plurality referents cannot promote
  identity or erase ambiguity; selected multiple literals need bound
  permission; unchanged evidence is not redrawn to clear thresholds.
  Native literal presence is a separate code fact, not an invented
  probability. Exact comparison preserves whitespace and UTF-8. Identical
  pixels no longer establish subject identity; changed native documents
  fail closed. Legitimate native geometry/document facts remain usable.
- Dwell absent/invalid/unmarked legacy safe is off. Legacy all is
  retained because the writer audit found no automatic all writer.
  Explicit Settings choices persist `gaze.dwellExplicitOptIn=explicit-v1`.
  Learned writes do not create consent; minimum delay is 1 second.
  GazeService uses one injected defaults instance, default standard.
- Existing tests were extended before repairs. Initial source reproduced
  48 failed assertions; follow-up before logs preserve additional defects.
  Final: 380 consumer tests, 73 p11 tests, 27 Python evidence tests pass.
  Logs: `c1-authority-final.log`, `c1-p11-isolated-after.log`,
  `c1-p3-evidence.log`. This is not real-app or physical acceptance.
- Added `c1-authority` and `p11` verification-lane modes.
- Restored ONLY `.agent/results/P3/test_verifier.py` from sibling
  `jarvis-v1-p3-semantic-closeout`; hash/provenance in PROGRESS.

## Still to do

Performance baseline and implementation, signed candidate/manifest,
P12-M0 nonempty offline lane, full `all` verification, fresh independent
G4, matched real-app results/report, short physical Fn/pill checklist,
phase decisions/handoffs and ownership checks. Acceptance flags unchanged.
Wispr was absent from checked /Applications locations; no parity claim.

Use `enliven`, TypeSafe and immune-system methodology already loaded.
No new helper agents except the authorized reviewer. Measure before
changing speech/native code; none of those performance paths has changed.

## Concrete starting points

- `Sources/JevVoice/Voice/LocalSpeechSession.swift` is the correct path
  (contract typo corrected). `Intelligence/LocalTranscriber.swift` already
  starts whole-hold Ultra without waiting for EOU, uses CPU-only final
  decoder/ANE encoder, and defers provisional EOU when its old tail is
  busy while still admitting a new accurate hold. Do not reimplement these.
- Existing signed typing harness:
  sibling `.agent/results/P3/normal-voice-qualification/run-speed-ab.py`
  imports `typing-repair/run-packaged-check.py` and
  `physical-20261105/run-focus-window-density.py`.
  It exercises the normal controller, owned TextEdit fields, native
  insertion/readback and decoy preservation. It is not physical ASR/Fn
  proof. Inspect flags/cleanup before reuse; helpers can stop/restore the
  daily process, never overwrite it.
- Native ASR replay: existing `NativeSpeechTailReplayTests.swift` and
  lane `p3-native-tail` (release). Uses actual h15 audio/models and explicit
  `JARVIS_P3_NATIVE_TAIL` readiness/run-ID flags. Inspect before running.
- Sibling P3 `speech-evidence/` holds bench-execution.py, reports, recorded
  audio/evidence and prior signed-profile tools. Import only required
  assets with hashes; current root has only test_verifier restored.
- Referenced `.agent/results/P4/jev-stage-candidate.py` is MISSING.
  Available staging helpers: `jev-clone-stage.py`, `jev-vision-stage.py`.
  Reuse their source/resource digests, signature/requirement checks,
  APFS cloning and root signing. Their old CLI admissions are specific to
  historical templates; C1 needs its own explicit current manifest, not
  an old grant reused or bypassed.
- Daily app `~/jarvis-local/Jev Voice.app`: unchanged f6abbe... binary,
  strict deep signature valid. Bundle version 6. Resources: cua-driver,
  EyeTracking, CodexRuntime, EyeTracker, ThirdParty. Driver signed hash
  b81de36... in Info.plist; canonical source pin raw b4d974... is 0.38.0.
  Canonical Codex 0.160.0 raw 112fae7... . Reconcile signing provenance
  and staged 0.45.4 before selecting candidate bytes; no silent swap.
- Existing vision-stage receipt JSONs reference native admission files
  `jev-exact-native-facts-native-admission.json` and
  `jev-native-provenance-native-admission.json`. Their old temp apps no
  longer exist. 0.45 runtime is in the vision-driver worktree.
- Keep staging/signature verification outside synced Documents; use the
  desktop lock for actual GUI operations. No currently running test shell.

## Baseline/diff preservation

`c1-before/` preserves SHA-verified original GazeService, DwellClick,
SettingsView, and the DwellClick/GazeService/TrackerFlow test files
(recovered from unchanged source/sibling copies). Initial hashes for
JevVisualDecision, VisualGoalProof, JevVisionTests and the lane exist but
their original full bytes were not copied at session start. Their C1
patches are in the session transcript. `explicit-decision-before/` has
older copies of JevVisualDecision/JevVisionTests, not yet compared to the
initial hash. Do not pretend a HEAD diff excludes inherited work.
Freeze a complete source snapshot before performance edits.

## M2 baseline now captured (latest continuation)

Do not restart M1 or repeat baseline collection unnecessarily.

- `c1-performance-before/manifest.json` and its tree preserve **207**
  complete source/test/build files after verified M1 and before any speed
  changes. No production performance source has been edited yet.
- Release build passed through `p3-typing-package`, evidence
  `c1-performance-before-build.log`, 297.62s build.
- Added the previously missing P4 staging helper
  `.agent/results/P4/jev-stage-candidate.py` and wired its arguments into
  the existing `p4-stage-candidate` mode. It reuses clone-stage digest/
  resource/signature helpers, APFS clonefile, canonical pinned driver/
  Codex and existing `scripts/sign-app.sh`; no installation. The lane
  supplies `JARVIS_VERIFICATION_LANE_HELD=1` and uses jev-build-guard.
  Source snapshot validation covers production Swift/Info/Package files;
  the lane itself changed after the snapshot only to expose staging.
- **Signed baseline app**:
  `/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-c1-before-tjbmt7hv/Jev Voice.app`
  SHA256 **29b4d4f9457f0b2924afd37a61234ae42301c9b458050b3874798757ffcbf8c5**.
  Receipt `.agent/results/P12/c1-before-stage.json`, log adjacent.
  Strict signature, source/rollback preservation and same designated
  requirement/entitlements verified. Stage took canonical raw b4d974...
  driver and signed it. Whole-file signed SHA differs from rollback,
  but BOTH driver CDHashes are
  `7d6866051aa3a2f9c7ed9f397d820ce97bda5cf6`; same signed code/identity.
  Record this CDHash reconciliation in final P12 component manifest.
  Raw canonical driver exits -9 if run loose (foreign original signature);
  signed bundled driver reports `cua-driver 0.38.0`, as expected by
  sign-app.sh. Do not mistake the raw -9 for a candidate failure.
- Restored 3 more existing helper files, unchanged, with provenance in
  `c1-harness-imports.json`: normal-voice-qualification/run-speed-ab.py,
  typing-repair/run-packaged-check.py,
  physical-20261105/run-focus-window-density.py.
- **Real native typing baseline PASSED 3/3** via desktop lock and exact
  signed app. `c1-native-before.log`; authoritative result
  `.agent/results/P3/normal-voice-qualification/speed-c1before/results.json`.
  Three fresh app processes; normal controller scripted typed input,
  NOT microphone/Fn latency or warm steady-state qualification.
  Times **2265.1988335419446, 2386.8579999543726,
  7428.993625100702 ms**. Exact insertion, unchanged decoy, one native
  dispatch, no model rounds, unchanged document count all asserted.
  The runner closed only its own test documents and restores daily
  process if one was running; no daily app replacement.
- Native trace has `monotonic` timestamps. Main costs:
  context 343.7/398.9/340.7ms; gaze await 345.9/15.3/1052.8ms;
  resolver 923.2/807.9/3056.7ms. Native insertion itself
  3.5913/3.5874/19.4123ms. Third run has another ~1893ms between
  resolve end and insertion begin. Do not attribute all of this to driver.
- **Signed actual-ASR replay PASSED 35/35**, no missing cases, zero
  wrong critical actions. Output
  `.agent/results/P3/c1-signed-asr-before.json`, log
  `.agent/results/P4/c1-signed-asr-before.log`.
  Exact production provider/session with real recorded audio, paced
  while speaking; admission boundary only, no GUI insertion/physical Fn.
  Release->authoritative final n35: min117.63062491081655,
  median138.70425010100007, max256.3254584092647ms.
  Six raw word edits /164 reference words. Prepare took
  **67446.83324988ms**, report this startup cost separately.
  Historical signed 34/35 failure did NOT reproduce in current candidate.
  Retain history; don't invent a fresh failure.
  Command: staged binary `--p3-voice-replay --manifest
  Tests/Fixtures/P3/manifest.json --recordings-root
  <sibling>/jarvis-v1-p3-semantic-closeout/.agent/results/P3/audio
  --out <root>/.agent/results/P3/c1-signed-asr-before.json`.
  Run under desktop lock, timeout900. All processes from these runs exited.

### Immediate investigation, bounded to three hypotheses

1. `VoiceTaskCoordinator.swift:809-811` unconditionally awaits
   gazeContextProvider even for a literal already bound to the captured
   field. Default provider at ~1985 calls GazeService.referentContext;
   don't assume network cost, this may be MainActor scheduling delay.
   Consider bypass ONLY for provably non-deictic captured literal
   typing; preserve gaze for any unbound/deictic task.
2. `VoiceTaskCoordinator.swift:1344-1346` calls
   resolver.resolveDetailed for a canonical app bundle with a captured
   window merely because spec.pid is nil. AppResolver.swift:57 owns the
   lookup. Fresh exact NSWorkspace app identity + matching native focused
   window might avoid this broad resolver without changing ambiguity
   behavior. Inspect before designing; do not bypass target validation.
3. `FocusedTextTarget.swift:110-120` observedWindow scans **all**
   onscreen CG windows even though pid and windowID are already captured.
   A native `.optionIncludingWindow` query can narrow the same proof,
   retaining exact PID/window/on-screen checks. Need a diagnostic stack
   or precise trace to support the cost, and keep fresh ownership checks.
   Do not replace visibility with a guessed AX title or window-list order.

No speed edits yet. Write meaningful guards first in existing tests.
`Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift` is the right
consumer but was omitted from the C1 exact owned-path list: amend G2
contract for that path if needed (same read-only reviewer allowed).
Relevant existing test fixture around 210 constructs an AppResolver with
listApps closure; around227 replaces gazeContextProvider.

Focus/scroll baselines still required by C1, as is the combined real
speech->GUI insertion measurement and final human Fn/pill check.
Typed before baseline and ASR replay must stay separately labelled.

### Skills/current docs

Invoked enliven, immune-system and TypeSafe again after the user's
rule refresh. Read enliven + traps and immune-system; adapt methodology
to existing native harness, no new web framework/agent machine.
Live TypeSafe index/Noul/fan-out docs read: independent questions cannot
see one another's answers; do not synthesize probabilities.
Current FluidAudio release lookup found **0.18.3 (2026-11-07)**; installed
and pinned is **0.17.5**, clean tracked dependency tree. No upgrade made.
0.18.3/0.18.2 notes include streaming seam/long-form repairs, not a reason
to replace the already-passing whole-hold final. Measure before selecting
any ASR change and follow the contract's promotion gate.

## Latest M2 implementation and active verification

**ACTIVE shell `1be8cb`** is a finite, sequential pipeline. Read it with
`get_output(timeout=280000)` before doing any build or desktop work.
It runs (stopping on the first nonzero exit):

1. `scripts/verification-lane.sh c1-native`, log
   `c1-native-consumers-r2.log`.
2. Freeze 207 source/test/build files to
   `c1-performance-after-r2/manifest.json` and its source tree.
3. `p3-typing-package` release build, log
   `c1-performance-after-r2-build.log`.
4. `p4-stage-candidate --label after-r2 --snapshot ...`,
   receipt `.agent/results/P12/c1-after-r2-stage.json`.
5. Same desktop-locked run-speed-ab workload, label `c1afterr2`,
   results in P3 `normal-voice-qualification/speed-c1afterr2/results.json`,
   log P4 `c1-native-after-r2.log`.
6. Same signed 35-clip actual-ASR replay, P3
   `c1-signed-asr-after-r2.json`, log P4 `c1-signed-asr-after-r2.log`.

Do not assume later steps completed; inspect the actual receipt/logs.
Do not edit production files while the pipeline is building/staging.
Each finite subprocess has a 900s timeout. No daily installation.

### What the diagnostic actually established

One separate instrumented run was made using
`c1-profile-native.py` (reuses packaged-check's `on_started` callback and
owned-document cleanup). Diagnostic output folder
`c1profile-fb393cb5/`; full result P3
`user-audit-c1profile-fb393cb5/result.json`; log `c1-native-profile.log`.
The run FAILED after ~15.75s with **zero dispatch**, decoy unchanged and
safe owned task/document cleanup. Keep this failure out of timed metrics.

The sampled UI thread contains the 1-second timer in main.swift calling
synchronous TCC status APIs, including repeated microphone reads.
It also contains AVSpeechSynthesizer initialization/stop-speaking waits.
Much of the large initialization sample count is **profiler-induced dyld
notification waiting**. Do NOT call it a normal TTS duration or replace
the TTS engine. Source already uses AVSpeechSynthesizer; it is NOT a
legacy NSSpeechSynthesizer implementation.

The gaze spans are scheduling waits, not proven network or eye costs.
AppResolver already uses exactBundleApps; no driver list-app call there.
The active resolver optimization below avoids an unnecessary await for
an already-native-bound owner, rather than claiming a new resolver SDK.

### Implemented permission polling change

G2 amendment added only `Sources/JevVoice/Settings/Permissions.swift` and
`Sources/JevVoice/main.swift` to original C1 ownership. Reviewer
**8b04b662** first FAILed missing explicit status-only/background API
boundary and grant/wake test coverage, then **PASS** after both were
written into `c1-implementation-contract.md`. No production speed change
preceded that PASS.

- Permissions.swift: `Permission` is Sendable; openSystemSettings stays
  MainActor. New MainActor `PermissionStatusMonitor` runs only the
  status-reading closure in `Task.detached`, at most one read in flight.
  Invalidate cancels its result but does not start overlapping OS calls;
  stop prevents callbacks/restart. No new grant/prompt APIs.
- VoiceController: explicit `refreshPermissions()` remains synchronous
  and invalidates older background status. New background refresh applies
  status on MainActor and reports a denied->granted transition once when
  lifecycle permits preparation. Revocation suspends an active/preparing
  microphone. The prior permission must have been granted (or microphone
  ready) to suspend; an already-denied status must not cancel unrelated
  typed input. Shutdown stops the monitor.
- main.swift: existing 1-second timer uses the background refresh and
  current `canPrepareMicrophone` gate. Removed duplicate microphone
  polling state/read. Grant callback calls existing lifecycle method.
- Tests were written in LocalSpeechTests before the change: main actor
  responsiveness, one in-flight read, stale invalidation/retry, shutdown,
  preparation revocation/grant recovery and sleeping prevention. A
  newly-caught already-denied cancellation regression was reproduced in
  r2 and fixed. Tests use controlled permission status, no new audio or
  model simulation. Test MemoryKeys fixture is private to this file.

`c1-permissions` lane now selects LocalSpeechTests, MicrophoneInputTests,
VoiceLaneAuditTests and VoiceNormalQualificationTests. r1 compile failure
was a missing private MemoryKeys fixture; r2 had two meaningful failed
assertions in already-denied microphone cancellation; **r3 passed 81 tests,
4 skips, zero failures** (`c1-permissions-r3.log`). Skips are existing
gated speech recording checks, not omitted permission checks.

### Measured permission-only candidate (preserved)

- Snapshot `c1-performance-after/manifest.json`; release build passed
  in158.91s (`c1-performance-after-build.log`).
- Signed app:
  `/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-c1-after-e293167x/Jev Voice.app`
  SHA **db03d7c877acdcb1408d42fee09564cb74e859d373a1a8b24ce4a2eecf0d8eb9**,
  receipt P12 `c1-after-stage.json`.
- Native same-harness runs **passed3/3**: exact insertion, one dispatch,
  decoy unchanged, document cleanup.
  Times **1875.8634582627565,2934.0634583495557,1659.7801665775478ms**,
  median1875.8634582627565 versus before2386.8579999543726ms.
  Small n3, fresh processes, not physical/warm latency qualification.
  One ordinal run got slower, retain it. No p95/reliability claim.
- Source cause evidence after: gaze waits20.106/16.646/13.975ms;
  resolver906.345/1434.030/529.981ms remains significant. Context
 424.277/327.924/276.231ms. Native input4.036/19.611/4.817ms.
  Logs `c1-native-after.log`, P3 `speed-c1after/results.json`.

### Second performance change now under verification

`VoiceTaskCoordinator.swift` adds `capturedForegroundPID`: only an exact
canonical bundle matching current NSWorkspace app, positive PID and a
fresh native focused window matching the task's captured window can bind
the PID. This avoids AppResolver await when the owner is already proven.
All aliases, absent/mismatched windows/apps/PIDs keep the original
resolver and ambiguity behavior. No window-list order, cached model
probability, or new permission. Downstream field freshness, deny checks,
visibility, effect verification and cancellation remain unchanged.
Resolution start/end tracing still surrounds either path.

Existing owned FastLaneTests now contains a guard for exact app/window
owner and negative mismatches; written before implementation. Only
already-owned production/test paths changed, no frozen interface.
The new `c1-native` lane includes FastLaneTests, FastLaneExecutorTests,
VoiceTaskCoordinatorLaneTests and FocusedTextTargetTests.

Stager labels now allow `before`, `after`, `after-r2`, `final`; prior
receipts/artifacts cannot be overwritten. Before/after are intact.

### Required remaining work after the active pipeline

Continue C1, don't stop at these measurements. Need:
- inspect after-r2 outcome and pursue/revert based on matched evidence;
- focus/scroll and complete speech->GUI insertion evidence still missing
  (typing and ASR replay are separate clocks/paths); use existing safe
  real-app harnesses, not fake physical claims;
- P12-M0 actual component/model/license/runtime manifest, read-only
  assertions and nonempty `p12` lane with negative controls;
- full integrated lane at frozen candidate boundary, ownership check;
- independently review G4 with a fresh read-only reviewer, one at a time;
- generated report (including slower runs) and updated phase/handoff;
- one short physical Fn/pill check against exact frozen artifact.
  Daily replacement still requires user permission.

Wispr not found under /Applications or ~/Applications in read-only
listing; do not purchase or claim comparison/quality parity.
No ASR model/provider/code change has been made. Before ASR median~139ms
already exceeds50ms goal; report honestly. No Terra/C2/C3 expansion,
commits, pushes, merges, daily install, or acceptance-flag edits.

### Most recent pipeline outputs

Shell `1be8cb` has confirmed native consumer tests, release build, and
after-r2 staging all exited0. Native after-r2 also passed3/3 with exact
insertion/decoy guards, but its measured totals are
**2278.260708320886,2984.9966666661203,2412.9394167102873ms**.
Signed SHA **d18677cff5b2b690f871c5a46e741299c4b620728a4901a328eed8fb03087b01**.
This is slower than the permission-only median and slightly slower than
the original median. **Do not call the PID optimization a speed win.**
Inspect the before/after traces for where the remaining time went and
revert this second optimization if it did not pay; no target weakening.
The ASR after-r2 step was still running at the last get_output. Read
shell `1be8cb` again for completion. Do not run concurrent desktop work.

Pipeline is NOW COMPLETE, exit0; no active build/desktop subprocess.
ASR after-r2 passed35/35, no missing cases, same6 word edits. Finalization
median133.22712504304945ms (before138.70425010100007), min106.8347916007042,
max423.9840831141919ms (before max256.3254584092647: tail regression).
Prepare3063.8904583174735ms vs before67446.83324988ms. ASR code/models
unchanged; do not attribute cache/startup/run variation to our code.

Latest trace comparison is revealing: resolver after-r2 is2.077/1.469/
2.085ms, but resolve-end->native-insert now costs1122.074/1826.405/
1342.864ms. In permission-only it was95.072/522.036/256.865ms while
resolver cost906.345/1434.030/529.981ms. Work appears to move between
stages rather than disappear. Check how setting `work.spec.pid` changes
DriveLoop's native-fast-path/catalog/window/session setup before keeping
the PID change. Do not blindly optimize another span or claim a gain.
After-r2 total executor1162.348/1910.658/1365.181ms; permission-only
1031.279/2025.608/802.088ms. Existing all before/after evidence is retained.

## Current C1 integration boundary (latest; supersedes active-shell notes above)

**ACTIVE shell `62762f`** is now the only pipeline. Earlier shells completed.
Read its output before any build/desktop work. It runs sequentially:
1. `p12` → P12 `c1-offline-validation-r2.log`.
2. Create/verify P12 `component-manifest.json` → `c1-component-validation.log`.
3. Full `all` (Swift + existing P3 verifier + EyeTracking typecheck/Vitest)
   → P4 `c1-integrated-verification.log`.
4. Same desktop-locked signed typing benchmark label `c1final`
   → P4 `c1-native-final.log`, P3 `speed-c1final/results.json`.
5. Same signed35-clip replay → P3 `c1-signed-asr-final.json`,
   P4 `c1-signed-asr-final.log`.
6. New small wrapper around the EXISTING packaged audit runs three
   app-focus cases on BEFORE then FINAL, under desktop lock:
   P4 `c1-focus-before.json`, `c1-focus-final.json` and corresponding logs.
It stops at the first error. Inspect actual logs, not this planned list.

### Final production speed source

The remaining resolver wait in after-r2 was the second call in
DriveLoop.run, which still unconditionally awaited resolveDetailed.
That explained the moved cost. Now both callers use native evidence.
`DriveLoop.capturedForegroundApplication` lives in FastLaneExecutor and
returns the real OS display name, exact bundle and positive PID only
when the AX focused window matches the captured task window. Display name
is retained for existing deny/consent corpus checks. Coordinator binds
that PID. DriveLoop.resolveTaskApplication rechecks the same fresh owner
before skipping its own resolver call; absent/mismatched facts preserve
the original resolver. It does not treat the task's supplied PID alone
as proof. FastLaneTests and FastLaneExecutorTests cover identity
mismatches, fallback and zero redundant resolver calls.

After-r3 native consumer suite/build/staging all passed. Its3 same-harness
native runs passed at **1693.3195416349918,1504.1724999900907,
2108.59916661866ms** (vs before median2386.8579999543726ms).
After-r3 SHA2b41d8fb3a18455631b4454d8b2b32d0c606d006949a39c8adc7b28ebd2e2245.
Snapshot `c1-performance-after-r3/manifest.json` is the current production
source. Native resolver1.589–1.725ms; other preflight713.296–1247.080ms
remains. Native insertion2.473–3.051ms. Cold context255.143–445.981ms.
No warm target, physical latency or ASR speed win is claimed.
No further production edits are currently in flight.

### P12 work now implemented

`p12-stage` is an alias of the existing serialized C1 stager. Final label
adds FluidAudio LICENSE and its ThirdPartyLicenses from the exact resolved
checkout (git revision and LICENSE bytes verified) and the new
P12 `speech-attribution.md`. The existing FluidVoice UI notice is GPL
and is separate from FluidAudio Apache-2.0. Ultra model card states
CC-BY-4.0; streaming EOU upstream states NVIDIA Open Model License.
Weights remain external; no model files or dependency checkout modified.

Final app staged, strict signature passed, no installation:
`/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-c1-final-zfuec7b7/Jev Voice.app`
SHA **c292e12024dc04bfc6a924b0d7f6ceb41a2c1c23ed38ffcba8f404750f9264eb**.
Receipt `.agent/results/P12/c1-final-stage.json`.

New P12 `c1_manifest.py` reuses existing digest/resource/signature helpers.
It binds actual executable, generated plist, sealed resource inventory,
canonical driver vs compiled CuaDependency pin (stdio JSON-RPC; no
separately linked Cua Swift SDK), Package.resolved/FluidAudio, exact
external speech model files/hashes, snapshot, notices and rollback.
Release preflight remains false for external speech models and unfinished
C3 transitive/portable-package qualification.

New P12 `test_c1_manifest.py` (written first) checks actual package,
wrong binary, SDK/driver mismatch, escaped resource path, missing speech
model, and a genuinely removed notice in an APFS clone. The rollback
and real candidate are checked unchanged. `p12` runs nonempty existing
CuaDependencyPinTests, DriverDaemonHostTests, TrackerHostTests,
LedgerSpendTests, then these Python controls.

The initial final pipeline `d444dc` staged successfully, then p12 stopped
with exit75 BEFORE any tests due to4.8GiB available (<5GiB guard).
No guard was reduced. Reclaimed only own intermediate staging trees
after/after-r2/after-r3, archiving their tested executables, Info.plists,
CodeResources and original receipts into P12 `c1-retired-*.zip`.
Full intermediate bundles are retired, not retained/replayable in place.
Sources and ALL results/receipts remain. Baseline, final and daily
bundles were hash-checked unchanged. Cleanup receipt
`c1-staging-retirement.json` records free space4.826→7.996GiB.
The current62762f pipeline resumes from p12, without re-staging.

### Focus harness extension

P3 `typing-repair/run-packaged-check.py` has one optional keyword mode:
default typing path unchanged; `mode="focus"` selects the EXISTING
network-free trace-only audit (first local open Calculator command).
That mode returns audit status `reproduction_observed`; success requires
its sole row actually pass and safe ownership release. No semantic
budget reused, no provider requests.
P4 `c1-focus.py` uses that launcher and existing document cleanup,
checks binary marker, exact app/window result, one local work, no
confirmation/wrong proposal and restored documents. It launches
Calculator in background before trials to make the target already
running. Each trial still launches a fresh Jev process; not a warm Fn
or physical test. Both sides use the identical wrapper.

### Still required

Finish current machine pipeline and fix failures. Scroll comparison and
speech-to-GUI full-path evidence remain uncollected; do not invent them.
No installed Wispr found in /Applications or ~/Applications; comparison
blocked, no parity claim. ASR source/models remain unchanged and all
35 replay recordings are existing real human recordings.
Need generated self-contained HTML report from raw JSON (show regressions),
license/reuse report, fresh read-only G4 reviewer, C1 scoped ownership
diff against the inherited fingerprint, updated phase handoffs,
and brief physical Fn/pill check. Do NOT mark C1/full phases accepted.
Do NOT stop here: user asked to finish C1 through review and handoff.

### Latest integrated output: pipeline62762f stopped; no active process

P12 offline suites/6 manifest controls passed (`c1-offline-validation-r2.log`).
Component manifest creation and verification passed; actual
`component-manifest.json` now exists with final package/model hashes.
Full Swift passed **1399 tests,25 skips,0 failures**, and P3 evidence
verifier passed27 tests. Combined lane then exited127 at EyeTracking
typecheck: **`sh: tsc: command not found`**. No EyeTracking tests or
final native/ASR/focus steps ran after that stop.

Next resolve EyeTracking dependency availability using its pinned package
manager/lock and existing setup (do not touch another owner's source or
upgrade packages). Prefer reuse of existing installed dependencies/runtime;
read package.json and lock/CI. Then resume **eyes only** through the lane;
do not rerun the already-green1399 Swift tests without a source change.
After eyes, execute the remaining same final native/replay/focus steps
from62762f's command (logs/output paths absent so remain available).
Final app/source unchanged. No active desktop/build process.

## LATEST CONTINUATION — selected c292 candidate, final review/handoff not done

**Only active shell: `b4e8e5`**, running desktop-locked scroll comparisons
before3 then final3. Read output first. All earlier pipelines completed.
Do not stop at this checkpoint; finish C1.

### Machine gates now passed

Missing EyeTracking dev dependencies were restored with pinned
`corepack pnpm install --frozen-lockfile --prefer-offline --ignore-scripts`
from EyeTracking cwd. Package.json and pnpm-lock hashes unchanged.
The first attempt from root chose a broken global12.21 Corepack path;
that failed setup log remains. Correct cwd selected packageManager10.33.
Logs `c1-eyes-dependencies.log`, `c1-eyes-dependencies-r2.log`.
No EyeTracking source edited.

Required full `all` gate **passed**: `c1-integrated-verification-r2.log`,
1399 Swift tests/25 skips/0 failures;27 evidence Python checks;
EyeTracking tsc and234 Vitest tests/11 files. Previous failed all attempt
preserved. P12 offline validation passed26 Swift +6 Python controls,
`c1-offline-validation-r2.log`; component-manifest.json created/verified.

Selected final candidate remains:
`/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-c1-final-zfuec7b7/Jev Voice.app`
SHA **c292e12024dc04bfc6a924b0d7f6ceb41a2c1c23ed38ffcba8f404750f9264eb**
P12 receipt `c1-final-stage.json`; production source snapshot after-r3.
Whole current production source was hash-checked equal to that receipt
AFTER reverting the slower experiment below. Do not accidentally select
the most recently built .build/release executable; it is the rejected
experiment. Use the signed c292 app and its frozen source snapshot.

Selected final typing passed3/3:
1407.686458202079,1543.745124945417,1536.3931667525321ms.
P3 `speed-c1final/results.json`; P4 `c1-native-final.log`.
Before2265.1988335419446,2386.8579999543726,7428.993625100702ms.
Focus before3/3 passed at6181.205875007436,3123.512208228931,
4711.153000127524ms; final3/3 passed at1610.013333382085,
1365.7779998611659,5860.091458307579ms. The third focus trial regressed.
P4 `c1-focus-before.json`, `c1-focus-final.json` + logs.
All are fresh Jev processes with scripted normal-controller input;
Calculator was already running. Not warm Fn measurements.

Signed final speech replay passed35/35,0 missing,0 wrong critical actions,
same6 word edits/164 reference words as before. ASR timing REGRESSED:
seal→authoritative final median138.70425010100007→172.30233340524137ms;
before range117.63062491081655–256.3254584092647; after
125.34166662953794–681.0221667401493ms.
Preparation67446.83324988→3129.264499992132ms is **not a speed claim**:
cache/cold state was not matched. Models and engine source unchanged.
P3 `c1-signed-asr-before.json`, `c1-signed-asr-final.json`;
P4 `c1-signed-asr-final.log`.9/9 clear intents;15 regression+20 holdouts.

### Rejected final-r2 experiment (retain failure, do not promote)

Tried changing ONLY NativeFocusedTextTarget.observedWindow to a detached,
captured-ID CGWindowListCopyWindowInfo query with revalidation afterwards.
Existing native suites passed; signed experiment passed exact typing but
was slower:2730.7672917377204,2946.5682085137814,3315.653416560963ms.
It was reverted byte-for-byte. Current FocusedTextTarget.swift equals
selected c292 snapshot again. No new source changes remain from it.
Preserved `c1-performance-after-r4/manifest.json`, r4 build/native logs,
P12 `c1-final-r2-stage.json`, signed SHA
eac804975c9504c4dfc6aada473ed087f0c90535e855cbae9de0510a0eae52a8,
P3 `speed-c1finalr2/results.json`.
Do not re-run another speculative performance change; report this red
result and finish the reviewed candidate. The stager retains final-r2
label support and copies speech license material for final* labels.

### Scroll comparison in progress

New P4 `c1-scroll.py` reuses EXISTING jev-realapps.Session, MCP stdio,
standing-grant check, bundled0.38 driver and P3 owned-document cleanup.
No model/request cap added. Actual user standing grant was true.
Session securely obtains existing Jev key through existing bench helper;
no keys logged or persisted. Each side gets private daemon and retained
packaged MCP actor; current-stage receipt adapter records original hash,
removes Package.resolved only for the older helper's source-map schema,
and validates any baseline source delta exactly. Gaze explicitly points
to an owned bound-but-not-listening loopback port via existing
JARVIS_GAZE_URL; workload is bound-window fallback, NOT gaze proof.

Two300-line owned TextEdit documents, one decoy; independent AppleScript
AX vertical scrollbar/body readback, wrong-state oracle false before
dispatch, body/decoy unchanged after. Uses production drive_until.
Before/final and before2/final2 runs failed BEFORE any goal dispatch due
to harness AppleScript errors, and restored documents. First error:
activation returns empty output; fixed apple() to allow void.
Second: AppleScript parsed `text of first document whose path` wrongly;
fixed by assigning ownedDoc first then returning its text.
Both failed pairs/results retained;0 timed rows. ACTIVE b4e8e5 now runs
before3/final3 with that correction. If another setup issue, fix based
on actual error; do not treat setup failure as product result.

### Report and scope packet

New P4 `c1-report.py` generates self-contained c1-report.html and JSON
from actual native/focus/ASR/intermediate data, exclusive non-overlapping
timeline partitions, regressions, source binding and gaps.
**Not run yet.** It currently selects scroll before2/final2; change to
the final actual pair after current probe finishes. Validate/report
script output; no standalone frontend rebuild needed. Style reuses
existing P4 audit report's neutral paper tokens. All raw values retained.
Keep HTML headline/source claims consistent with JSON.

Need scope manifest/diff against initial c1-baseline-source.json.
19 fingerprinted files changed; all within contract. Exact baseline
bytes found for15 by hashing snapshots:
- DriveLoop,FastLaneExecutor,FastLaneExecutorTests:
  c1-performance-after-r2 paths (hash equals original baseline).
- VoiceTaskCoordinator,Permissions,VoiceController,main,FastLaneTests,
  LocalSpeechTests: c1-performance-before paths.
- DwellClick,GazeService,SettingsView,DwellClickTests,GazeServiceTests,
  TrackerFlowTests: c1-before paths.
Four baseline byte copies not yet found: JevVisualDecision.swift,
VisualGoalProof.swift,JevVisionTests.swift,scripts/verification-lane.sh.
Baseline hash exists. Recover from history/patch records if possible;
do not pretend HEAD equals inherited baseline. Current source, exact
changed-file hashes, contract and preserved failing-before tests still
give review evidence. No C1 production files outside contract changed.

### Still must finish

Fresh read-only independent **G4** reviewer (`jarvis-judge`), one at a time,
is explicitly user-authorized. None currently active; no G4 yet.
Give final source, contract, c292 receipt, all machine evidence and report.
Resolve findings; never self-review as independence. Review source G4
separately from pending G5/G6/phase acceptance.
Finish generated report, scope packet, P12 reuse/license/contract notes,
phase decision/handoff updates and final C1 handoff/physical checklist.
No physical Fn/pill or full real microphone→insertion proof, no Wispr
installation, no warm goal claim. Do not flip acceptance or replace daily.
No commit/push/merge. Main source fixes are done; finish review/handoff.

## NEWEST — report generated, real MCP scroll blocker, G4 correction

No shell is active. Stable candidate copy now exists and is VERIFIED:
`~/jarvis-local/c1-review-c292e120/Jev Voice.app`, same c292 executable.
P12 `c1-delivery-receipt.json` and `c1-delivery-payload.json` prove every
path, file byte, mode and symlink equals the tested temp app, strict
signature passes, and daily executable still f6abbe98. Existing
archive.clone (`cp -cRpP`) was reused; no signing change/install occurred.
Delivery copy has not yet had a normal physical GUI launch.

Independent G4 read-only reviewer **dbbf6534** returned FAIL solely because
report referenced stale scroll before2/final2 instead of latest3 pair.
Eight other source/candidate criteria MET. `c1-g4-review.md` records it.
Re-review needed after correction; never call that original verdict PASS.

Scroll harness debugging is FINISHED with actual blocked product results:
- before3/final3: AppleScript syntax error;0 goals, docs restored.
- before4/final4: AppleScript viewport traversal failed;0 goals, restored.
- Read-only `c1-viewport-diagnostic/readback.json` proved real vertical
  AXScrollBar exists and JXA reads it. Replaced only the harness viewport
  reader with JXA; body and cleanup reuse existing helpers.
- **before5/final5** reached real packaged MCP drive_until (one attempt
  each), both **Blocked: Jev API400 max_tokens_exceeded**. Request response
 1477.628834/1206.849917ms is NOT successful latency. No scrolling, body
 and decoy unchanged, documents restored; false_done=false.
 This is genuine live product coverage failure, not another setup issue.
 No production edit or goal simplification to hide it.
- Existing `jev-realapps.Session` obtains key privately, uses existing
 standing grant and bundled0.38 driver. No artificial Jev request/dollar
 cap was introduced. The workload is300 lines in owned TextEdit, gaze
 unavailable, pinned window, MCP goal path. It is distinct from the
 normal controller's direct scroll route (still unmeasured).

Live TypeSafe docs researched:
https://docs.typesafe.ai/models.md, api/errors.md, concepts/state.md.
Jev1.14 has64k per-request /32k per-question context. Long-context
opt-in header raises both to262k, but docs say slower/less accurate.
DO NOT silently enable it, truncate evidence, change model, or treat
unlimited Jev usage as unlimited per-request context.
JevChooser.swift:69 creates JevClient(model:jev-1.14.0); source
JevVoiceCore/Models/JevClient.swift has no long-context option.
MCP calls production DriveLoop/JevChooser, not the normal fast scroll
entry. Root-sized request capture/compaction has NOT been implemented.
General-decider expansion is outside current C1 contract unless amended.
Existing Calculator request diagnostic is Calculator-scoped; do not
repurpose its grant for this TextEdit case.

`c1-report.py` now generated successfully as c1-report.html + JSON with:
explicit before5/final5, all earlier failed attempts, current raw outcomes,
red ASR regression and real scroll blocker, stable delivery-copy receipt,
source binding, honest clocks. Generation log c1-report-generation.log.
Regenerate command:
`python3 .agent/results/P4/c1-report.py --scroll-before before5 --scroll-after final5`

`c1-scope.py` ran; c1-scope.json and c1-scoped-diff.patch:
19 changed/189 unchanged of208 fingerprinted files; all owned; HEAD same.
15 exact original-byte diffs. Four original files not recovered from
archives/HEAD: JevVisualDecision,VisualGoalProof,JevVisionTests,lane script.
Full histories found under summaries2b3f79...,317949...,4ae0..., but tool
requests/patch bodies aren't recorded, only outputs. Do not pretend HEAD
is the baseline or invent a full exact diff. Limitation explicit in scope.

Next: fresh independent G4 re-review (resume dbbf6534 is authorized review
loop, one reviewer at a time), prepare concise normal physical check,
update P3/P4/P11/P12 outcomes/handoffs and finish C1 handoff with open
gates. If review finds a source problem, resolve it; no acceptance claims.
Report must be visually checked before handing it to user if possible.
Stable app is separate; don't replace daily or commit/push/merge.

Physical preparation research (not implemented yet):
Existing sibling normal-voice-qualification/run-normal-fn.py requires27
holds, installed daily app and old5-request authorization. Do NOT use it
for the user's requested brief C1 check or reuse that budget.
Installed `/usr/bin/open -h` supports `--env NAME=value`, so a normal
LaunchServices launch of the stable app can use ONLY
JARVIS_VOICE_EVIDENCE_DIR pointing to fresh0700 evidence. That enables
existing hash/event/turn recording without qualification modes or caps.
VoiceTurnEvidence.swift:41 accepts it directly. Physical normal-profile
mode has oldmax5 bound; avoid it for this brief, uncapped try.
Fn+Ctrl is actual dictation chord (VoiceController.swift:845); Fn is
command; Esc cancels. Human must supply real Fn/pill/microphone input.
Activity UI has genuine typed entry: ContentView.swift:228–243,
TextField placeholder "e.g. open Calculator", Run button. main.swift
status menu item "Activity" opens it. A normal typed scroll benchmark
could use that existing UI if needed; no such check has run yet.

## NEWEST — G4 PASS, handoff delivered, normal candidate awaiting human

G4 re-review by independent read-only reviewer dbbf6534 returned terminal
**PASS**, all eight criteria MET. Source and artifact unchanged. Recorded
in c1-g4-review.md and c1-g4-verdict.json; initial FAIL preserved.

Final handoff: c1-handoff.md. Brief check: c1-physical-check.md. Owning
P3/P4/P11/P12 phase notes and SHIP-PLAN now link the current results.
No acceptance JSON changed. No commit/push/merge/daily replacement.

Report HTML/JSON regenerated with G4 metadata and checked evidence hashes
and local links. Chrome CDP screenshots at exact 390/1440/3440 CSS widths
were inspected: c1-report-phone/laptop/wide.png. A real mobile overflow
from long raw error text was fixed with native CSS overflow-wrap; prior
captures retained. c1-report-render.json records viewport/document widths.
Native Chrome CLI window-size alone did not provide a reliable 390px
layout viewport; explicit CDP emulation did. No product UI change.

**NORMAL CANDIDATE IS RUNNING, PID64877**, executable:
`~/jarvis-local/c1-review-c292e120/Jev Voice.app/Contents/MacOS/JevVoice`.
Normal LaunchServices open, ONLY JARVIS_VOICE_EVIDENCE_DIR set; no audit
profile, no request cap, no fake Fn/audio/input. Initial Keychain access
wait was observed in a bounded sample and SecurityAgent Allow/Deny UI.
No approval was automated. Controller subsequently initialized.
Health confirms c292, PID64877, writable=true, error=null.

Physical evidence:
`.agent/results/P4/c1-physical-691cfc93d2/`
Current pointer: c1-physical-current.json; preparation.json holds status.
Owned TextEdit document is now OPEN:
`.agent/results/P3/user-audit-c1physical-a04729212e/C1 voice check.txt`
It has 300 synthetic reference lines for the brief scroll check.
It is intentionally retained for the human check, not a leaked prior
automated fixture. Afterward clean only this document by verified path,
preserving the user's test text before closure if appropriate.

Initial preparation mistakenly used imported normal_pids(), which filters
only the daily executable; it saw [] despite the candidate running.
Corrected by exact stable-candidate process-path matching, without a
duplicate launch. Do not reuse that helper unconfigured for this candidate.
Observer/preparation shell 7c8ecb has finished its useful work and opened
the fixture; it did not generate physical input. No builds or test
processes are running. Candidate remains active for the user's check.

Remaining: obtain user's actual Fn+Ctrl dictation, Fn Calculator, Fn
scroll and Escape observations. No physical proof/acceptance recorded.
MCP max_tokens_exceeded, normal direct-scroll coverage, full end-to-end
speech clocks, ASR observed regression, warm goals, Wispr access and C3
portability stay open as the handoff describes. C1 acceptance is NOT
complete. Do not substitute source G4 PASS for those gates or repeat the
completed G3/source review without a new concrete defect.
