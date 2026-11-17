# D10 Native UI Outcome Source Review

SOURCE VERDICT: PASS. Independent reviewer: a3b4862b.
Scope: approved private native UI outcome extension and named consumers.
This is not phase acceptance or signed-product qualification.

Reviewed production SHA-256:

| File In Sources/JevVoice/Drive | SHA-256 |
| --- | --- |
| JevVisualDecision.swift | b1dc9ef91fbaabc6359f3540c1d4fdf9256b3994aac75bb64bd1ffd4187058a8 |
| NativeUIOutcomeEvidence.swift | 206b5ac413029b2272651645bedbfc1b9c7ab84d76d6d66377310e0fabec94ce |
| NativeWindowObservation.swift | c5bfac00a767a75e2e68a1351c98fa1dd3f96ecea37b5754b53a6383855c61bd |
| TaskLoop.swift | 2130a12cb6099cc5db1ce29e53fe57f77d6316e8221d776959af6e55e5739942 |
| VisualGoalProof.swift | e0a1fa570048d9bd0fdefb4dd3c211eee3ce6e1dc5d8ef40d6b94f7731733b78 |

The first review returned FAIL. Both findings were rechecked and
withdrawn on evidence, not hidden:

- The exact-text-only invariant is already enforced by the sole custom
  constructor and immutable let fields. Every non-exact kind with real
  sealed evidence is rejected by the production-constructor regression.
  No mutable-state, decoder or alternate initializer bypass exists.
- Broad P3/P4 verification-lane scopes predate D10. The current work adds
  read-only/probe/owned-fixture scopes, not the old guarded p4-local
  command. Removing old scopes would revert unrelated work.

The final review confirms native CFString admission, owned native root,
SDK metadata clearing, same-registry selected-candidate binding,
literal/history exclusion, fresh native identity/bytes/generation,
original visual anchor/origin, fresh scope/support/literal judgments,
unchanged exact_required gate, and settled TaskLoop verification.
Native collect/merge, AX/Snapshot conversion, general proof/context,
chooser/decider, TaskLoop, DriveLoop preview, control and voice consumers
were included. General fact semantics remain unchanged.

Retained risk: generic display facts still format NSNumber as strings.
They are not sealed CFString evidence. A real numeric-valued fixture
element proves it cannot acquire nativeReadOnlyValue.

Evidence under workspace-local JevVoice:

- recovery-20261110/native-ui-regression-ready-before.log: old production
  path fails readonly provenance and exact UI-result verification.
- recovery-20261110/native-ui-regression-after.log: two real Calculator
  native observation/verification tests pass; model answers are stubbed.
- recovery-20261110/native-ui-authority-restored.log: 335 checks pass.
- completion-research-20261110/native-ui-identity-mutation: replacing CF
  identity with frame equality incorrectly verifies a same-value different
  element; the owning assertion fails. Source is restored byte-for-byte.
- completion-research-20261110/native-ui-owned-fixture-restored and
  native-ui-kind-invariant: source-path tests pass with clean resources.

The fixture uses its own AppKit raster and stubbed typed AI answers.
It does not establish driver capture, physical input, real-model
reliability, signed-app success or latency. P4 remains FAIL/open.
