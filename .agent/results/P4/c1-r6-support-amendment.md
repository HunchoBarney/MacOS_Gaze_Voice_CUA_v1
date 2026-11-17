# C1 R6 primitive support repair

Status: G2 PASS304e48f5, no blocking findings. Approved before production edits.

R5 is signed7e813283… and source/artifact G4 PASS304e48f5. Its unchanged live
TextEdit G5 reaches real Jev, but rejects independent action support0.87/0.85
below0.90 despite selecting scroll:down0.89/0.92. No input, no false_done,
AX viewport0->0, both documents unchanged/restored. Evidence:
c1-scroll-r2-joins-2/{comparison,results,decision-trace}.json.

Two concrete source gaps:

- JevChooser.swift242-248 defines TRUE beginning "For an implicit multi-step
  goal..." without clearly including an explicitly requested single operation.
- DriveCandidates.observationFields passes only tool and null bounds for
  background window primitives. It omits their actual declared arguments and
  target relationship. The loop still stamps pid/window_id at dispatch; that
  authority must remain outside the model.

The existing readonly native capture and unchanged model were used to separate
question wording from supplied facts. c1-scroll-support-probe.py retains every
state candidate; changes only the TRUE criterion's first sentence and the
declared diagnostic fields. No UI input, no production changes, no threshold
changes. These are older R4 native observations, not current signed-app proof.
Live TypeSafe Noul/API guidance was read: yes/no criteria should be unambiguous,
question IDs are not model-visible, and independent questions share state.

Fixed experiment results, each cell old criterion / clarified criterion:

| Input variant | Down | Up | Other window | Status only | Explicit page | Sidebar |
|---|---:|---:|---:|---:|---:|---:|
| Original facts | .86/.90 | .02/.02 | .18/.18 | .02/.02 | .91/.90 | not run |
| Actual arguments | .84/.88 | .02/.02 | .17/.17 | .02/.02 | .92/.92 | not run |
| Window scope | .88/.91 | .02/.02 | .15/.17 | .02/.02 | .91/.91 | .12/.13 |
| Arguments and scope | .87/.91 | .02/.02 | .19/.18 | .02/.02 | .95/.95 | .17/.17 |

Raw requests/responses are in workspace-local development/JevVoice directories
c1-scroll-support-{direct,arguments,scope,complete}-20261116. Source native
prototype SHA571b2585e905348a086944dfacb8905e9cbe8d8160c6e13afc7c65e2dd492dfd.
No unchanged reroll was used to authorize input. Negative probabilities and
the explicit-page regression in the wording-only variant remain visible.
This small matrix does not establish reliability or general accuracy.
Actual parameters remain in the proposed repair even where they reduce support.

## Concrete implementation

Owned production paths: Drive/DriveCandidates.swift and Drive/JevChooser.swift.
Owned checks: existing Tests/JevVoiceAppTests/JevChooserTests.swift.
Packaging only: existing jev-stage-candidate.py and verification-lane.sh for a
new final-r6 label; no budget, signer, dependency, model or runtime changes.
Frozen R5 and its receipts must not be overwritten.

1. In observationFields expose the actual request arguments for native
   background scroll/press_key primitives without an element target. Mark their
   declared target as a window. Do not expose caller literals, clipboard data,
   tokens, or invent any resolved region, capability, permission or effect.
   Prefer an explicit draft target declaration set by those primitive
   producers; null bounds alone must never imply window targeting.
2. In stateJSON complete only that declared window target with the same
   app/window fields supplied to the state. Preserve unknown/empty values.
   Do not mint or send execution pid/window/session authority. Both live
   JevDecider and DriveLoop.preview already use these shared factories.
3. Change only the first TRUE sentence to:
   "This exact operation on the identified target directly carries out the
   user's current instruction, or is one legitimate immediate step of
   currently unfinished work in an implicit multi-step goal, including UI
   preparation implied by the requested end state."
   Retain every subsequent constraint and the entire instructions/FALSE
   criterion. All0.90support/selection/applicability gates and no-false-success
   checks remain unchanged.
4. Add/update existing-file checks before production edits: actual request
   parameters survive the real chooser request, opposite directions and key
   arguments stay distinct, element/global actions acquire no window declaration,
   root app/window cannot be overwritten by caller extra fields, no execution
   IDs/grants are minted, and original drafts/state remain unchanged.
   Existing0.89support and0.69selection counterexamples must still refuse.
   The retained real-app failure and source/request omissions are the before.

## Verification and stopping boundaries

Use the existing release consumer lane for focused affected checks, preserving
failed evidence. No full1434+234 repeat merely for this repair. Standard production
release after testable builds, freeze current source, sign a separate final-r6,
explicit-current-receipt8package controls/component manifest, fresh G4, then
unchanged300-line TextEdit workload with actual independent AX viewport movement.
Stop a live run at its first failure, preserve it, and investigate evidence.
Never lower thresholds or omit inconvenient parameters to manufacture success.
Model-only probability changes cannot satisfy G5.

Compilation/test start budget remains3GiB; stage2.75GiB/stop1GiB remain unchanged.
Current filesystem is near2.8GiB and may block compilation. No further lowering,
no broad SDK/cache/source/evidence deletion, no protected-app alteration.
Complete permitted preparation and report a genuine resource block if needed.
Dailyf6, baseline29b4, savedc292, R4 651 and R5 7e8 stay preserved.

No C2/Terra, app whitelist, authority bypass, dispatch/retry change, or acceptance
flip. Physical conversation, accuracy/latency and C3 portability stay open.
