# Native Decision Trace

Status: user selected Approve Trace And Preview on2026-11-12.
Senior0c77f700 PLANPASS. Trace-only implementation and one read-only
signed suggestion are approved; no behavior change is authorized.
P4 remains4/6; the signed D14 study is not qualified.

Current disposition: implemented/source-reviewed;36 focused checks and8
preview harness checks pass. No signed suggestion has run. Staging stops
before build on the old D14 admission's expected pre-D15 source hashes.
The user subsequently redirects work to architectural diagnosis and away
from repeated testing. Staging and preview remain paused; consult
jev-decision-architecture-diagnosis.md before resuming.

## Why This Is Needed

After-2 has complete native context, selectedP.66 and applicability.93.
The separate visual fallback refuses presence.58/box.53. Current production
logs do not retain the intervening refinement's selected probability,
candidate support or parse failure. We cannot name its exact failure gate
and should not change prompts or safety policy to guess our way through.

Both read-only diagnostic attempts are retained. The first fails native
fixture readiness before inference. The authorized rerun fails earlier:
a5000ms SDK read contains only4nodes and no display, so neither inference
nor the modified Swift readiness helper runs. Both have0goals/0input/
0model requests and clean resources. The subsequent approval for this plan
permits one public read-only signed suggestion, not another fixture retry.

A passive Calculator process sample succeeds but shows an idle event loop.
It was not taken during the stalled AX request and cannot establish or
exclude a transient app hang.

NativeWindowObservation starts its current timer after initial window
roster/identity/document reads. Its elapsedMs is not full-read wall time.
Apple's installed AXUIElement.h also says messaging timeouts apply only
to the exact object reference, not even equal references. Fresh window
references are queried for identity before receiving an explicit timeout.
That is a boundedness hypothesis to investigate, not a proven stall cause.

## Minimal Proposed Production Scope

- JevChooser.swift: privacy-safe refinement start/parse/model-match/score
  outcome logs. Only counts, probabilities, floors and fixed result
  categories; never candidate IDs, state, labels, values, images, keys or URLs.
- NativeWindowObservation.swift: full-read wall timing and exit-phase
  diagnostics, including early nil. Preserve every AX call, timeout,
  completeness rule, cancellation check and output.
- Existing JevChooserTests/JevNativeObservationTests and the now-owned
  private JevNativeChoiceDiagnosticTests, P4 harness/report paths and lane.

No question wording, request bytes, model, numeric gate, selected action,
proof, permission, interface, driver, signing policy or app recipe changes.
No timeout correction or retry is included in this first trace-only scope.

## Verification And Use

Write before/after owner checks at the existing inference seam, proving
semantic requests, decisions, request count, cancellation and refusal outputs
are unchanged for passing, low-support, low-selection, malformed and
model-mismatch refinements. Do not add a shipped test injector.
Compare canonical request digests, preserving strings and array order.
The unchanged HTTP encoder can vary JSON object-key order; do not claim
wire-byte identity without an actual matching wire capture.
Check only affected consumers through the serialized lane and obtain a
fresh source PASS. Retain the old signed candidate and all failure data.

Use the existing public read-only suggest_action tool for one isolated
signed preview only if separately approved. It already uses the production
preview path; no new tool or actuator is needed. Do not issue drive_until,
repeat the six-goal study, reset Calculator or claim goal timing.
If current native evidence remains unavailable, a separately labelled
frozen-state replay may inspect existing refinement requests without live
app access. Neither route is release or physical-front-door qualification.

Only a demonstrated failure may motivate a subsequent behavior change.
Changing frozen wording, authority or numeric policy still requires its
own explicit Decision Log, approval and consumer review.
