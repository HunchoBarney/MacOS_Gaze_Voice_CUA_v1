# D69 Notes append-paragraph qualification — clean pass

Candidate: `native-d69-candidate-stage` (signed, frozen embedded daemon).
Evidence: `completion-research-20261110/native-d69-notes/`
Harness: `jev-vision-qualification.py realapps-everyday --app-case notes --repeats 3`
Front door: signed embedded daemon MCP — **not** GUI/Fn.
Fixture: the single approved synthetic note (`jev-realapps-owned-note.json`),
title `Jev Test - Native Qualification <marker>`; retained afterward.

## Result

| Run | Status | verified | wall |
|---|---|---|---|
| after-0 | done | true | 7.0s |
| after-1 | done | true | 8.0s |
| after-2 | done | true | 9.3s |

**3/3 done, 3/3 verified, 3/3 strict_success, false_done=false.**
Summary `status: pass`, all `resources_clean`.

## What the trace shows (after-0, representative)

1. `open matches=element_2:0.94` + open_confirm redraw `.96` — the
   candidate-judge lane settles the note body AXTextArea; `key`/`type_text`
   are the only ops offered for an editable role.
2. `grounded control=editable presence=.96 located=1.00 authorized=.96
   protected=.01 editable=.99 deny≤.03 literal=literal_0:.99
   subject=1.00 reference=native` — all gates clear; `subject` is
   code-proven by the window-subject fingerprint (D61), not pixels.
3. `type_text` dispatched via `element_token`; the append lands at the
   note's end (the literal's own leading separator forms the paragraph;
   D62 `doc_end`/`doc_start` vocabulary exists for caret movement).
4. Post-dispatch: `nl=true gc=true` — the merged snapshot attests the
   caller literal in the attested native value (U+2028-normalized, D63);
   `presence` code-substituted; `.verifyState` issued.
5. Fresh-frame verify: `same_subject=.99`; `completed`, `evidence_visible`,
   `kind_supported`, `offered_only`, `hidden_required` all discharged by
   `hasNativeExactEvidence` (fresh scoped native tree attests every
   caller literal) → `.done`. Native oracle independently confirms
   `title_preserved=true`, `requested_paragraph_count=1`.

## The D64→D69 arc — what it took

The defect chain was real, not draw variance:

- **D64** `JevModels`: one malformed `box` answer poisoned the whole
  response decode → lossy per-answer decode + `malformed=` diagnostics.
  `TaskLoop`/`JevDecider`: first post-dispatch identical fingerprint is
  delivery-in-flight (reobserve), not staleScreen.
- **D65** `authorized` scoped: caret position, focus and single-step
  completion belong to sequencing and verification, not this gate.
- **D66** `TaskLoop`: a dispatched round's stale mark excluded — it
  observed the screen *before* causing its change; the pre-dispatch
  stillness streak no longer escalates past the delivery it just made.
- **D67** `authorized` widened: setup steps (focus, caret movement,
  navigation) count as part of the asked action, not a different one.
- **D68/D69** `VerifiedVisualGoal`: `completed`, `evidence_visible`,
  `offered_only`, `hidden_required` discharged under `exactText` +
  `hasNativeExactEvidence`, same clause as `kind_supported`/
  `exact_required`. Pixel squint on a small Notes window can never
  positively assert exact text; the native read is strictly stronger.

## Honest limits

- Not GUI/Fn qualification; not a production install; MCP harness only.
- Native-exact proves literal *presence* in attested content on the
  proven-same subject, not position within the field — the harness
  oracle checks position independently (title preserved, paragraph
  count). Same residual the earlier `kind_supported`/`exact_required`
  discharges carry.
- The dispatch gates (`authorized`, deny, protected) still redraw on
  borderline model draws and can cost extra rounds — evidence remains
  honest when they fail closed.
- Pre-D69 evidence (D43–D68) records the defect chain, not passes:
  subject gate misses, prepend-position defect (fixture restored),
  line-separator mismatch, staleScreen false-positive, invalidBox
  decode poisoning, authorized-gate wobble, verify-conjunct wobble.
