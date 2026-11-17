# Native D79 Calculator qualification — first clean pass

## Claim

D79 (pressable-label subject identity + referent progress framing +
authorized discharge for proven clicks) is the first Calculator
qualification with **3/3 `done`, 3/3 `verified`, 3/3 `strict_success`,
0 `false_done`** under the matched before/after protocol.

## Result matrix — "Calculate 3 plus 4 and show the result."

| run | status | verified | strict | false_done | wall |
|-----|--------|----------|--------|------------|------|
| after-0 | done | true | true | false | 10.1s |
| after-1 | done | true | true | false | 4.7s |
| after-2 | done | true | true | false | 4.3s |
| before-0 | stuck | false | false | false | 1.4s |
| before-1 | stuck | false | false | false | 2.5s |
| before-2 | stuck | true | false | false | 3.5s |

after-0's 10.1s includes runtime warm-up; steady-state is ~4.3–4.7s
for the full see→decide→verify loop per goal.

## Evidence quality

- `actual_state` oracle: `{"display": "7", "expected": "7",
  "display_evidence_available": true}` — the harness read the real
  Calculator display after the run and it matched the randomized
  expectation. Not an already-satisfied pass: the fixture seeds a
  different pre-state per run and the expected value is the computed
  answer, which only appears after correct key presses.
- Fixture seed presses (All Clear → 2 → Add → 3 → Equals) exercise
  the Clear↔All Clear label mutation the D78 fingerprint change
  covers; subject continuity held through all three after runs.
- The `authorized` discharge removed the D78 residual: no after run
  blocked on `.84–.89` authorization draws for proven elements.
- before-variant (coordinate baseline, same driver) stuck on
  `low_confidence` all three runs — the comparison is real, not
  harness leniency: the baseline cannot read dense button labels.
- `resources_clean: true` on every run; oracle snapshots show
  `ax_trusted: true`, `input_actuations: 0` (oracle is read-only).

## What changed vs D78

- `JevVisualDecision.swift` (1d62b610): `authorized` discharges for
  every natively-bound click, not only referent binds — the identity
  judgment plus code-derived `AXPress`→click already answers "is this
  the asked action". Live draws remain for text/keyboard lanes;
  protected, deny, control class, editable-scope and subject gates
  unchanged.
- Harness only: `calculator_display` prefers the tallest numeric
  static (AX frame height) instead of declaring ambiguity whenever
  the main display and "Last Expression" row are both numeric.

## Limitations (unchanged)

- Click-on-dense-grid is now proven on one app; Notes/TextEdit cover
  type/replace. Scroll, drag, menus, key chords remain unqualified.
- `gui_autospawn_proven: false`, `fn_microphone_proven: false` — the
  staged candidate ran under the harness, not the physical Fn/pill.
- Staged + signed, **not installed**. No release claim.
- Model can still pick legal-but-wrong steps; progress framing in
  `open_referent` mitigates but does not eliminate it.

Stage: `native-d79-candidate-stage` (frozen pair, both signed,
verification lane green). Receipt chain: Addendum 42.
