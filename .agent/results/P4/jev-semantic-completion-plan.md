# Proposed bounded completion evidence for default goal-only requests

Status: user G1 approved "Approve observed proof"; revised senior G2
PASS d3665964. Contract amendment recorded before source implementation.

## Reproduced source gap

TaskBrief.successContains defaults to []. Both MCP and normal DriveTask
allow it to be absent. TaskLoop.successEvidence always returns false for
empty criteria, and TaskLoop.run requires it even after verifyState.
Therefore general goal-only requests can act but cannot finish normally.
The latest safety hardening intentionally closed acknowledgement-only
completion, but left no way to verify a semantic goal without caller
postcondition strings. Do NOT restore the old confirmed-effects bypass.

The user asks for Jev's full capabilities without artificial limits,
but has NOT waived consent, cancellation or honest completion.

## Proposed minimum (subject to senior contract review)

Keep explicit meaningful successContains authoritative and unchanged.
Never invent criteria when malformed/blank criteria were supplied.

For NO declared criteria only:
- Code enumerates actual safe observed outcome facts, not controls that
  could be pressed. IDs address read-only labels or meaningful observed
  control values. Exclude secure values, available button/link labels
  and blank values. Source privacy normalization is shared.
- Alongside existing done Noul, Jev chooses the strongest fact or none.
  A Choice alone cannot prove relevance or truth. Only a high done
  probability (proposed >=.95, stronger than existing .9) can proceed.
- At most ONE targeted follow-up asks whether that exact fact actually
  establishes the whole requested outcome, rather than merely being an
  available control, a planned action, an intermediate or dispatched
  effect. Require support>=.9 and selected fact probability>=.9.
  This uses the existing two-request observation ceiling, not another
  provider, arbitrary text, generated code, script or model permission.
- Factory returns only a validated evidence ID. Decider resolves the ID
  against its same input snapshot and mints a typed observed-goal-proof
  request. The model never supplies fact text or scope.
- Loop binds proof to the input snapshot/task and captured window,
  reobserves and independently checks the same actual fact before
  successful verifyState. Done still requires verified settle AND
  CURRENT matching evidence. No quiet-screen or prior-effect shortcut.
- A declared criterion that fails cannot be overridden by semantic proof.
- Freshness/context needs careful review: role/label/value plus
  captured window/title and original snapshot provenance vs whole-tree
  fingerprint (the latter overblocks unrelated ticking UI). Never
  silently rebind a different window/account/subject.

Alternative: keep current fail-closed requirement and require every
caller to supply a code-owned completion predicate. This preserves
today's locked contract but limits generic goal-only voice/MCP requests.
Do not silently claim the latter are fully working.

## Pre-code regressions / acceptance

- Full production TaskLoop + JevDecider + JevChooser with recorded fake
  model responses: no literal criterion, action changes UI, actual
  read-only goal outcome, verifyState then done.
- Already true goal with observed outcome and no mutation.
- Available button label, no outcome: high model done vote still blocks.
- Forged/missing evidence ID, stale/changed fact, changed window,
  private value, blank supplied criterion, failed explicit criterion,
  cancelled model/verification: no done or unintended actuation.
- Preserve literal ownership, consent, denied tools, captured scope,
  all existing supported criteria behavior and safety floors.
- Native paired run includes a goal-only default request, not merely
  fixtures whose caller supplies the answer strings.

Frozen shapes/Decision Log and all TaskLoop/Decider/preview consumers
must be reviewed before this extension. Do not treat a scoped source
review as P4 closure.

## Concrete amendment proposed after senior FAIL

No source work may begin until user G1-equivalent approval and revised
senior G2 PASS. Senior d3665964 confirmed the gap but rejected the
unspecified subject binding and unauthorized frozen-contract change.

Proposed Decision Log, not an active contract:
- Extend the current declared-literal-only completion rule with ONE
  opt-in Jev observed-evidence verifier. Absence of literal criteria is
  not proof. A scored, observed, freshly rechecked proof is required.
  Explicit/blank supplied predicates can NEVER be bypassed.
- Add `ActuationRequest.verification: ObservedGoalProof? = nil`.
  Existing call sites stay source-compatible. `DecideResult.done`
  stays unchanged. New type and field must be added to CONTRACTS.
- Proposed internal Sendable/Equatable `ObservedGoalProof` contains:
  exact task goal; bound WindowRef(pid/windowID); source snapshotID;
  a typed normalized observation context; code-selected fact identity
  (element index, role, label, value-vs-read-only-label kind, actual
  observed content and observed bounds); model identity; completion,
  evidence selection and evidence-support probabilities.
- Normalized context contains window title and ALL captured safe
  elements' index, role, label, value, bounds and action metadata.
  It excludes random snapshot IDs/tokens and masks secure values.
  Use typed equality, not delimiter-joined text or substring scope.
- Loop populates the observation's TaskBrief.window with the window it
  actually bound, even when caller used frontmost fallback. No scope
  is accepted from the model.
- Before accepting verifyState, loop checks proof belongs to the exact
  task, bound window, input snapshotID and normalized input context.
  All three probability floors and actual fact membership are checked
  in code; only IDs, never model-authored text, are resolved.
- Semantic verifyState ALWAYS performs a NEW CaptureSource.axTree
  read of that same bound window, including when settleReobserves=false.
  Require the same fact AND identical normalized observed context.
  Changed account/document/row, other context, window/title or fact
  invalidates the proof and requires a new judgment. It never rebinds.
- A later done also rechecks current context/fact against the verified
  proof. No stale proof survives task restart, another scope or mutation.
- This deliberately fails closed when unrelated ticking UI changes the
  context during verification. Such UI needs a caller's stronger scoped
  predicate or a future separately reviewed subject-binding feature.
  Do not silently weaken context equality to hide this limitation.
- P5/P7/P9 do NOT automatically gain permission to mint semantic proof.
  Their current literal predicates/nil verification remain unchanged;
  any opt-in requires a separate consumer review. Current opt-in is the
  pinned Jev factory/decider in production DriveLoop and its preview.
- No MCP/nine-tool schema, consent, literal ownership, stale-window or
  mutation authority change. No prior-effect or quiet-screen fallback.

Amended regressions must include context change with IDENTICAL proof
text in a different subject, timestamp/context drift, frontmost fallback
scope, and semantic fresh read despite settleReobserves=false.
