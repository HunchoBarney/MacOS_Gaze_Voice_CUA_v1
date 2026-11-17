# Native UI Outcome Proof

Status: proposed frozen-private-contract amendment. Not authorized for
production implementation until a senior plan PASS and explicit user G1.
No release acceptance or daily installation is proposed.

## Demonstrated Gap

The signed native-target candidate calculates 3 + 4 and independently
reads back 7, but blocks. Its actual native decision receives both the
expression and result. Complete native observation, formatting, additional
full-value metadata and exact arithmetic context do not resolve its
completion uncertainty. Those experiments are retained and not shipped.

The same captured image instead reports goal_evidence .99, exact_text .92.
VisualGoalProof.hasNativeExactEvidence requires caller-supplied text.
This task supplies no literal because its output is a calculated result.
Consequently even fresh, correct native result data cannot satisfy the
existing exact-visual path. Do not add the expected result to task.values
or pretend that an independent test oracle is caller input.

One frozen-image feasibility run adds native outcome selection and a
separate goal-scope judgment, not authority:

| Case | Scope | Selected Fact | Whole-Goal Fact Support |
| --- | --- | --- | --- |
| 3 + 4, actual 7 | derived_ui 1.00 | result .98 | .99 |
| 3 + 5, actual 7 | derived_ui .98 | none .99 | result .00 |
| Replace field with literal 7 | literal .97 | result .53 | .58 |
| Save 7 to a file | hidden 1.00 | none .78 | .42 |

This is model-only feasibility, not a signed-app pass, before/after
reliability result, or a substitute for fresh-frame verification.
Artifacts: `native-target-calculator-traits-readonly`,
`native-readonly-completion-state-ab-valid-wire`, and
`native-ui-outcome-feasibility` under completion-research-20261110.

## Contract Delta

Permit an optional sealed native UI outcome claim on VisualGoalProof
and an optional private readonly-value record on AXElement.
It is evidence for a derived, read-only UI result, never input authority
and never a substitute for user-literal or persisted/backend proof.
Old callers default to nil. No public MCP, driver or provider schema
changes. No model, permission, threshold, round-limit or input-path change.

### Native Evidence Admission

- Reuse the existing native walk. Admit only complete, nonsecure, actual
  CFString values on readonly nodes whose PID and native owning window
  independently match the pinned native root.
- Do not treat NSNumber formatting, labels, placeholders or clipped SDK
  values as byte-exact native strings. Keep the current readonly/action
  filters unchanged. Do not infer that a readonly node is a document body.
- Do not reuse editable NativeFieldProvenance/nativeValue for readonly
  output. In NativeWindowObservation.swift define an immutable
  NativeReadOnlyValue with a fileprivate constructor, issued only by
  native collection: exact CFString, role, label, frame, parent roles,
  verified WindowRef, optional actual NativeDocumentSubject, opaque
  NativeFieldIdentity (reusing only the existing CFEqual identity wrapper),
  and a native-read generation UUID assigned once per collect invocation.
  Its constructor verifies AXUIElementGetPid and the native AXWindow
  attribute against the exact original root. No SDK conversion can issue
  this record. NSNumber/attributed-string conversion is ineligible.
- Add AXElement.nativeReadOnlyValue with a nil default. Clear it together
  with other incoming native metadata on every merge. Only a complete,
  explicitly bound local Display can republish it. Its record owner,
  document, role, frame, ancestry and raw bytes must agree with the row
  and verified Display. Unknown/foreign/incomplete/secure data clears it.
  The existing editable nativeIdentity/nativeValue path remains unchanged.
- Publish only from a complete locally verified bound native observation.
  A missing optional owner attestation means ineligible, not a fabricated
  success or a relaxation of native completeness.
- No extra native walk. Batch native owner attributes with the existing
  read where possible. Measure any added AX cost honestly.

### Semantic Claim

Use the existing image-primary request, not a new per-action model or RPC.
Include all eligible actual native facts without a silent candidate cap.
Use an alternate private registry in NativeUIOutcomeEvidence.swift built
from the current snapshot's sealed NativeReadOnlyValue records. Do not
change ObservedGoalProof, general fact JSON or positional fact IDs.
The registry has immutable code-generated outcome_0/outcome_1/etc keys,
records and a captured VisualBinding/snapshot ID. Serialize only actual
native values, roles, labels, bounds and role ancestry, never CF handles
or opaque document fingerprints. Questions and response validation use
that SAME registry instance, not a reconstructed mutable dictionary.
Ask independent speculative questions:

1. Goal scope: derived readonly UI result versus literal edit/comparison,
   hidden/persisted result, or unknown.
2. Select the native fact that, with the current full image, establishes
   the entire goal, including a none option.
3. Whole-goal support for each offered fact, referring to that exact fact.

A claim requires pinned Jev 1.14, complete well-formed distributions,
derived_ui selected probability >= .95, the exact selected fact >= .95,
and that same fact's support >= .95. Never borrow another fact's support.
Retain original raw scores. No synthesized completion probability.

Only an exact-text visual claim may use the new source. Any caller
literal or literal answer in task history excludes the new route.
Semantic literal comparison/editing, hidden outcomes, mixed goals,
unknown scope and conflicting fresh judgments also exclude it.

The sealed NativeUIOutcomeEvidence has a private initializer and a
factory that takes the immutable registry and actual pinned response.
A selected model ID must be a key in that registry, with the whole
well-formed probability distribution validated. Bind to the record
stored under that key; never look up by the model's value or an expected
answer. The observed value is a physical continuity witness, not a
computed expected answer. Independent current-image whole-goal support
is what judges whether that actual value satisfies the user's goal.

Bind task, VisualBinding session/transport/epoch/window, original visual
anchor generation/capture/origin, claim frame generation/capture,
snapshot ID, native read generation, native window/document, exact
native outcome element CF identity and complete raw UTF8 value.
Require all existing matchesOrigin/acceptsFresh anchor constraints,
including TaskLoop's capture-session/window checks. No caller extras,
model-supplied records or mutable dictionaries can issue evidence.

### Fresh Verification

Keep the existing fresh-frame verifier and all its numeric gates.
Require another capture/generation in the same task, window and origin.
Use that capture's fresh native observation, not the original snapshot.

- Fresh native evidence must uniquely re-identify the same readonly
  native outcome element by CFEqual identity AND role, owner/window,
  document when known and hierarchy/context. Exactly one fresh eligible
  record must match; same-value replacement elements do not match.
  Require a different native-read generation, not a cached original
  record. Its entire raw value must be byte-for-byte equal.
  Preserve invisible direction marks; no Unicode normalization in proof.
- Preserve native document identity when known, original task subject,
  complete context and existing hierarchy/context invalidation rules.
- Independently reaffirm derived_ui scope >= .95 and native-outcome
  whole-goal support >= .95 in the existing fresh verification request.
  The fresh support question refers to the actual matching FRESH native
  record plus the fresh full image, not the earlier claim as evidence.
  Also require caller_literal_required <= .05: does the goal request
  insertion, replacement, transformation or comparison of a specified
  literal string/bytes, as opposed to a derived readonly UI result?
  Task/history literals and any primary or fresh literal/hidden/mixed/
  unknown scope exclude the new route.
- Existing completed, evidence_visible, same_subject and kind_supported
  remain >= .95; offered_only and hidden_required remain <= .05.
  Keep exact_required finite/in-range and consumed by the exact-evidence
  gate. Keep existing literal proof behavior intact.
- Keep hasNativeExactEvidence unchanged for supplied literals. A distinct
  derived-native method supplies full native UI-value evidence only under
  the sealed claim and fresh guards. Do not equate pixels or a prior
  dispatched action with byte-exact output.

The precise replacement of VerifiedVisualGoal's current exact-evidence
condition is:

```text
existingLiteralExact = proof.hasNativeExactEvidence(freshObservation)
derivedUIExact = sealed claim + all native continuity guards
                 + fresh derived_ui >= .95
                 + fresh selected-native-outcome support >= .95
                 + fresh caller_literal_required <= .05
                 + no caller/history literals or conflicting scope
exactOK = (exact_required <= .05 && proof.kind != exactText)
          || existingLiteralExact || derivedUIExact
```

Every existing gate outside that condition remains required. Positive
exact_required NEVER becomes irrelevant: when it exceeds .05, only
existing literal evidence or sealed/fresh full-native-string evidence
can pass. A derived result can need exact UI content without requiring a
caller-specified literal. A positive caller_literal_required or
literal/hidden scope is contradictory to the derived route and refuses
it even if exact_required is low and all bytes match. Do not change
hasNativeExactEvidence or fabricate any old score.

## Owned Implementation And Consumers

Production: NativeWindowObservation.swift, VisualGoalProof.swift,
JevVisualDecision.swift, TaskLoop.swift solely for AXElement's optional
readonly-value slot, and one small private NativeUIOutcomeEvidence.swift
in Sources/JevVoice/Drive. Reuse the existing CF identity wrapper.
Do not change TaskObservation, input requests, ObservedGoalProof or
public schemas. The alternate private registry bypasses general fact
construction without changing general proof semantics.

Tests: existing JevNativeObservationTests, JevVisionTests and TaskLoopTests
through real factories and verification seams. Harness/report changes
stay in .agent/results/P4 and the serialized verification lane.

Re-review native collect/merge, AXElement/Snapshot conversions, native
context equality, visual claim construction, fresh verification,
TaskLoop consumers, voice, control and read-only preview. G4 is a fresh
source-and-consumer PASS, not an acceptance flip.

## Failures To Guard Before Code

- Foreign/unowned/unknown native roots, incomplete reads, secure ancestry,
  SDK-only metadata, NSNumber conversion, label-only and editable inputs.
- Missing/conflicting scope, none selection, malformed/unpinned response,
  weak selection/support and another candidate's stronger support.
- Caller literals and answers, literal edits/comparisons and Unicode-byte
  differences cannot use the derived route.
- Hidden saves/sends, mixed goals, offered buttons, partial status and
  adversarial screen text cannot establish the whole result.
- Reused captures, swapped task/session/epoch/window/document, replaced CF
  field, changed value/role/hierarchy and nonunique fresh fields refuse.
- No claim grants input, retries a delivered operation or alters the
  existing native/pixel authorization checks.
- Missing new fields preserve all existing callers and literal proofs.
- Fresh exact_required > .05 without a valid existing literal proof or
  sealed/fresh derived proof refuses. Missing derived scope, positive
  caller_literal_required, contradictory scope and hidden persistence
  refuse even when the native value bytes match.
- A same-value different-CF-identity element, reused native generation,
  reused visual capture/generation and swapped anchor/origin refuse.
- Wrong arithmetic must select none or lack whole-goal support, never
  acquire an expected answer from the observed value. Include the actual
  7/goal-8 counterfactual and partial expression without a result.
- Editable/literal replacement stays on existing literal/D9 proof paths.
  Supplied task and history answers exclude the new route independently.
- TaskLoop only returns Done after a settled verify_state and a current
  verifiedVisualGoal, preserving its existing source and freshness gates.

## Execution And Proof

Write the owning production-seam regressions first and retain the red
run, implement minimally, mutation-check the keeper and run the affected
authority/consumer lane. Obtain fresh independent source review.

Stage an isolated signed source-only candidate with unchanged driver,
runtimes, resources, entitlements and explicit reviewed source hashes.
Do not install it. First run one controlled Calculator command with a
verified negative pre-state and independent native result oracle.

Only if that passes, run a small clean matched same-driver comparison
and the affected derived/literal/hidden/subject negatives. Recheck the
existing owned TextEdit literal path and affected visual behavior.
Keep raw timings, preparation/cold-start costs, failures and false_done
separate. No reliability or latency claim from the feasibility sample.

P4 remains FAIL/open until all current native, visual, everyday-app,
latency, human-front-door and fresh independent phase requirements pass.
