# Native Selection Diagnostic Preparation

Status: user selected Approve Scope on 2026-11-12. No production change.
Senior0c77f700: PLANPASS for private preparation; ownership now approved.

Outcome: one-line allowance change compiles; six diagnostic tests execute
with five opt-in skips and one keeper pass. Reviewer9e41b33a source PASS.
The single authorized rerun fails upstream of Swift readiness: SDK read
times out5000ms with4nodes and unknown display. Thus the10s helper is not
live-exercised. Zero model requests/goals/input; resources clean.
No further retry or limit increase. Preserve both attempts.

## Evidence

The completed D14 comparison is baseline3/3 and candidate2/3.
Both successful candidate returns exceed4000ms. The failed candidate
retains Calculator5 and refuses target selection. P4 stays4/6.

The existing read-only preview then fails before inference:
native-d14-selection-capture/tests.log reports exactly
readonly fixture readiness unverified. The full scoped SDK read is
non-truncated with44elements and exact display5. Independently, the Swift
native collector records5incomplete reads, visiting1/7/35/37/38nodes.
Several cross its unchanged500ms collection budget. These are different
observation paths; a complete SDK read does not replace native proof.
Actual setup wall time is9.071s because synchronous AX calls can overrun
the private5s admission loop. Resources close cleanly;0goals,0input and
0saved model requests. Original artifacts remain unchanged.

## Proposed Scope

Add Tests/JevVoiceAppTests/JevNativeChoiceDiagnosticTests.swift to the
P4 owned list before editing it. The current list omits this existing
private diagnostic despite its prior source review adbe8c30.
Do not infer that historical source review grants new ownership.

Change only private awaitReadOnlyFixture preparation allowance5s to10s.
Retain maximum10reads and the exact refusal. Optional setup logs contain
attempt number, completeness and matching-window/value booleans, not raw
UI data. Synchronous AX overrun remains possible and must be reported.

Keep full/native completeness, exact original window and expected display
checks. No model request or input before readiness. Product500ms
collection, goal30s deadline,4000ms bar, prompts, probabilities, model,
driver, signed applications and all permissions stay unchanged.

## Proof

The existing failed real read-only capture is the before witness.
Compile/check only the affected diagnostic through the serialized lane,
then obtain a fresh source PASS. Rerun the same preview once into a new
owned evidence directory. Record actual wall time, readiness failures,
every model request/answer if reached, zero goals/input and cleanup.
If readiness still fails, retain the failure; do not raise it again or
accept partial native evidence. No repeated command or comparison.

This is preparation for diagnosis, not a product fix, qualification,
production cold-start claim or permission for new frozen wording.
