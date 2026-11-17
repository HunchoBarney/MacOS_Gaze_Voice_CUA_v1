# P4 Current Verdict: No-Go

4/6 acceptance criteria are met. This is a gate count, not an estimate of
effort remaining. P4-5 and P4-6 remain false. No candidate is installed.

## Current Direction: Decision Architecture

The user requested a different approach on2026-11-12: read the current
docs, explain the underlying problem, and stop repeating tests.
Staging/live work is paused. No D15 signed preview occurred.
The trace-only code has source PASS,36 focused checks and8 harness checks;
these are not a product reliability result.

The investigation identifies an implicit whole-goal/next-step contract,
independent visual questions without a shared initial proposed target,
and semantic uncertainty routed to screenshots. It also records the
separate observation-budget limitation without claiming to explain the
SDK stall. No production behavior changes follow from this investigation.
See `jev-decision-architecture-diagnosis.md` for current docs, source
evidence, retained scores, limits and the recommended decision boundary.

## Latest D14 Signed Comparison

D14 versus retained D13 completes the fixed A/B, B/A, A/B comparison.
Baseline: 3/3 strict successes. Candidate: 2/3. Zero false Done.
The failed candidate remains at the independently observed starting value 5.
All six runtime leases close cleanly. No install or acceptance flag changes.

Candidate successful return times: 4022.5872080000045ms and
4027.342125000004ms. Both exceed 4000ms. The blocked return is
1189.357875000013ms and receives no speed credit. There is no qualifying
candidate median because only two candidate goals strictly succeed.
Baseline successful median: 7472.912624999992ms.
The two successful matched pairs are faster, but completion count is worse;
this is not an end-to-end speed or reliability win.

Current reviewed report, under workspace staging
vision-pinned-owner-20261110.artifacts/completion-research-20261110:
`native-d14-calculator-comparison-r3/report.html` and `comparison-audit.json`.
Report source review: PASS, reviewer 2f68ceeb. Four new audit/report checks
and four retained D13 checks pass. This signed study uses the reviewed
two-file D14 delta; signed driver/runtime payloads remain unchanged.

The separate same-client pilot returned done twice, verified 7:
6577.711542000003ms first goal and 4991.552124999998ms second goal.
Neither meets 4000ms. A retained MCP actor is proven; actual driver
transport generation/session epoch and cache hits are not exported.

Three earlier setup failures issue zero goals and zero presses. Their
original measuring sources and failure records remain retained.
Read-only diagnosis completes the full 44-element driver view in
1427.2503749999998ms with an explicit 5000ms diagnostic budget; a sampled
owned driver waits in AXUIElementCopyMultipleAttributeValues during
traversal. Private preparation now uses 5000ms identically in both arms,
retains full-tree/native identity/modal guards, and records 9-11s setup
separately. Product reads, goal timing, 30s caller deadline and 4s bar do
not change. This is prepared-state evidence, not production cold startup.

The failed goal's native observation is complete. Initial native selection
probability is .66; the visual fallback subsequently reports target
presence .58 and box confidence .53. The read-only refinement capture then
fails native fixture readiness before any model request, goal or input;
its SDK view is complete but its independent Swift native views are not.
Resources close cleanly. User-approved ownership and the private5s->10s
allowance change are implemented and source-reviewed. The single rerun
then fails earlier: a5000ms SDK read contains4nodes and no display.
It issues0model requests/goals/input and does not reach the changed helper.
Its error text does not prove the UI changed. No further retry is run.
A later passive Calculator sample is idle but was not coincident with the
failed AX request, so no hang cause is established. No threshold change,
prompt experiment or new production fix follows from those scores alone.
Everyday apps, physical Fn/pill, visible cursor quality and P4-5/P4-6 remain
unqualified. See `jev-native-dispatch-live-results.md`.

## Previous D13 Signed Comparison And Diagnosis

D13 versus retained D12, fixed A/B, B/A, A/B order: candidate 3/3 strict
successes, baseline 0/3, zero false Done, native final display 7, all resources
clean. Each goal starts from separately verified 2+3=5. The one admitted
production source delta is JevVisualDecision.swift. Driver and runtime
payloads are unchanged. This is signed embedded-MCP evidence, not physical
Fn/pill/microphone or the complete everyday-app qualification.

Candidate successful median: 7476.824749999992ms, or 7.477s rounded up.
The 4s bar still fails. There is no successful D12 speed baseline.
Three successful goals do not establish 95% release reliability.

Checkable report and raw rows, under the workspace staging
vision-pinned-owner-20261110.artifacts/completion-research-20261110:
native-d13-calculator-comparison-r4/report.html and comparison-audit.json.
Original preparation refusals and the slower single pilot remain retained.

Private native-driver diagnostics make zero Jev goal calls. The first
cursor-enabled contrast does NOT rule out the animation wait: the setter
changes render visibility, while the wait checks another enabled field.
The earlier negative causal conclusion is retracted; raw results stay intact.
CPU samples locate native AX press, background focus/settle and window-report
paths, but cannot assign suspended async wall time.

The corrected six-trial motion contrast varies only glide_duration_ms:
automatic versus 120ms. Both conditions keep the cursor enabled. Renderer
motion readback and unchanged other motion fields are checked. Thirty native
presses, six verified final states, original settings restored, resources clean.
Four repeated-button medians change from 800.287458-876.124375ms to
363.837750-424.299000ms. All raw trials are in native-d13-glide-duration-probe.
This is not independent pixel proof of visible feedback.

The separate six-trial native-d13-post-action-wait-probe varies the existing
public default/none argument. Thirty presses, all final states verified,
resources clean; per-button median reduction is about 98-131ms. The driver
continues its full focus-protection watch detached. No production setting,
deadline, verifier or threshold has changed.

Neither contrast establishes a combined effect, a signed Jev goal speed
gain or P4 qualification. User approved D14 and the test-only fixture scope
extension. Its two-file production change passes 387 selected consumer
checks, the bounded cancellation check, and source re-review74ea56f0.
See jev-native-dispatch-source-review.md and the approved latency plan.
No signed D14 goal, product speed gain or installation is established yet.

## Historical Pre-D13 Qualification

The following records are retained historical evidence, not newly rerun
checks or the latest signed subject.

## What Changed

The SDK reports placeholder/display text when actual editable AXValue is
empty. An empty Email field therefore appeared to contain the supplied
literal word Email, and Jev skipped typing. Swift now uses a private
same-window native actual-value map. Exact unique matches can update only
the existing SDK row value. Original action authority stays unchanged.
Secure fields are excluded before the new actual-value read; failed reads
remain unknown and cannot authorize semantic completion.

No fixed production step ceiling, candidate cap or browser-ref cap was
reintroduced. Permissions, cancellation, no-progress and stale-state
protection remain. No slower per-action model or lower confidence floor.
The caller's native benchmark deadline is separate from the production
progress-driven loop budget.

## Checks

- Swift:1191 tests,18 skipped,0 failures.
- Focused native/loop/goal/browser tests:114,1 skipped,0 failures.
- Tracker:234 tests and typecheck pass.
- Verifier/corpus:25 Calculator checks,13 strict-run checks,4 case checks.
- Fresh source judge896e253f: SOURCEPASS; overall PHASEFAIL.
- Signed receipt: `jev-candidate-stage-6ec2307771e34c8aaee594112231d5f5.json`.
- Receipt records unchanged immutable resources, designated requirement
  and signing metadata, with a passing strict signature check.

The114-test focused lane is Swift-only. Corpus consistency is checked
separately by `scripts/verification-lane.sh p4-native-verifier-tests
--implementation .agent/results/P4/jev-native-verifier.py`; its final
record is `jev-placeholder-corpus-after.log`. It is not included in the
114 Swift test count.

The named HTML artifact is validated without writing a new report by
`scripts/verification-lane.sh p4-native-report --native
.agent/results/P4/native-candidate-3cdd2d5ec1b1477cafe97db9df666845/results.json
--goal .agent/results/P4/native-pilot-80784ea4c4e34e089b26d682b29495d2/results.json
--output .agent/results/P4/jev-p4-audit-6addd9ad96f24e94a4f1da31363e4c87.html
--check`. This checks current source hashes, signed-receipt booleans,
baseline/candidate binary identity, A/B hashes, resource cleanup and
exact existing report contents. A mismatch refuses to overwrite evidence.

## Matched Native Reproduction

Before: `native-pilot-cec8134bb3c840efa991aea407890827/results.json`.
After: `native-pilot-e26e9a1d5e764aba883183cade15cc71/results.json`.

Same corrected workload/harness/driver/fixture/verifier hashes.
Old82 saves Aster with empty Email:0/1 strict.
New6ec saves the exact supplied word Email:3/3 strict.
Successful wall times:9.172s,7.108s,6.957s, each rounded up.
Both use a30s diagnostic caller deadline. The old build failed, so its
wall time is not a successful-completion speed baseline. No speed gain
or general accuracy claim is made.

The first new case accidentally retained the old address in its success
string. Its goal, supplied text and independent expected state requested
Email. `jev-placeholder-corpus-before.log` reproduces the mismatch;
`jev-placeholder-corpus-after.log` passes after correcting that one case.
Both builds were then rerun against the same corrected case.
Original `native-pilot-af06a9fc1a364c1789bb2f17c7ce2cca` remains unchanged.
That run is not relabelled a pass. A field is persisted to fixture JSON
only on Save; empty persisted email before Save does not prove typing
failed. The private synthetic trace shows actual empty -> entered values.

## Current Native Qualification

`native-candidate-3cdd2d5ec1b1477cafe97db9df666845/results.json`:

- Original deadlines:8s forms,30s ten-page setup.
- 6/9 strict successes,7/9 state matches,3 caller cancellations.
- One cancelled form physically completed; it still counts as failure.
- Median successful completion:8419.1137705ms. Cancelled times are censored.
- Zero false_done; resources clean.
- Ten-page installer completes3/3 without a fixed step ceiling.

`native-pilot-80784ea4c4e34e089b26d682b29495d2/results.json`:

- Goal-only seven-page setup:0/1 strict,1/1 state verified.
- UI finishes, semantic completion remains below the required confidence.
- The refusal is safe but still a product failure, not successful usage.

These do not meet >=95% strict success and p50<=4s. Extra calls alone
have not solved goal-only confidence; prior failed model-only probes are
retained and no prompt experiment was promoted by fishing for agreement.
Timing cause is not established by wall time alone.

## Disposition

No install, commit or push. No personal browser/document interaction,
permission reset, or repeated physical Fn/microphone test.
Source safety review is not a full security audit.

Visual report with actual fixture screenshots and all current rows:
`jev-p4-audit-6addd9ad96f24e94a4f1da31363e4c87.html`.
The original45/48 sample was a synthetic decision evaluation, not48
voice workflows; its three misses were follow-up vetoes. Later native
tests exposed additional integration bugs. No48/48 product claim is made.

For continuation: profile the real native pipeline with a paired
per-stage harness before changing timings, resolve goal-only completion
at existing proof thresholds, then requalify G5 and request a fresh phase
judge. Do not count longer diagnostic deadlines or offline rescoring as
fresh passing release evidence.
