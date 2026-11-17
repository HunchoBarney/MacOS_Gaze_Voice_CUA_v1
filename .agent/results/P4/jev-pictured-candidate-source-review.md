# D17 Pictured-Candidate Selection — Source Review

SOURCEPASS, independent fresh reviewer dd1af7a9 (read-only explore agent;
fresh context, no access to prior review artifacts). P4 remains open; this
is a component review, not a phase judgment, desktop proof or speed claim.

Scope: `Sources/JevVoice/Drive/JevVisualDecision.swift`,
`Sources/JevVoice/Drive/VisualTarget.swift`,
`Tests/JevVoiceAppTests/JevVisionTests.swift`, against plan
`jev-pictured-candidate-plan.md` and pre-change copy
`.agent/results/P4/explicit-decision-before/`.

## Verified

- Fail-closed selection: `policyPrefix` non-empty only when exactly one
  pictured candidate has `match >= .95`; a failed native check cannot
  borrow pixel answers, and pixel fallback never reads native answers.
- Match uniqueness: missing `match` answer on any pictured candidate
  blocks; >=2 at >=.95 blocks ambiguous; 0 falls back to the unchanged
  pixel path; unpictured candidates carry no questions and are
  unselectable.
- `control = nil` is strictly safer directionally: taxonomy exclusion
  skips, and the protected-class escape `(control?.protected ?? false)`
  cannot fire, so `protected <= .05` is enforced.
- type_text on a pictured field still requires `.editable` control and
  `editable >= .95`; literal authorization unchanged.
- `VisualNativeElement.candidates`/`matches` re-prove containment of the
  proposed point, snapshot ID, token, role/label/frame and operation
  eligibility, so `location = 1` is a code-verified invariant for native
  candidates; `target.present`/`located`/`identity`/`native_element`/
  `native_matches` IDs have no remaining consumers.
- Subject continuity, VisualBinding, literal authorization, deny scan,
  `validates`, dispatch and verification paths unchanged.

## Coverage additions after review

- `testPicturedCandidateClickOmitsRedundantOrAmbiguousJudgments` asserts
  the removed question IDs are absent for click ops.
- `testTypeTextOnPicturedFieldKeepsEditableClassificationAndToken` and
  `testTypeTextOnPicturedFieldRefusesCredentialOrUncertainEditable`
  exercise the native type_text control/editable branch.

## Residual (non-blocking, recorded)

- `elementText` loses the canonical protected-phrase marker for
  nil-control targets; the deny-scan corpus is real AX labels plus the
  protected/authorized/deny chain — the plan's stated replacement. A
  model false-negative on `protected` plus a phrase-evading label is the
  remaining risk surface.
