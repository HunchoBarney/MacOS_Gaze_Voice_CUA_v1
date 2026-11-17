# D60 TextEdit replace qualification — clean pass

Candidate: `native-d60-candidate-stage` (signed, frozen embedded daemon).
Evidence: `completion-research-20261110/native-d60-textedit/`
Harness: `jev-vision-qualification.py realapps-textedit --repeats 3`
Front door: signed embedded daemon MCP — **not** GUI/Fn.

## Result

| Run | Status | verified | wall |
|---|---|---|---|
| before-0 | done | true | 3.2s |
| before-1 | done | true | 5.1s |
| before-2 | done | true | 7.0s |
| after-0 | done | true | 6.1s |
| after-1 | done | true | 1.9s |
| after-2 | done | true | 4.2s |

**6/6 done, 6/6 verified.** First clean real-app replace qualification.
Summary `status: pass`, `acceptance_eligible: true`.

## What the trace shows (before-0, representative)

1. `open matches=element_1:0.95` — candidate-judge lane settles the
   text area in one primary call (~170ms), op derived `set_value`.
2. `grounded control=editable presence=.95 authorized=.95 protected=.02
   editable=.98 deny≤.02 literal=literal_0` — all gates clear, native
   element binding, `set_value` dispatched via `element_token`.
3. Post-action: `gc=true` + `nl=true` — merged snapshot attests the
   caller literal in the AXTextArea value; `presence` code-substituted
   to .95; `.verifyState` issued.
4. Fresh-frame verify: `completed/evidence_visible ≥ .95`,
   `same_subject=1.00` (document-fingerprint code proof),
   `hidden_required/offered_only ≤ .05`, `hasNativeExactEvidence`
   discharges `kind_supported`/`exact_required` → `.done`.

## What it took (D41→D60 arc)

- Open candidate-judge lane: op-agnostic element match at ≥.95 +
  borderline confirm redraw; replaces op-vote + box-draw gates when a
  native element wins.
- `set_value` as a first-class visual op; `element_token` transport
  (driver rejects `element_index`/`snapshot_id`/`capture_id` for it).
- Negative-polarity `editable_obstruction`, `deny`/`protected` scoped
  to unauthorized side effects, `hidden_required` scoped by
  `native_literal_evidence`.
- Code proofs substituted for model judgments where code is strictly
  stronger: `subjectProven` (document fingerprint, primary + verify),
  `kind_supported`/`exact_required`/`presence` discharged by
  `hasNativeExactEvidence` (gc + all caller literals attested in the
  fresh scoped native tree).

## Honest limits

- Not GUI/Fn qualification; not a production install; MCP harness only.
- `before-1`/`before-2` order is harness-assigned (before vs after is
  the frozen-baseline vs candidate variant label, not run order).
- Residual variance remains in conjunct-borderline draws on
  re-grounding rounds (`control pick` .77-.78 gate misses when a stale
  capture has `nl=false`); those rounds fail closed and retry.
- `same_subject` code-proof covers document-fingerprinted apps;
  non-document apps still rely on the model comparison.
