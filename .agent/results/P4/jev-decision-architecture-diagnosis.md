# P4 Decision Architecture Diagnosis

2026-11-12 UTC. Read-only investigation after the user requested a different
approach and an end to repeated testing. No new model requests, desktop
commands, tests, builds, installation or policy changes during this investigation.

The main design problem is an underspecified next-step decision shared
implicitly across independently evaluated questions. The controller also
routes semantic uncertainty into visual observation without distinguishing
why the decision failed. Repeated wording patches do not repair that
composition. This is a source-backed diagnosis of the design; it does not
establish the unrecorded final refinement gate in the latest D14 failure.

## What The Current Documentation Actually Says

Read live on this date:

- https://docs.typesafe.ai/concepts/how-to-build-with-system-one.md:
  code owns the workflow; broad judgments should become explicit,
  narrow questions. This does not prohibit bounded action selection.
- https://docs.typesafe.ai/primitives.md:
  questions in a batch are independent and cannot see one another's
  answers. A dependent judgment needs explicit state from the earlier
  answer; otherwise independent questions belong in one request.
- https://docs.typesafe.ai/confidence.md:
  Choice confidence summarizes the distribution; the selected probability
  concerns the question actually asked. It is not whole-workflow accuracy.
  Our code already uses selected probability, so confusing the API's
  confidence field with probability is not the bug.
- https://docs.typesafe.ai/primitives/noul.md:
  a Noul judges one yes/no proposition. Avoid calibrating a threshold
  against a handful of examples.
- https://docs.typesafe.ai/primitives/box.md:
  a Box always returns coordinates, including for absent targets. Keep
  presence and location distinct. There is no universal recommended Box
  confidence floor.
- https://github.com/vercel-labs/agent-desktop:
  snapshot-bound references, observation, action delivery and the calling
  agent's decision loop are distinct. The driver has no model inside.
  Its documentation is not evidence of superior measured task reliability.
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool:
  the model proposes tool calls, the application executes them, and results
  return to the next decision. This is architectural reference, not a
  proposal to replace Jev or change model policy.

## Confirmed Problems And Their Limits

1. **The current instruction is the entire goal.**
   `DriveCandidates.swift:69-74` sets `current_instruction` to `goal`.
   Voice steps are retained as advisory prose in `previousContext`
   (`VoiceTaskCoordinator.swift:802-805,848-854`); they are not missing
   from the native model state (`JevDecider.swift:413-426`). There is no
   explicit current substep/progress contract at this decision boundary.
   Each decision must infer it again from the goal, screen and history.

2. **The first visual batch does not bind every question to one proposal.**
   `JevVisualDecision.swift:130-146` separately asks for the next operation,
   whether the next target exists, and the next target's box. Each infers
   “next” from the whole goal. For a multi-step goal, the shared state
   does not require these answers to concern the same proposed step.
   The later grounding request already binds `proposed` and native object
   identity; that useful machinery should be reused. Different primary
   interpretations are a design risk, not an observed per-head target
   disagreement: the existing boolean answers do not identify their targets.

3. **Failure recovery confuses decision uncertainty with missing perception.**
   `JevDecider.swift:249-286` sends low choice/applicability and returned
   reobserve/stuck decisions to `requestPixels()`. Its reason says AX did
   not ground the step even when the native observation is complete.
   This is a confirmed routing conflation. An image may add useful
   evidence, but it cannot be assumed to resolve an unclear next step.

4. **Preference and candidate validity remain coupled.**
   `JevChooser.swift:378-405` asks whether each primitive is a legitimate
   unfinished step and separately asks which is next.
   `JevChooser.swift:437-438` requires both support >=0.90 and the selected
   Choice's floor. When several steps are acceptable, their relative
   ranking is not the same proposition as an exact action's validity.
   This is not permission to ignore ambiguity about the user's intended
   target, relax a threshold, or dispatch any vaguely relevant control.

5. **Completion has repeatedly depended on inconsistent semantic categories.**
   The retained D13 diagnosis records goal evidence .99, native scope .99,
   selected output 1.00 and native support .99, while `exact_text` .89
   failed the .90 kind gate. D13 repaired that producer/consumer definition.
   This is a historical demonstrated failure, not a claim that the same
   defect still exists. It shows why adding another predicate is not
   automatically stronger evidence.

## Existing Captures, Without Another Run

The saved source-factory capture at
`completion-research-20261110/native-refinement-source-capture` has:

- Primary All Clear probabilities .74 and .69, with press3 at .23 and .29.
- Refinement All Clear probability .89 and support .86.
- All36 support answers remain below .90; the next highest is .43.
  There was no passing alternative discarded in this record. Removing
  only the Choice floor would not fix this captured refusal.
- Visual fallback chooses click .97, presence .86, box confidence .35.

These are historical read-only source captures, not new signed commands.
They establish a semantic refusal, not a lost score or skipped refinement.
The last D14 signed failure has complete native context and primary .66,
but its actual refinement response was not retained. Do not invent it.

The signed D13 comparison was3/3 versus0/3; D14 was2/3 versus3/3.
Those small samples do not establish a release success rate. Unit and
source-review counts do not resolve this uncertainty.

## A Separate Observation/Latency Problem

The Swift reader's500ms deadline starts after initial window/document
lookups and is checked between traversal iterations. Several synchronous
AX calls can run within one iteration; final continuity checks occur
afterward (`NativeWindowObservation.swift:314-359,436-452`).
It is not a hard wall-clock bound for the whole read.

The reader already sets0.2s messaging timeouts on visited nodes. Do not
propose adding that as if it were missing. The installed Apple SDK's
AXUIElement.h documents that a timeout applies only to that particular
AX object, not even to another equal reference.

Retained SDK reads took1.427s for44nodes and, on another attempt, returned
only4nodes after5s. Those are a different reader. The Swift budget
structure does not establish the cause of the SDK stall. Raising private
setup waits again would not establish a production repair.

## Recommended Replacement For The Decision Boundary

Keep Jev, the generic native/image tooling and existing authority checks.
Make one proposed step explicit before judging its target and consequences.
Every applicable judgment must reference that same step and captured state.
Code should retain progress from observed effects, with inferred plans
remaining advisory. A fresh observation still owns completion proof.

Distinguish unavailable evidence, ambiguous next step, unsafe action and
unproven outcome. Acquire images for a perception need; interpret or revise
the proposed step for semantic uncertainty. Do not turn either into a
generic driver refusal.

Define the requested outcome and permitted evidence consistently across
selection and fresh verification. Preserve exact native identity/value,
literal authority, freshness, consent and hidden-state requirements.
Use the existing batched questions where independent; avoid serial
re-questioning of the same state. Reuse the existing bound grounding and
proof code rather than adding a second executor or per-app recipes.

This requires a coherent decision-contract change, not another local
wording adjustment. It is not implemented or qualified. The size of its
reliability/latency effect is unproven. It does not authorize changed
thresholds, model/pricing policy, installation or additional live runs.

## Paused D15 Work

The two trace-only production files are implemented and source-reviewed.
The focused lane ultimately passed36 checks; the preview harness passed8.
The eight captured before/after request semantics, outcomes and counts match.
No D15 signed preview occurred.

Staging stopped before compilation because its supplied D14 admission
receipt still binds the two pre-D15 source hashes. Original bundles remain
unchanged; verified baseline clones and the failure log are retained.
The user then redirected work to this investigation. Do not automatically
resume staging or consume the old preview approval instead of addressing
the revised direction. P4 remains4/6; P4-5/P4-6 remain false.
