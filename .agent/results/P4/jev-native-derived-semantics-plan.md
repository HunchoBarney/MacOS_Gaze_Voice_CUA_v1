# Native Derived Result Semantics

Status: proposed amendment, NOT authorized. Renewed explicit user G1 and
a fresh independent plan PASS are required before production changes.
This does not authorize installation, acceptance, threshold changes or
additional model requests.

## Reproduced Problem

D10 is implemented and has a narrow source PASS and 335 passing
authority/consumer checks. Its signed isolated Calculator pilot produces
5 for 2 + 3, independently reads 5, but reports blocked in
10456.450208000004 ms. No false Done occurs.

Read-only production-path capture r5 confirms that actual native output
and the image reach Jev. The primary can fail D10 admission at .91
derived scope and .94 output selection. Fresh verification can report
completed .99 while same_subject .94, kind_supported .81 and
hidden_required .10 correctly prevent Done.

The verifier describes the new computed readonly result only by the old
`exact_text` enum. Its subject question allows requested document/page
navigation but does not distinguish requested changes to arithmetic
contents from replacement of an account/document/task entity.

Evidence root:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/staging/vision-pinned-owner-20261110.artifacts/completion-research-20261110`

Relevant evidence:

- `native-ui-outcome-calculator-pilot/after-0/results.json`
- `native-ui-outcome-calculator-readonly-r5`
- `native-ui-outcome-state-probe`
- `native-subject-contract-probe`
- `native-subject-contract-probe-continuation-r2`

These are not equivalent evidence lanes. The signed pilot is the product
failure. The read-only capture is diagnostic, not an actuator history.
Frozen model requests are semantic experiments, not sealed native proof,
signed-app reliability or P4 acceptance.

The repaired frozen comparison contains eight inherited primary rows
and six new fresh/synthetic rows, not a clean repeated qualification:

| Check | Baseline | Proposed Interpretation |
| --- | --- | --- |
| Correct primary output selection | .94 | 1.00 |
| Correct primary derived scope | .98 | .97 |
| Correct primary output support | .98 | .98 |
| Original result 7 to requested result 5: same_subject | .87 | .97 |
| Same synthetic account/document, requested numeric change | not reissued | .98 |
| Wrong synthetic account: same_subject | not reissued | .00 |
| Wrong synthetic document: same_subject | not reissued | .01 |
| Synthetic changed/unknown document: same_subject | not reissued | .13 |

Wrong math still selects none (.97), text transformation without fixed
output selects none (.94) and literal scope (.92), and mixed hidden
outcome selects none (.90) and mixed scope (.74). None qualifies for a
native derived proof. Fresh positive gates reach their existing floors;
kind_supported is exactly .95, so no reliability margin is established.
The .13 unknown-document result is a refusal, not 95% negative certainty.

The unchanged-context definition-only experiment also improves kind/
literal/hidden interpretation, but does not solve requested value changes:
its 7-to-5 same_subject is .88. The additional subject clarification is
therefore separately exercised, not assumed from more metadata.

## Rejected Alternatives

- No typed-Choice replacement for caller_literal_required. Keep its Noul
  response and .05 gate. The earlier proposal needs a new contract and
  is unnecessary for this narrower amendment.
- Do not use the first experimental scope definition limited to
  caller-fixed output text. It could exclude transformations whose
  output is not supplied. It is rejected, not a production candidate.
- Do not narrow native hierarchy/context or ignore changing SDK rows.
  Their involvement is unproven. Preserve all D10 hard matches.
- Do not bypass same_subject, infer a successful score, lower .95, or
  promote local expected output into caller input.
- Do not ship a question-only tweak that still fails fresh verification.

## Proposed Change

Preserve the existing private evidence slots, primitive types, raw-score
gates and all native admission/freshness requirements.

1. Clarify the newly added private primary scope, fact selection and
   support instructions. A selected value must be the completed readonly
   output, not its input, expression, label or offered control. Ordinary
   numerical operands do not by themselves make a computation a textual
   edit. Every text editing/transformation/comparison condition remains
   excluded, including when output text is not supplied verbatim.
2. Only after a real D10 claim uniquely matches fresh native evidence,
   explain its private kind in claimed_outcome: a derived readonly UI
   result with exact fresh native CFString evidence, not an asserted
   caller-literal edit or backend outcome. These are descriptions of the
   proposed evidence family, NOT assertions that the goal belongs to it
   or is complete. Literal/hidden/mixed goals remain excluded.
3. In that same fresh-native branch only, clarify same_subject:
   goal-requested ordinary value changes are not by themselves identity
   changes. Account/document/entity names and IDs are identity, not
   ordinary values. Preserve original account and task entity. Different
   document/page identity is allowed only for explicitly requested
   navigation. An unrequested replacement or unproven required identity
   still refuses.
4. Keep all other existing verifier questions verbatim. Keep same_subject
   as Noul >= .95. Retain completed/evidence_visible/kind_supported >=
   .95, offered_only/hidden_required <= .05, exact native evidence for
   exact_required, and all fresh D10 scope/support/literal gates.
5. If fresh native evidence is absent or invalid, provide neither the
   explanatory definitions nor the clarified subject question. The
   legacy visual/literal path remains unchanged.

There is no new public enum, provider/driver schema, permission, model,
round limit, app recipe, input route or extra per-action RPC.
Completion still settles through TaskLoop. No definition is authority.

## Owned Production Files

- Sources/JevVoice/Drive/NativeUIOutcomeEvidence.swift: central private
  definitions and the D10-only question wording.
- Sources/JevVoice/Drive/VisualGoalProof.swift: attach those definitions
  and the clarified subject question only inside its existing successful
  freshValue branch.

No NativeWindowObservation/TaskLoop/driver change is proposed.

## G2 Fail-First Contract

Before production edits, extend the existing opt-in owned-native
production-seam keeper, not an imitation verifier:

- Valid sealed/fresh readonly CF evidence receives exactly the reviewed
  private definitions and subject instructions.
- No native claim, stale/stripped evidence, wrong owner/context/CF
  identity, changed bytes, reused generation and same-value replacement
  cannot receive the new branch or become Done.
- Legacy literal/editable and nonnative visual requests retain their
  original question/state shape.
- A raw .94 subject/kind/support or .06 hidden/literal probability still
  refuses even with definitions. No score can be fabricated.
- All text transformations, literal comparisons, mixed and hidden goals
  remain ineligible. Model distribution/key validation remains intact.

Frozen model checks must include correct and wrong math, text
transformation without fixed output, mixed hidden outcome, unchanged
account/document with requested value changes, wrong account and wrong
document. Synthetic account/document images prove only model behavior,
not native scope or real account qualification.

## Evidence Integrity

The first subject probe stopped after ten answers with HTTP400 on its
manufactured scope images. The renderer produced Retina-scaled
920x1792 rasters rather than the intended 460x896. Do not count the
unissued negative cases.

The continuation guard exposed a recorder alias: the baseline fresh
request retained a dictionary subsequently edited for the candidate.
Its stored baseline request is not authoritative. Preserve it, exclude
that row, and reissue only the affected pair. Freeze future recorded
requests and retain the actual wire-body SHA. Do not reinterpret the
corrupted artifact as a clean comparison.

The repaired continuation links the old report hash, inherits only the
eight byte-equivalent completed primary cases, and separately reports
new requests. Preserve both failures. Do not call it one clean run.

## G3 Through G6

Use scripts/verification-lane.sh for focused/native and affected
authority/consumer checks. Obtain fresh independent source PASS for all
named consumers. Stage from the preserved signed D10 candidate with a
reviewed two-file delta and unchanged driver/runtime/resources.

First run one isolated signed Calculator command from a verified
different initial result, independently check final native value and
strict product status. If it blocks, stop comparison and diagnose that
specific failure. Never count the native oracle alone as success.

Only after that pilot passes, run the reviewed matched slice and retain
every failure, setup interruption, request count and unrounded timing.
The existing owned TextEdit literal fixture guards against regressions;
do not touch other documents or create another Notes note.

P4-5 still requires its real reliability/latency bar, P4-6 a fresh
independent phase verdict. Signed MCP is not physical Fn/pill proof.
Any human try remains separate. No daily installation is authorized.
