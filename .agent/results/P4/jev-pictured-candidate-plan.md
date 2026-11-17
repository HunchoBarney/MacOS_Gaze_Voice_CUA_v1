# D17 — Pictured-candidate visual selection

Status: implementing under the user's 2026-11-12 direction "do what you gotta
do according to the best research ... just get p4 working and finished".
P4 remains open; no install/commit/push.

## Evidence basis

Frozen-capture autopsy (`jev-failure-autopsy-20261112.md`) plus the prior
controlled probe `delivery-visual-native-picture-choice` on the same fixture:

| Question | Current wording | Probe wording |
| --- | --- | --- |
| identity/match | .88 identity, .83-.85 located | **.98-.99** correct target, ≤.05 wrong |
| authorized | .92-.95 | **.97-.98** permitted; ≤.51 denied |
| control taxonomy | .41-.66 selectedP (ordinary vs toggle) | unusable at .9 gate |

Root causes: 5-8 correlated .95-gated judgments ANDed per action; selection
asks the model for geometry code already knows; the `control` taxonomy is an
ambiguous proposition for clicks; `located` asks about box-center-vs-padding
when candidate bounds containment is already computed.

## Scoped change (owned paths only)

`Sources/JevVoice/Drive/JevVisualDecision.swift`,
`Sources/JevVoice/Drive/VisualTarget.swift`, plus
`Tests/JevVoiceAppTests/JevVisionTests.swift` for the question-id updates.

1. For pictured native candidates, replace `target_present` + `located` +
   `identity` + `native_element` Choice + `native_matches` with one `match`
   Noul per candidate (probe wording: visible identity vs exact requested
   target; match every requested property; identity not permission).
2. Selection by match uniqueness in code: exactly one `match` ≥ .95 selects;
   ≥2 above gate blocks ambiguous; 0 falls back to the unchanged pixel path.
3. Location code-verified: `VisualNativeElement.candidates` already admits
   only elements whose bounds contain the proposed point and are
   operation-eligible — location = 1.0 for a pictured candidate; `located`
   stays model-checked for the pixel path only.
4. Reword `authorized` to probe form ("does the caller's `goal` authorize
   `proposed.operation` on this candidate now, consistent with deny/history").
   `protected`, `deny_*`, `editable` unchanged semantically.
5. `control` taxonomy remains required only for type_text (editable vs
   credential semantics); for click/key/scroll on a pictured candidate the
   protected+deny+authorized chain covers consequence risk — `control`
   becomes optional in `judgmentsValid`/`VisualTarget` (nil skips taxonomy
   exclusion only).
6. Unchanged: .95/.90/.05 numeric gates, snapshot/session/subject binding,
   pixel path, native chooser, dispatch, verification, deny semantics.

## Validation

Fail-first tests replay the capture answer shapes: accept pictured-candidate
click with match .98/auth .98/protected .02; reject on each lowered field,
ambiguity (two ≥.95), missing answers, stale proposals, type_text without
editable. Then focused suite, source review, isolated signed pilot on the
owned synthetic fixture, matched comparison only if pilot passes. P4-5/P4-6
stay false until the real bench bar is met.
