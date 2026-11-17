# Native UI Outcome Plan Review

Scope: private-contract proposal only. Not source G4 or P4 acceptance.
Reviewer: independent `jarvis-judge` agent `73dc42f7`.
Reviewed plan SHA-256:
`e76c52e3b154c230ff182b2a94f3aa420bb40d116bda0f175ac1013515a80fd8`.

Initial verdict: FAIL. Seven gaps required explicit readonly provenance,
the exact-evidence predicate, code-owned candidate identity, visual
anchor/origin binding, readonly uniqueness, a concrete fact-registry path
and production-consumer negatives.

Revised verdict: PLAN PASS. No remaining issue found in this scope.
The revised contract specifies:

- A separate producer-sealed readonly CFString record, not editable
  provenance, cleared on SDK merge and retained only under verified scope.
- An immutable code-owned candidate registry and sealed claim, without
  changing general ObservedGoalProof semantics.
- Same native identity, role, owner, document, hierarchy, raw bytes and a
  new native-read generation during existing fresh-frame verification.
- Exact-required still demands exact native evidence; caller literals
  and contradictory literal/hidden scope exclude the derived route.
- Original visual binding, source/anchor, settled verify_state and
  current verifiedVisualGoal remain mandatory.

The frozen-image feasibility sample is not desktop qualification.
Explicit user G1 is still required before production implementation.
