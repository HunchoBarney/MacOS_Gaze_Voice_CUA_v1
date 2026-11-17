# D16 independent source review

Reviewer: `de8b6c5e`, fresh-context read-only `jarvis-judge`.

SOURCE_VERDICT: PASS

PHASE_VERDICT: FAIL

Reviewed the real D16 delta against `explicit-decision-before`, the source
receipt, frozen contracts, affected consumers and retained verification output.
No source edits, builds, tests, live model/desktop requests or acceptance edits
were performed by the reviewer.

Source target: `jev-explicit-decision-source.json`.
Delta: `jev-explicit-decision-delta.patch`.
G3: `jev-explicit-decision-consumers-r2.log`,346 tests pass,0skips,0failures.

No material D16 source findings remain. The reviewer confirms:

- Candidate support is consumed only for the selected candidate at .90;
  malformed support fails, and the action ID is assigned only after all gates
  (`JevChooser.swift:198-219,319-412`).
- Primary goal support is batched with completion >=.95, fact selection >=.90,
  support >=.90. Focused recovery and dependent supported-fact Choice remain
  (`JevChooser.swift:355-369,430-510`).
- Semantic ambiguity with sufficient AX does not automatically request pixels.
  Missing candidate coverage can request generic pixels; selection rejection
  carries a proposal only with incomplete goal context
  (`JevDecider.swift:298-318`).
- Proposal state retains task/source/history/document/operation/literal/key
  and semantic target, without AX tokens. Substitution is blocked; selected
  target presence/location/authorization/control/deny gates remain
  (`JevVisualDecision.swift:5-81,429-432,540-579`).
- TaskLoop retains execution, settle, cancellation, stale-turn and verified
  completion ownership; voice and preview consumers still use the same seams.

P4-1 through P4-4 remain MET. P4-5/P4-6 remain NOT MET: there is no signed D16
comparison, live model qualification or performance qualification. A source
PASS does not supply the >=95%, p50<=4s, zero-false-Done release evidence.
No acceptance flags are changed by this receipt.

The reviewer notes the inherited `lastFingerprint != nil` warning in
`TaskLoop.swift:597`: the shadowed value is non-optional. It is outside the D16
delta and was not treated as a material D16 defect. No fix is claimed.
