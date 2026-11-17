# D77 Calculator real-app qualification — open_referent categorical pick

**Verdict: first real dispatched pass.** 1/3 done+verified (strict), 2/3
blocked — both blocked runs are fail-closed on live gates, not harness
defects. Prior candidates (D70–D75) never dispatched a real Calculator
actuation through the open lane; D69's "done" rows were already-satisfied
verifications, not dispatches.

## What changed in D73–D77

The open lane's per-element `open_<id>__match` asks (N independent
near-1.0 identity judgments over ~20 look-alike keys) were replaced /
complemented by a single `open_referent` categorical choice over the
shown candidate ids + `none`/`unsure`:

- Bind rule: unique plurality over candidates AND escape options, plus
  the element's own match draw not decisively rejected (< .5 vetoes).
- A corroborated referent bind is admitted as the cleared native
  identity without re-applying the single-draw .95 filter;
  `presence`/`authorized` discharge to proven (the referent question IS
  the next-action judgment; `located` was already construction-proven
  from the element's own AX rect). `protected`, `deny_*`, control class,
  `editable_obstruction`, literal authorization and `same_subject`
  remain live gates.
- `VisualNativeElement.corroborated` persists the relaxed (.5) identity
  bar through `init`/`matches`/`VisualTarget`/`validates`; all
  structural checks (snapshot id, tool eligibility, containment,
  uniqueness) unchanged. Non-referent binds still require .95.

## Run evidence (signed candidate, real Calculator, desktop lock)

| Run | Outcome | Notes |
|-----|---------|-------|
| after-0 (expected 7) | blocked, protected .08 | Referent picked "All Clear" at .88; protected-consequence gate flagged a destructive step — hard violation, fail-closed. |
| after-1 (expected 7) | **done, verified, strict** | Native referent dispatch produced expected display; oracle independently read display="7". |
| after-2 (expected 5) | blocked, subject .90–.94 | Dispatched "3", then model chose "Clear" (sequencing error — wiped entry to 0), then Clear↔All Clear label swap flipped the window fingerprint (remove+add under subset continuity) and model subject draws sat at .90–.94 < .95. |

Trace shape of a passing dispatch (after-1/D76 after-2 identical):
`referent pick=element_N selectedP` → `native matches=element_N:…`
(reference=native) → `grounded control=native presence=1 located=1
authorized=1 protected≤.05 deny≤.05` → click dispatched →
`verify scores=completed≈1 same_subject≈1` → done.

## Honest limitations

- 1/3 strict success is not qualification-complete; the mechanism is
  proven but model step-selection and protected-gate calibration still
  gate reliability.
- The "All Clear" protected hard-violation ends a run terminally —
  fail-closed by design, but a borderline redraw cannot recover it.
- Window-subject subset continuity does not survive the Calculator
  Clear↔All Clear label mutation (genuine remove+add); falls back to
  model subject draws which hover under .95.
- The referent pick can select a harmful-but-unprotected step
  ("Clear" mid-expression at protected .02) — gates cannot tell a legal
  click is strategically wrong.
- Qualification is the staged signed candidate over the desktop lock —
  no installed-app, pill/Fn, or release claim.
