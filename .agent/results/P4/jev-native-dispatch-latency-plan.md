# D14 Native Dispatch Latency

Status: G1 approved by the user's explicit Approve D14 selection.
Independent plan review 4b3992f3 passes after resolving all material risks.
Implementation passes 387 consumer checks plus the bounded cancellation
check, and independent source re-review74ea56f0. Signed qualification
and product speed improvement remain unproven.
This plan does not close P4. P4-5 and P4-6 stay false.

## Reproduction And Cause

The frozen D12/D13 comparison completes in A/B, B/A, A/B order.
Both use the same signed driver 0a64b75c and unsigned driver 6f42da99.
The sole production source delta is JevVisualDecision.swift.
Every goal starts from independently verified 2+3=5.
D12 has 0/3 strict successes; D13 has 3/3, with no false Done.
D13 successful median is 7476.824749999992ms, above 4000ms.
There is no successful D12 latency baseline.

Retained evidence, under the workspace completion-research-20261110 root:

- native-d13-calculator-comparison-r4/report.html and comparison-audit.json
- native-d13-calculator-comparison-r4/latency-events.ndjson
- native-d13-driver-sample and native-d13-driver-sample-r2
- native-d13-cursor-causal-probe and native-d13-cursor-causal-probe-r2
- native-d13-post-action-wait-probe
- native-d13-glide-duration-probe

The scoped actor trace puts the large gaps between action selection and
dispatch return. CPU samples name native AX press, its background key-window
primer, focus suppression and the window-report wait. CPU samples do not
assign wall time to suspended async futures.

The initial cursor-enabled contrast is NOT a valid animation-off control:
the registry reports enabled=false, but SetEnabled changes render visibility
while animate_cursor_to_target checks core.cfg.enabled. Retract the earlier
claim that this contrast ruled out the animation wait. No disabled-cursor
performance change is proposed.

The corrected motion contrast keeps the cursor enabled in both conditions,
changes only glide_duration_ms, and verifies actual renderer motion readback.
All other motion fields are checked unchanged. Six trials, fixed paired
order, 30 scoped native presses, six independently verified 2+3=5 outcomes,
zero Jev goals/model requests, original motion/enabled state restored.
It is a native RPC diagnostic, not a signed Jev goal comparison or pixel
proof of cursor appearance.

Per-button medians, original automatic glide versus 120ms glide:

| Button | Original RPC ms | 120ms RPC ms |
| --- | ---: | ---: |
| 2 | 834.894916 | 400.973417 |
| Add | 828.092166 | 363.837750 |
| 3 | 800.287458 | 402.383125 |
| Equals | 876.124375 | 424.299000 |

The independent post_action_wait contrast changes only the existing public
default/none argument. Six trials, 30 native presses, all final values
verified, zero goals/models, resources clean. Per-button medians:

| Button | Default RPC ms | None RPC ms |
| --- | ---: | ---: |
| 2 | 855.288458 | 737.559875 |
| Add | 817.147666 | 719.387792 |
| 3 | 816.712833 | 700.144708 |
| Equals | 868.328542 | 738.041417 |

These separate contrasts do not establish their combined effect or a
product speed gain. The 120ms value is a measured candidate, not an
established product default. Neither contrast establishes the 4s bar.

## Proposed Production Boundary

One generic session/dispatch integration, not an application recipe:

1. Configure only glide_duration_ms=120 once per owned session and transport
   generation, using the driver's existing public motion API. Do not change
   visibility, path/style, effects, target selection or user-persisted prefs.
2. For TaskLoop-owned native mutations that are followed by fresh observation,
   use the existing post_action_wait=none argument only when that exact tool
   advertises it. The full driver focus-protection watch must continue for
   the unchanged host deadline. Do not shorten that deadline.
3. Cache advertised tool schemas per transport generation. Reuse the
   existing tools/list ingress; no discovery or configuration per action.
   Unsupported/malformed capabilities retain legacy pacing. No mutation is
   retried when configuration or a transport fails.
4. Do not apply report deferral globally to fast-lane, media, browser or
   arbitrary caller operations that lack the TaskLoop observation contract.
   Rebind invalidates capability and per-session preparation records.

Exact seam: only the native-token default branch of TaskLoop.actuate ->
DriveLoop.actuate -> DriveLoop.dispatch -> CuaConnection.callResult.
Require the existing same-window native element-token authority. Exclude
press_key/hotkey, all visualTarget/scopedCall, browser, media, window-control,
fast-lane and no-token branches. Add no preference in the shared dispatch
function itself. The native-token branch requests the existing argument;
CuaConnection removes it for an unsupported exact tool schema.

Use that explicit TaskLoop request to trigger lazy session motion preparation
in CuaConnection, after DriveLoop's existing consent gate, before native input.
No new loop-config field or connection-wide automatic action pacing.
Motion and report-wait support are checked independently against their own
advertised schema properties, never inferred from screenshot capabilities.
Cache one bounded tools/list result per generation and one preparation
attempt per owned label/generation. Do not configure the shared default cursor.
An unsupported API or definite cosmetic refusal leaves legacy motion and
must not itself fail the goal. A transport failure is different: its outcome
may be unknown. Keep normal transport refusal/cancellation, do not claim
defaults were restored, and never replay the native action.

Reset the new schema/preparation caches AND existing capturedInputsVerified
and nativeCaptureTools on disconnect/reconnect. Require regressions for both
generation changes and new session labels. Do not carry schema authority
from the previous daemon merely because the socket path is unchanged.

No new shipped driver RPC, schema field, enum, permission, app flag,
planner head, Jev question, per-action model request or pricing policy.
No driver rebuild or driver-byte change. This deliberately does not fix
the separate shared driver SetEnabled/render-state mismatch.
No lower confidence threshold, skipped observation, skipped independent
verifier, fabricated success or forced Done.

G1 must approve the private dispatch/capability integration and owned-path
extension before production code. Expected implementation ownership:

- Sources/JevVoice/Driver/CuaConnection.swift
- Sources/JevVoice/Drive/DriveLoop.swift
- Tests/JevVoiceAppTests/DriverConnectionTests.swift
- Tests/JevVoiceAppTests/DriveLoopTests.swift
- Existing P4 harness, acceptance, ExecPlan and Decision Log paths only.

Review the actual adapter/callScoped consumers for the shared cache reset;
do not change their dispatch preferences. No correctness-sensitive preference
is inferred from a different capability such as screenshot support.

## Proof And Stop Conditions

Before implementation, add owner checks for once-per-session preparation,
new labels and transport generations, unsupported/partial schemas, failed
configuration, correct native input arguments, captured-input scope,
consent/cancellation, no mutation replay and fresh independent completion.
Include missing public motion API, failed cosmetic preparation retaining
healthy legacy dispatch, uncertain/closed configuration producing no replay,
and resets of both the old capture cache and new pacing caches.
The old behavior must fail the affected-path checks; restore after mutation
must pass. Do not add test-only switches to shipped code.

Run affected authority/consumer checks through the serialized lane and get
fresh independent source PASS. Stage isolated signed source variants with
unchanged driver/runtime payloads. Preserve the D13 control and all failures.
Run one signed Calculator pilot, then a matched three-per-build comparison
only if the pilot strictly succeeds. Same initial state, oracle, goal,
deadline and prepared-runtime policy. Include session setup in goal timing
when it occurs within the timed product call. Never subtract it afterward.
Report first-goal/new-session and warm same-session pilot rows separately.
The immutable runtime may already be loader-warm; label that honestly.
The first-goal row must actually include discovery/preparation. A separate
warm pilot may issue a second recorded goal on its retained session; count
both goals and preserve both outcomes. Do not call the first a setup success
or omit it. The matched comparison remains one goal per fresh-session run,
not two selectively scored goals.

Record all rows and return times, model/request count limitations, cold
setup, refusal and resource-cleanup outcomes. Inspect actual cursor feedback
before claiming it preserved the visible feature. Public enable and renderer
config readback alone do not prove visual quality.

If timing remains above 4s, record FAIL and attribute the next largest
measured stage. Do not tune thresholds, remove feedback or increase the
release bar. Do not repeat the full everyday-app matrix on an intermediate
candidate. A stable affected-path win still needs the remaining everyday,
physical front-door and independent phase acceptance evidence.

No install, personal-document action, Spotify operation, commit or push.

## Observed D14 Outcome

The implementation/source gate passes; signed qualification does not.
The completed matched comparison is native-d14-calculator-comparison-r3:
D13 baseline3/3, D14 candidate2/3, zero false Done, all runtime leases clean.
Candidate successful returns4022.587208ms/4027.342125ms both miss4000ms.
The failed1189.357875ms return is excluded from successful timing and
remains a failure, not a fast success. No qualifying candidate median.

An independent senior approved the private setup-read correction after
sampled evidence: full AX traversal took1427.250375ms, exceeding the old
1000ms setup read budget. Both arms now use5000ms only for preparation.
The actual goal deadline, product reads, goal clock, proof gates, runtime
policy and4000ms bar are unchanged. Setup9-11s is separately retained;
the old three setup failures all issue0goals/0presses and remain frozen.
This does not establish production cold-start behavior.

The separate first/same-client pilot returns6577.711542ms/4991.552125ms,
both verified7 and both above4000ms. The matching driver epoch/cache hit
is not externally observed. Full current evidence and remaining gaps:
jev-native-dispatch-live-results.md and the generated comparison report.
No lower threshold, driver swap, installed candidate or phase PASS follows.
