# D16 results: source fixed, live pilot failed

SOURCE_VERDICT: PASS — fresh reviewer `de8b6c5e`.
PHASE_VERDICT: FAIL — P4 remains 4/6; P4-5/P4-6 remain false.

## What changed

The primary request retains the candidate details and asks support for each
specific candidate. An action can only use its own support at the existing .90
gate, together with the unchanged selection, applicability and operation gates.
Unvalidated completion receipts cannot return a dispatchable action.

Primary goal selection and candidate-specific goal support share one request.
Focused goal recovery and fresh native outcome verification remain.

Visual presence is judged against the concrete proposal in the grounding
request and taken from the selected native/pixel target's own answer set.
The private recovery proposal preserves operation, literal bytes, key,
task/window/document and the next non-actuating reobserve. Stale context or
argument substitution refuses. Semantic ambiguity with sufficient AX does not
automatically request images; missing candidate coverage can still request
generic visual evidence.

## Source evidence

- Frozen before source: `explicit-decision-before/manifest.json`.
- Initial six counterexamples fail unchanged production code; nine expanded
  regressions also fail. Additional receipt/document/coverage counterexamples
  fail before their fixes in `jev-explicit-decision-boundary-before-r2.log`.
- Nine regressions pass in `jev-explicit-decision-after-r2.log`.
- All 346 affected consumer tests pass, zero skips/failures, in
  `jev-explicit-decision-consumers-r2.log`. The nine regressions are included
  in those 346; do not add the counts.
- Five production files differ out of 103 source entries, with no other
  production drift. Source receipt and delta:
  `jev-explicit-decision-source.json`, `jev-explicit-decision-delta.patch`.
- Independent source receipt: `jev-explicit-decision-source-review.md`.
- Reviewed source hashes still match the signed pilot source after execution.

## Signed pilot

One command, through the signed embedded daemon MCP under the desktop lock:
**Activate the green triangle.**

| Measurement | Actual |
| --- | --- |
| Strict successes | **0/1** |
| Returned status | **blocked** |
| Requested control activations | 0 |
| Other control activations | 0 |
| False Done | 0 |
| Goal wall time | 2428.328167 ms, displayed as **2.429 s rounded up** |
| Bound presence | .97, passes .95 |
| Pixel location | **.89, fails .95** |
| Authorization | **.92, fails .95** |
| Resources | Fixture exited; session/lease closed; no owned processes remain |

This is a product refusal, not a setup failure. The scene's own independent
state oracle records `Nothing activated.` Both counts remain zero.
The saved trace identifies the refusal gates but does not prove why the model
assigned those scores. No guard was lowered and no second command was run.

The comparison stops at the plan's failed-pilot gate. No exact pre-D16 signed
baseline was built, and no D16 A/B, speedup or reliability gain is claimed.
The frozen source remains available if a future comparison is authorized.

Cold read-only runtime validation took 14251.223833 ms; preparation wall time
was 22275.634875 ms. These were outside the goal clock, with the same verified
runtime copy subsequently used for the command. This is not production
cold-start qualification. Actual model request count is not recorded.

## Artifacts and limits

External workspace evidence root:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/staging/vision-pinned-owner-20261110.artifacts/completion-research-20261110`

- `native-d16-candidate-stage/stage-receipt.json`: both signatures pass;
  driver, nested runtimes, Info.plist and signing policy stay frozen.
  Its before/after labels are **driver variants**, not a D16 source A/B.
- `native-d16-visual-pilot/summary.json`: overall status **fail**.
  Its nested session status `pass` only means the harness session finished;
  the row explicitly has `strict_success=false`.
- `native-d16-visual-pilot/after-0/results.json`: returned refusal, raw timing,
  fixed-category visual trace, signed subject and cleanup evidence.
- `native-d16-visual-pilot/after-0/fixture-state.json`: independent oracle.
- `native-d16-stage-admission/`: new chained D15/D16 source admission and
  verified temporary baseline copies; historical receipts are unchanged.

Initial staging stopped before compilation on Finder metadata in the synced
baseline. Both clean temporary copies matched all 5592 saved file/mode/symlink
entries and passed strict verification. The retry built and signed successfully.
Logs: `jev-explicit-decision-stage.log`, `jev-explicit-decision-stage-r2.log`,
`jev-explicit-decision-pilot.log`.

No physical Fn/microphone/GUI qualification, daily-app install, personal-app
mutation, commit or push. No process is still running. `check-acceptance --green`
correctly returns failure with **4/6 criteria pass**.
