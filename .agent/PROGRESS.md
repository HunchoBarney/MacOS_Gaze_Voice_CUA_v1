# PROGRESS — append-only session log

One entry per working session, newest at the bottom. Format:

```
## <date> — <phase/session id> — <author agent>
**Did:** what changed, named by repo-relative path.
**Evidence:** commands run and what they printed; links to runs.
**State:** which gate the phase is at; acceptance counts.
**Next:** the literal next action for whoever resumes.
**Surprises:** anything that contradicted the plan (also copy into the
phase's Surprises & Discoveries).
```

A fresh agent should resume cold from this file plus the active
ExecPlan. Never edit old entries — corrections are new entries.

---

## 2026-10-18 — P0 — devin-local (SWE-2)

**Did:** Created the harness skeleton: `.agent/PROGRAM.md`,
`.agent/PLANS.md`, `.agent/CONTRACTS.md`, `.agent/PROGRESS.md`,
`.agent/phases/_TEMPLATE.md`, `.agent/phases/P0-harness.md`,
`.agent/acceptance/P0.json`, `.agent/acceptance/schema.json`. Follow-up
entries in this session cover scripts, hooks, agents, AGENTS.md, and doc
normalization as they land.

**Evidence:** this file exists.

**State:** P0 in progress; acceptance criteria all `passes: false`.

**Next:** verification scripts → `.devin/` updates → `AGENTS.md` → doc
normalization → dry-run gates → commit on `ship/v1-p0`.

**Surprises:** none yet.

## 2026-10-18 — P0 (cont.) — devin-local (SWE-2)

**Did:** Scripts + config landed: `scripts/check-acceptance.py`,
`scripts/check-owned-paths.py`, `scripts/verification-lane.sh`,
`scripts/hooks/phase-handoff-check.py`, `scripts/hooks/session-context.py`,
`.devin/hooks.v1.json` (SessionStart + Stop), `.devin/agents/*` now pin
`opus`/`gpt`. `AGENTS.md` rewritten as thin entry point; `README.md`
points at `.agent/`. Doc normalization: 11 files deleted per megaplan
§3.1, still-valid research folded into
`development/JevVoice/research-notes.md`, drift headers on
`EyeTracking/README.md`; all `~/.devin/plans/*.md` carry banners.

**Evidence:** `py_compile` all four hook/check scripts — clean;
`bash -n verification-lane.sh` — clean; `hooks.v1.json` parses;
`check-acceptance.py P0.json` → `0/13` schema-valid; doctored
`passes:true/evidence:null` copy → rejected exit 1;
`check-owned-paths.py P0` staged → OK; `--all` correctly flags the
user's pre-existing dirty paths; Stop hook in `/tmp/hooktest` scratch
repo → blocks (exit 2 + reason) when phases dirty/PROGRESS clean,
passes when both dirty or all committed.

**State:** artifacts M1–M3 done; awaiting G4 judge dry-run (M4).

**Next:** `jarvis-judge` fresh-context verdict vs `acceptance/P0.json` →
apply flips with evidence → commit `ship/v1-p0`.

**Surprises:** none new.

## 2026-10-18 — P0 done — devin-local (SWE-2)

**Did:** G4 dry-run + G7. `jarvis-judge` (gpt, fresh context) reviewed
all 13 criteria → **VERDICT: PASS**; fixed its 2 actionable findings
(PROGRAM index missing D1/D2; Stop hook missed untracked/rename paths →
`-uall` + ` -> ` split, re-verified in scratch repo). Recorded verdict
into `acceptance/P0.json` → `--green` **13/13**. Staged 24 owned files
by name → `check-owned-paths.py P0` OK → milestone commit **`2e62f29`**
on `ship/v1-p0`, plus the handoff commit closing this entry.

**Evidence:** judge report (per-criterion file:line);
`check-acceptance.py --green` → 13/13; `check-owned-paths.py` →
24 files OK; `git log` → `2e62f29`.

**State:** P0 complete. Harness is live: SessionStart injects the
`.agent/` pointer, Stop hook requires PROGRESS hygiene on phase work.

**Next:** P1 — bench test user + harness + baseline. Write
`.agent/phases/P1-bench.md` from `_TEMPLATE.md`, get G1 user approval,
then contract → implement → judge.

**Surprises:** `git add`/`git rm` refuse deleted-path pathspecs when a
file is already gone from the tree — use `git rm` for tracked
deletions, and confirm tracking status first (`development/AGENTS.md`
was gitignored, nothing to stage). The staged-vs-`--all` distinction in
check-owned-paths exists because this tree is shared-dirty.

## 2026-10-19 — P1 done — devin-local (SWE-2) + jarvis-implementer + jarvis-judge

**Did:** Bench harness shipped under `bench/` (16-task corpus, MCP
stdio client, 5-kind verifiers, classifier covering the full
`describe()` vocabulary, runner/report/suite/env-snapshot,
`scripts/bench/create-test-user.sh`) + CONTRACTS §7 amendment (D3/D4)
+ PROGRAM index. Live slice ran for real: 35 `drive_until` rows on the
installed app → `bench/results/results-live-20261019.jsonl` +
`baseline.json`/`baseline-report.md`. Judge: G1 FAIL→fixes→PASS;
implementation FAIL (UnboundLocalError + stale wall_ms rows)→fixes→
**VERDICT: PASS**.

**Evidence:** `bench/selftest.py` → 18 tests OK (×3, incl. post-fix);
`check-acceptance.py P1.json` → 10/11 (P1-11 completes with this
commit); baseline: calc.quit 5/5 @p50 1.3s, finder.frontmost 5/5 @1.3s,
calc.open 3/5 @5.4s (2 false_done), compute/safari/chrome/textedit 0/5
verbatim; T0/T3 bars missed — measured, not guessed.

**State:** P1 complete pending the milestone commit on `ship/v1-p1`.

**Next:** P2 spikes. IMPORTANT carry-forward bug: reused `--agent`
slug on `--mcp-stdio` children permanently wedges drive_until
(tombstoned session label binds dead transport; ~1.2s `.closed` every
call). Bench mitigates with unique slugs; fix belongs in drive/session
layer — see P1-bench.md Handoff for repro + files.

**Surprises:** the wedge bug itself (headline); mcp-stdio children
never touch LatencyLedger (bench owns wall-clock timing until P4/P5
emit spans); `make local` reports tracker-not-ready while the app runs
fine for drive_until — tracker readiness is not a bench prerequisite.

## 2026-10-19 — P2a readiness — devin-local (SWE-2)

**Did:** P2a G1 artifacts written —
`.agent/phases/P2a-coreml-tracker.md` (self-contained spike: offline
`onnxruntime-node` CoreML-vs-CPU-vs-ort-web-wasm bench of every
`EyeTracking/public/models/*.onnx`, per-frame chain composed from the
real inference-worker path, ≥15FPS promote bar, self-contained spike
dir `EyeTracking/spikes/ort-node/` so EyeTracking's entangled dep files
stay untouched) + `.agent/acceptance/P2a.json` (8 default-fail
criteria, validates 0/8). PROGRAM.md P4 row now explicitly owns the
session-label wedge bug found in P1.

**Evidence:** `check-acceptance.py P2a.json` → 0/8 schema-valid;
`check-owned-paths.py P2a` → parses, 4 patterns; onnxruntime-node
latest stable = 1.30.0 (published 2026-09-14); env snapshot confirms
MacBookPro17,1 = M1/8GB = the shipping floor.

**State:** P2a plan ready for G1 — awaiting user approval, then
branch `ship/v1-p2a` + implementation.

**Next:** user G1 → implementer builds spike (M1 scaffold/inventory →
M2 per-model×EP+EP-binding proof → M3 chain/report/verdict → M4
acceptance/judge/commits).

**Surprises:** `EyeTracking/package.json`+`pnpm-lock.yaml` carry the
user's uncommitted `onnxruntime-web` 1.26→1.30 upgrade — the
self-contained spike dir sidesteps entangling it rather than asking
for a pre-commit.

## 2026-10-19 — P2a complete: PROMOTE ort-node+CoreML (ship/v1-p2a)

**Verdict: PROMOTE.** Measured on the floor machine itself
(MacBookPro17,1 / M1 / 8 GB / node v26.8.1 / ort-node 1.30.0): CoreML
cadence-weighted effective chain p50 = **5.01 ms ≈ 199.6 FPS** vs the
66.7 ms bar; strict all-models = 20.82 ms. CPU 151.78 ms (6.6 FPS),
same-box wasm 531.09 ms (1.9 FPS). Judge recomputed every number —
exact match, PASS.

**Headline finding:** `retinaface` detector **run_errors under CoreML
on every zero-detection frame** (fused NMS emits `{0,3}` tensor — EP
rejects zero-element dynamics). Not a bench artifact — fires on any
no-face production frame. Promoted architecture: gaze/appearance/lip
on `coreml`, detector on `cpu` EP (or yolo variant on CoreML, p50
9.90 ms) → honest fallback ≈7.03 ms weighted (≈142 FPS), verdict
unchanged.

**Artifacts:** `EyeTracking/spikes/ort-node/` — self-contained npm
package (pins ort-node+ort-web @1.30.0, own lockfile, zero touch of
EyeTracking/package.json/pnpm-lock.yaml), `measure.mjs` (6 models
auto-discovered, symbolic-N→1 recorded, seeded inputs, 20w+100i,
separate --profile pass for binding proof: all models partially bound),
`results/{results.json,REPORT.md,profiles/}` committed.

**For P8:** inference is NOT the bottleneck (~5-7 ms of the 66.7 ms
frame budget) — camera capture + preprocessing + calibration own the
rest, unmeasured here. Detector EP split is a hard requirement, not a
preference.

**Gates:** G1 judge FAIL'd 5 defects (cadenced-pipeline denominator,
missing 6th model, symbolic-dim policy, load_error vocab,
profiling-on-timed-runs) — all fixed pre-implementation; G5 judge PASS
with notes only. Acceptance 7/8 pending P2a-8 (this commit).

## 2026-10-19 — P2b complete: browser-driver pick measured (ship/v1-p2b)

**Pick: chrome-devtools-mcp@1.10.1 (`--autoConnect`) primary + Cua
`browser_*` fallback** — the locked direction confirmed with numbers,
not intent.

Arm-B (isolated, interleaved, N=15): devtools 83% cell-ok vs cua 32%;
attach 6.2s vs 11.7s; per-op devtools {nav 1334, snap 164, click 1093,
extract 222, settle 216}ms vs cua {1692, 68, 2088, 546, 746}ms. Cua's
semantic_v2 snapshots are 7× smaller (8-63KB vs 1-470KB) but heavy-page
snapshots hit the 15s read deadline and killed the stdio transport
(301 cascade errors; reattach always recovered).

Arm-A (real profile): both drivers gated by Chrome's "Allow remote
debugging?" consent — one human click unlocks both (ws 101 in 2.7s;
autoConnect attaches; cua bound a real logged-in tab in 12.9s).
Post-consent: devtools full corpus in own tab (snapshot 72ms); cua
read-only ~2-3s/op floor on `existing_profile` — no tab verbs exist,
so mutation on the real profile would require user-tab writes (spike
rule: unsupported). P10 gets a documented first-run consent step.

Robustness matrix: 26 cells recorded — 16 ok, 10 blocked_env (arm-A
cells blocked pre-consent stay recorded, not silently omitted). Clean
stale-ref refusals both sides, reattach works (devtools 4.7s / cua
12.5s); killed-proxy leaks an empty isolated-* profile dir — P7 needs
a sweeper.

Artifacts: `spikes/browser-drivers/` (results: 2016 rows, 36 cycles).
Run state: laptop closed mid-window — consent click landed, Arm-A
rerun completed after resume.

## 2026-10-19 — P2b follow-up: consent-dialog mitigation researched

Post-phase question (user): the "Allow remote debugging?" click is
annoying — find a fix. Findings recorded as P2b Decision Log #2:

- The grant is durable per Chrome instance (DevToolsActivePort
  generation): one Allow covered ~75min + ~20 attaches; a fresh ws
  handshake still 101s post-run. NOT per-connection on Chrome 155.
- `devtools.remote_debugging.user-enabled:true` persists in Local
  State — the chrome://inspect toggle itself survives restart.
- Chrome's consent is by design (anti-infostealer), no 'remember'
  option, per new debugging session. Dialog spam in the wild comes
  from tools spawning per-session clients that each re-dial.
- Fix chosen for the product: P7's driver holds ONE persistent
  browser-level ws connection (daemon-side, like Cua's serve) → at
  most one click per Chrome launch; P10 onboarding guides the
  one-time toggle enable + Allow.
- Documented zero-dialog alternative: JevVoice-owned Chrome profile
  (`--user-data-dir` + `--remote-debugging-port` never prompts —
  Chrome's own recommended pattern); user logs into key sites once
  there. Chrome for Testing also exempt; extension chrome.debugger
  is a third path (infobar not modal) kept as backup.

## 2026-10-19 — Locked: real-profile primary, onboarding grants once

User directive: use the real logged-in Chrome profile (no profile
fork); all permissions issued once during onboarding. Locked two
PROGRAM.md rows: 'Permissions' (all grants once at onboarding — TCC +
Chrome toggle/Allow; no recurring prompts) and 'Browser attach'
(real profile primary; P7 holds one persistent browser-level ws
connection → ≤1 Allow per Chrome launch; JevVoice-owned profile kept
as documented zero-dialog alternative). P2b Decision Log #3 records
the rationale. Open verification for P10: does the consent grant
survive a Chrome restart? (Not tested — restarting the user's browser
unannounced was out of scope.)

## 2026-10-19 — P2c started (ship/v1-p2c)

ExecPlan .agent/phases/P2c-codex-cu-headless.md + acceptance
.agent/acceptance/P2c.json written (8 criteria, 0/8 default).
Plan-grounding done directly (vendored codex 0.160.0, computer_use
stable+enabled, app-server v2 schema dumped, ChatGPT auth live, no
jevbench user → measurable-unattended vs documented-multiuser split).
NOTE: G1 judge subagent was user-canceled twice; plan review done
inline instead — 7 fixes applied (scoped bundle allow-list variant,
TCC-prompt pause→needs_human, turn/interrupt abort path, TextEdit
verify without save dialog, home/ gitignore, mechanism discovery
order, model-fallback order).

## 2026-10-19 — PAUSED mid-P2c (user restarting laptop) — RESUME STATE

Branch: ship/v1-p2c. P2b fully done (commits 354b78b, 9af1d86,
c3d289c, f1e9e92, 3dbba8d on ship/v1-p2b).

P2c status: ExecPlan + acceptance written; G1 judge FAIL'd with 8
findings — ALL FIXED in plan/acceptance (requirements-vs-config
distinction, cu_evidence tool-activation proof + activation
checkpoint, per-run MARK verifiers, pinned approvals base incl.
scoped-first, predeclared verdict rule, executable check commands,
hypotheses-not-assertions for background sessions, symlink-aware
secrets check). No implementation started — spikes/codex-cu/ does
NOT exist yet.

NEXT on resume: spawn jarvis-implementer for M1-M3 with the
ExecPlan as contract. Key brief (already prepared): vendored codex
build/vendor/CodexRuntime/bin/codex 0.160.0; ChatGPT auth live;
app-server = line-delimited JSON-RPC WITHOUT "jsonrpc" member;
flow initialize→thread/start→turn/start→turn/interrupt; server→client
asks MUST be answered; client pattern = bench/lib/mcp_stdio.py;
schema dump at /tmp/codex-schema (regenerate if wiped:
`codex app-server generate-json-schema --out <dir>`); desktop runs
wrap in scripts/with-desktop-lock.py. WARN USER BEFORE RUNS:
canary tasks drive the real mouse/keyboard briefly; first run may
pop a TCC prompt for codex — one click = onboarding grant.

No stray processes required: none left running at pause.

## 2026-10-19 — P2c M1–M3 implemented (jarvis-implementer) — awaiting judge

What: spikes/codex-cu/ (appserver.py, probe.py, tasks.json, run.py,
report.py, results/). A partial pre-restart scaffold existed (baseline +
probe + untested runner); it was reused after checking it against the schema.
5 GUI runs under with-desktop-lock (screen driven). Runs 1–4 superseded
(rows kept in results/run-*.rows.json), run 20261019-162132 = evidence.

Findings: vendored codex 0.160.0 has NO computer tool (bare:
698 connector tools, 0 CU). CU comes from the ChatGPT app's
~/.codex/computer-use "Codex Computer Use.app", wired in as an MCP server
(SkyComputerUseClient mcp). The gate is Sky's per-app approval via
mcpServer/elicitation/request. approval_policy=never auto-declines it
(scoped/never refused), default/auto_review forward it to the client,
allow_persistent_approval is not settable. Added variant client_allowlist
(the client accepts only corpus apps) → textedit/finder/notes ok with
cu_evidence, 0 human clicks, p50 27.6s, Dictionary refused, 0 TCC
prompts, 0 orphans.

Verdict: predeclared rule = PROMOTE (this console session only).
Implementer recommends CONDITIONAL (client must answer elicitations;
external CU host; MARK matched only case-insensitively after autocorrect
p→P; background session unverified). Recorded in phase Decision Log #3.

Side effects cleaned: 5 MARK-only TextEdit iCloud autosave .rtf files moved
to iCloud Trash; MARK notes in Notes' Recently Deleted.

Next: G4 fresh-context jarvis-judge on P2c.json (evidence filled, all
passes=false); user/orchestrator confirms PROMOTE vs CONDITIONAL; commit
owned paths by name (results/ ≈7.3MB incl. 2.9MB dirty baseline). HUMAN
step still open: jevbench user for the background-session test.

## 2026-10-19 — P2c G4/G7: judge PASS, verdict PROMOTE (console session), phase complete

G4 judge bd701076: PASS 7/7 (P2c-1..7 MET) with recomputation — 3 ok
task rows rederived from raw results, p50 27.6s, 0 new non-owned hunks
vs dirty-baseline, 15 auth symlinks / 0 copies. Ruled PROMOTE (not
CONDITIONAL): the conditional clause requires reduced unattended-ness
and client_allowlist is genuinely zero-click. Deployment prerequisites
recorded in phase Decision Log #3 + Handoff (JevVoice client owns the
elicitation policy — needs exact bundle-id matching for product;
product ships/requires Codex Computer Use.app; jevbench run for the
background/multi-user claims). P2c-7 evidence corrected to note 4
harmless literal matches in dirty-baseline (not a fully empty scan).

Acceptance P2c.json: 8/8 --green. Milestone + acceptance commits on
ship/v1-p2c.

Side effects noted: TextEdit iCloud autosave .rtf files → iCloud Trash;
MARK note in Notes Recently Deleted. HUMAN step open: jevbench user
(sudo scripts/bench/create-test-user.sh) for background-session test.

Next: P2d (SpeechAnalyzer vs Parakeet) — gates the voice lane.

## 2026-10-19 — PROGRAM.md: TC lane budget + visionOS eye model (user directives)

Two user-directed plan updates committed as program docs:

1. **Latency**: executors formalized as lanes T0→T4 + new **TC codex-CU
   lane** (P2c-promoted Sky path): bounded single-app tasks p50 ≤30 s
   (measured 27.6 s). TC is fallback/background only — fast paths stay
   in T0–T3; ack ≤300 ms always, ≥T3 streams progress, T4/TC
   interruptible. Levers documented (slim AX payloads, persistent
   session, act-don't-re-perceive, planner tiers). Release bars gained
   the TC line; P2c Handoff links it.
2. **Eye tracking**: locked decision rewritten to copy the visionOS
   input model — gaze = targeting only (element hover-highlight +
   steady-state confidence dot; NEVER a cursor), selection = separate
   channel (voice/click, never gaze alone), deciders receive resolved
   target identity (no raw coords — privacy + grounding), dwell =
   accessibility opt-in, every flow works without gaze. P8/P11 DAG rows
   updated (≥60 pt ≈2.5° target spacing, resolved-target hint).
   Research: Apple HIG "Eyes" + "Designing for visionOS", WWDC23/25.

Decision Log index backfilled D4–D8 (P2a/P2b verdicts, permissions-
once, TC lane, visionOS model). Next: P2d (SpeechAnalyzer vs Parakeet).

## 2026-10-19 — P2d plan drafted + inline G1 review (judge subagent unavailable)

Drafted .agent/phases/P2d-speech-bakeoff.md + acceptance P2d.json (8
criteria). G1 judge subagent hung again (same as P2c) — performed the
plan review inline: 6 findings, all fixed (TCC fallback for bare-CLI
mic capture, eou_ms per-engine mapping, mixed-outcome verdict path,
corpus-power caveat, rss_* field check, FluidAudio fetch fallback).
Corpus = recorded utterances per user choice (option b). Branch
ship/v1-p2d. Implementing M1-M3 inline; G4 judge still required.

## 2026-10-19 — P2d recorder repair: reproduced converter EOS truncation

User reported 0/15 usable clips, then the fixed-window replacement was
still glitchy. The earlier buffered-Enter diagnosis was not established.
Negative control with real FluidAudio fixture speech proves the actual
tap bug: a reused AVAudioConverter receives endOfStream per microphone
buffer; 6s of real speech becomes 0.0853125s of output. This matches the
original 15 files, all 0.1s. Their files and manifest have been preserved.

Replaced the tap with AVAudioRecorder native file capture followed by
offline 16 kHz conversion. Check native and normalized file durations,
not a timer. No unchecked Sendable capture box. Explicit permission
preflight, bounded capture, longer windows for long prompts, line-based
meter, interactive-terminal requirement, flushed keys during capture,
speaker confirmation/playback/retry/quit. Resume skips accepted clips;
retakes use UUID filenames, legacy manifest peak is optional, decode
errors propagate, and writes are atomic. Stop/quit does not discard
previously accepted progress. Stopped only the stale spike recorder
PID 76917 before testing to avoid competing microphone owners.

Verification runner gained speech scope (ExecPlan owned paths amended).
Command: JARVIS_RECORDER_LIVE=1 python3 scripts/with-desktop-lock.py
scripts/verification-lane.sh speech. Evidence:
spikes/speech-bakeoff/results/recorder-live-tests.log.
7 Swift Testing checks pass, including three real 2.00s mic captures;
real-file resample round-trip; legacy manifest read; manifest error
handling; prompt-length windows; observed-short-file rejection and the
EOS negative control. PTY front-door test also passes: 6.00s actual WAV,
extra buffered Enters cannot truncate/accept it, four bad CLI invocations
exit 1 cleanly, quit preserves original manifest/recordings bytewise.
The PTY run starts from a temporary cwd and uses the rebuilt debug CLI.
The non-live run is in results/recorder-tests.log.

Microphone test artifacts (native and normalized WAVs) remain local in
ignored corpus/recordings/. No audio uploaded/staged; no commits made.
README documents single-phrase verification first:
./spikes/speech-bakeoff/.build/debug/bakeoff record --only p01
Then record (without --only) resumes remaining clips. The human still
needs to speak/confirm the corpus; these diagnostic captures are NOT
speech/WER benchmark evidence. P2d remains incomplete, 0/8 acceptance,
no engine-selection verdict or app-pipeline fix proven by this repair.

## 2026-10-19 — P2d corpus complete; corrected release measurement running

User finished 15/15. Independently verified all entries are ok and
speaker-confirmed, all source files are 16 kHz mono, durations 6-10s
(102s total). Original WAVs are unchanged and remain ignored.

Pre-measurement review found invalid smoke-harness assumptions:
audio-end moved after model processing (hides backlog); Apple retained
only last final segment; median per-command WER hides long-command
errors; empty hypotheses could trap WER; first-partial callbacks were
timestamped after an actor hop; client RSS was compared without Apple's
XPC memory. Corrected these and documented the method BEFORE measuring
the recorded corpus. Old debug rows archived as legacy-debug-smoke.json.

Benchmark now uses monotonic scheduled-end timing, 160ms end-of-chunk
availability, common energy-delimited input without changing WAVs,
source SHA-256, complete segment assembly, corpus-weighted word edits,
and synchronous event tracing. Assets load only from local paths;
missing Apple assets fail rather than download. New variant adds
Apple volatileResults+fastResults, same model locale. Model resource
sampling separates load and inference; parent observes shared XPC RSS
and inventory bytes, with attribution gaps explicit.

Release test initially invoked executable CLI with Swift Testing args
instead of running the suite. Split thin CLI and testable BakeoffCore;
release verification now passes: 10 executed Swift checks (plus 1
explicitly skipped microphone check), 4 Python metadata guards.
Command: scripts/verification-lane.sh speech-release via desktop lock.
Log: spikes/speech-bakeoff/results/benchmark-release-tests.log.
Baseline scope check: 0 new non-owned paths / 0 changed non-owned
diff sections (160 compared). No production files changed.

Smoke run 20261020T034909125112Z: Apple fast-results correctly
transcribed p01; warm simulated final 53.57ms, first partial 2149ms
(the 300ms target is NOT met by this row). Not a winner verdict.
Full run 20261020T034959348218Z started under desktop lock:
python3 spikes/speech-bakeoff/bench.py. Parent shell 92f8ee, log
results/benchmark-full.log; engine JSONs checkpoint after each row.
Expected matrix: 162 scored rows + 3 first-inference warm-ups, covering
15 recorded commands + 3 library clips, 3 iterations, 3 variants.
Do not start a second concurrent benchmark if resuming.

Read-only app-path inspection found a concrete display-wiring gap:
main.swift:599-613 binds local partials only to LocalCommandRouter (or
clears the callbacks in STT-only mode); the displayed partial event
instead comes from remote transcriptDelta in RealtimeVoiceLane:716-720.
P3 must connect turn-tagged local partials into VoiceController's
display path, independently of command speculation. Physical Fn
integration, model-ready drops and turn races remain unproven here.

Next after the run: report.py + --check, independent verify.py,
verify_scope.py; fill measured handoff/evidence. Fresh-context G4 is
still pending; do not flip acceptance without a judge. No subagents
or commits have been authorized in this continuation.

## 2026-10-19 — P2d M1-M3 measured and verified; G4/G7 pending

Full run 20261020T034959348218Z finished normally: 162/162 scored
release rows ok plus 3 excluded warm-ups. Three engine processes
exited 0 and were reaped (no benchmark process remains).
Command results (45 rows/variant; 97 reference words per repetition):

- standard SpeechAnalyzer: final p50/p95 209.5/1025.6ms, WER 5.15%,
  first-partial p50 2631ms.
- Parakeet EOU+Ultra: final p50/p95 150.0/389.1ms, WER 4.12%,
  first-partial p50 1831ms.
- SpeechAnalyzer fast-results: final p50/p95 84.4/213.1ms, WER 5.15%,
  first-partial p50 2119ms.

Directional pick = speechanalyzer-fast by the documented priority and
engineering tolerances. Not a product/accuracy promotion. All engines
missed the first-partial 300ms target (0/45 each); fast final <=200ms
41/45. Timings are energy-delimited file replay (onset proxy, 200ms
padding), not physical Fn times. Early debug smoke was not a fair
release comparison. Apple GitHub->GateHub is a meaningful entity
error; literal WER also counts numeral/hyphen differences. Accuracy
audit lists exact error pairs. ContextualStrings vocabulary is only
a prospective P3 experiment, not measured or secretly tuned.

Resource gap stays explicit: fast client peak 20.9 MiB excludes
localspeechrecognition (observed shared peak 600.2 MiB). Parakeet
client load peak 447.6 MiB and model bytes 856362338. Shared Apple ASR
inventory bytes 162235114, exclusive locale footprint unknown.
Do not certify total RAM/disk ratios from client RSS alone.

Verification:
- CLI `bakeoff report`, report.py --check, verify.py all PASS;
  independent recomputation covers WER, fixed-end timing, coverage,
  source/binary hashes and all 15 original audio hashes.
- Final serialized release lane with JARVIS_RECORDER_LIVE=1 PASS:
  11 Swift tests + 4 Python guards, 3 real 2s microphone restarts,
  PTY front-door 6s capture, buffered Enter protection, clean CLI
  errors and quit preserving all existing WAVs/manifest bytewise.
  Log: results/benchmark-final-tests.log.
- verify_hygiene.py PASS (no tracked audio or credential-shaped strings);
  verify_scope.py PASS: 0 new non-owned paths / 0 changed non-owned
  diff sections vs 160-section baseline. Scoped diff --check clean.

REPORT.md, README, phase Decision Log/Outcomes/Handoff finalized as
review-ready. Acceptance evidence filled explicitly UNJUDGED; passes
remain false (0/8), schema valid. G4 fresh-context judge has NOT run;
G7 commit NOT made or staged. Need user go-ahead for subagent review
and milestone commit; don't call the whole phase accepted yet.
No production files edited, no audio uploaded or committed. Next
implementation after acceptance: P3 local display wiring + one-brain,
with real Fn/mic validation and entity/intent correctness gates.

## 2026-10-19 — P2d final G4 PASS, accuracy hold, G7 authorized

User corrected the speed-first recommendation: known accuracy errors
are unacceptable UX. Added explicit POST-RUN product gate rather than
rewriting the experiment's predeclared rule or raw data. Historical
performance-only pick remains; current product decision is HOLD,
no production ASR selected. Known action-changing entity/slot errors
block promotion. Future correction must use existing + unseen
confusables, no gold-answer forcing/blind renaming, and count real
clarification burden. No guarantee of perfect ASR, no accuracy fix
or production switch claimed. Accuracy-policy regression fails before
and passes after (results/accuracy-policy-before.log / after.log).

User explicitly authorized independent judge, fixes, and commit only
after PASS. Fresh-context jarvis-judge b827626b returned PASS on
P2d-1..7 with one non-blocking verifier-attribution risk. Hardened
verify.py to require exactly one successful/reaped process per engine,
unique matching PIDs, and exact key/event/input-duration matching for
every partial-probe timeline. Four tampered-real-metadata regression
cases fail before and pass after; results/attribution-before.log and
attribution-after.log. Latest serialized release lane: 10 non-live
Swift checks pass, 1 live test skipped, 9 Python guards pass; earlier
11-check live run retained. verify.py, report.py --check, scope and
hygiene all pass; measured source/binary/audio hashes unchanged.

Same independent judge verified the delta and returned final PASS,
explicitly resolving risk 1. Remaining resource/network/physical-Fn
limitations are disclosed, not blocking this SPIKE and not production
readiness. Captures in results/G4-review-initial.md (summary) and
results/G4-review.md (final response capture).

Orchestrator relayed judge verdicts: acceptance 7/8, G7 commit meta
still pending. Next: stage only explicit owned file paths, milestone
commit, then evidence/acceptance handoff commit. No production source
changes or audio staging. User's 160-section non-owned baseline stays
unchanged. Do not confuse spike acceptance with approval of an ASR.

## 2026-10-19 — P2d G7 milestone committed; acceptance handoff

After final independent PASS and checks, committed 425bba6 on
ship/v1-p2d: 58 explicit owned file paths, no production sources,
no audio/build caches/credentials. G4 acceptance 1-7 relayed from
judge b827626b; G7 milestone evidence now completes 8/8.
This follow-up acceptance/handoff commit records final phase closure.
User's non-owned baseline remains intact; no push or merge requested.

P2d is accepted as a benchmark SPIKE, NOT a production ASR choice.
Current product decision remains HOLD: do not promote the speed-only
Apple candidate until meaningful entity/intent errors are addressed
and checked on previously unseen/confusable cases. No claim of zero
possible recognition mistakes, no forced correction or always-ask
shortcut. The GitHub->GateHub error is not fixed by this milestone.

P3 inherits the accuracy-first gate, turn-tagged local transcript
display fix, one-brain dispatch, real Fn/microphone validation, and
measured clarification burden. No next-phase implementation started.
