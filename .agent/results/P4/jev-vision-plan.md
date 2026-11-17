# General Jev Visual Fallback

Status: G1 APPROVED by the user, including independent read-only G2/G4
reviews. G2 reviewer b0eba62d returned final PASS with no findings after
both hardening requests were incorporated. A later installed-driver
contract check uncovered an M3 gap; G2 follow-up is FAIL for complete
generic input without a driver amendment. App transport/capture may
continue; driver scope requires user approval. See
`jev-vision-driver-amendment.md`.
This does not mark any P4 acceptance criterion complete.

## Purpose

Jev should operate ordinary apps even when their accessibility tree is
empty, incomplete or misleading. Users must not enable app-specific flags,
install extensions or restart an app to make its controls available.
Keep the existing fast text/AX/DOM paths; add a general, demand-driven
window-image path within the same TaskLoop.

## Current Evidence

- Current signed, uninstalled candidate:
  `jev-candidate-stage-53e1cfa34ff7489685ea2676cc9bdde4.json`.
- Scoped browser preparation regression: before 192 tests / 3 assertions
  failed; after 192 / zero failures. Blocked replies now retain recent
  steps. The new candidate is not real-app-qualified or independently
  reviewed. Its inherited unresolved resource-aggregate caveat remains
  in the receipt; strict signature verification is not its resolution.
- `JevDecider.wantsScreenshot` is false. `DriveCaptureSource.screenshot`
  returns an empty object. The client sends no assets and cannot decode
  Box. A model capability exists that this app has not integrated.
- The pinned Cua 0.38 driver already supplies bounded window PNGs,
  screenshot dimensions, window bounds and capture IDs. Pixel clicks
  accept a capture ID and atomically reject mismatched/stale captures.
  No driver swap or new screenshot backend is needed.
- An ordinary TextEdit synthetic document was captured without app flags.
  Only its window was captured, not the desktop. The unchanged owned
  document was closed and its file retained. No model-selected action ran.
- Four live requests used pinned Jev 1.14.0, no AX or app name in model
  state, and no retries. No-image control chose unknown. Three image
  requests chose document with probability .98-.99. Close presence was
  .95, absent Play presence .01 and absent replacement text .00.
- All three image responses nevertheless returned a Play box. Editable
  body presence was uncertain (.34-.43); images do not prove editability.
  Boxes alone cannot authorize actions. Location accuracy and action
  success are NOT established by these calls.
- Image request times were 222.39-240.40 ms. These are three model requests,
  not end-to-end timings or a controlled speed comparison with text:
  the image requests also asked additional Box questions.

Raw evidence and screenshot:
`vision-readonly-2250aa40282940289214708c21894287/`.
Initial no-owned-window setup failure is retained separately; the guard
did not substitute a user's document.

## Current Docs

Retrieved 2026-11-09:

- https://docs.typesafe.ai/images.md
- https://docs.typesafe.ai/primitives/box.md
- https://docs.typesafe.ai/api/system-one.md
- https://docs.typesafe.ai/confidence.md

Images/Box are explicitly experimental ("Dreamer-ready"), not advertised
as production-ready. Jev 1.14 accepts both. Requests require the
`TypeSafe-Danger-Zone-Images: true` header, a top-level assets map and
unique image references in state. Images are PNG/JPEG, both sides
280-1568 px, <=16 MiB/image. Repeated references duplicate image context.
Box coordinates are normalized edges, not screen coordinates. Box always
returns coordinates even when a target is absent. API schema permits
null confidence. Never fabricate missing confidence.

## Requested Contract Amendment

1. PROGRAM currently pins vision/reasoning to Sol and T3 to AX-only.
   Permit experimental Jev image judgments/Box for T3 fallback, without
   replacing Sol's later planning/recovery role or changing providers.
   Do not rename away the existing reliability or four-second target.
2. Extend typed Question/Answer and SystemOneRequest with Box/assets.
   Add a defaulted assets argument to JevClient; text callers remain
   byte-shape compatible and never send the image opt-in header.
3. Extend the frozen observation seam with a combined scoped capture
   and a defaulted decider request for pixels. Existing consumers retain
   their current behavior. A fallback rereads AX+pixels together so
   image capture cannot silently invalidate the chosen AX tokens.
4. Carry a validated image identity, original/returned dimensions,
   transform, PID/window, capture ID and observation generation.
   Add typed internal visual targets/evidence, not public raw x/y tools.
5. Extend verification for image-observable outcomes. A localization
   judgment, dispatched click, quiet screen or changed pixel hash is
   never a completed task. Preserve exact AX/text/file oracles wherever
   available. Visual claims cannot prove hidden backend or byte-exact
   outcomes that are not observable.

Consumers for G2/G4 review: TaskLoop, JevDecider, DriveLoop run/preview,
JevChooser, ObservedGoalProof, JevClient, JevSelection, synthetic recorder,
voice coordinator, and future P5/P7 CaptureSource/Decider consumers.
Gaze remains resolved-target identity only. Realtime receives no images.
Public drive_until/suggest_action and permission schemas stay unchanged.

## Proposed Owned Paths

All are repo-relative. This list extends the existing P4 ownership only
after approval; other writers' paths remain untouched.

```text
Sources/JevVoiceCore/Models/JevModels.swift
Sources/JevVoiceCore/Models/JevClient.swift
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/JevDecider.swift
Sources/JevVoice/Drive/JevChooser.swift
Sources/JevVoice/Drive/DriveCandidates.swift
Sources/JevVoice/Drive/JevVisualDecision.swift
Sources/JevVoice/Drive/VisualTarget.swift
Sources/JevVoice/Drive/VisualGoalProof.swift
Sources/JevVoice/Drive/ObservedGoalProof.swift
Tests/JevVoiceTests/JevModelsTests.swift
Tests/JevVoiceTests/JevClientTests.swift
Tests/JevVoiceAppTests/TaskLoopTests.swift
Tests/JevVoiceAppTests/JevDeciderTests.swift
Tests/JevVoiceAppTests/DriveLoopTests.swift
Tests/JevVoiceAppTests/JevVisionTests.swift
scripts/verification-lane.sh
.agent/results/P4/**
.agent/phases/P4-taskloop-jevdecider.md
.agent/PROGRAM.md
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

## Milestones And Checks

### M1 Typed Transport And Capture

Before code, record failures for absent asset references, oversize images,
malformed/nonfinite/reversed/out-of-range/zero-area boxes, null confidence, pixel transforms,
text-only header/body compatibility and same-frame AX tokens.
Use the existing driver, not ScreenCapture.jpeg (that captures a display).
Keep all actual/window/prepared scales explicit; the read-only prototype's
prepared PNG was resized after capture and is NOT a clickable frame.

Proposed focused lane `p4-vision-transport` must pass the new model/client
and capture seam checks. The text-only request golden must be identical.

### M2 Demand-Driven General Decisions

AX sufficient: no image or image API header. Missing/partial AX,
unavailable targets or evidence ambiguity: request scoped pixels without
restarting the app. Do not reject just because AX is empty.
Use goal, recent progress and observed state. Select a bounded primitive
and caller-supplied literal, then locate its visible target. Ask presence
and location separately; independent speculative questions may share a
request. If clarification needs another call, use new evidence or a crop,
not repeated votes until one agrees. Retain probability distributions.
Do not require app-name branches, hidden three-choice cutoffs, default
round ceilings or slower per-action models.

Proposed focused lane `p4-vision-decisions`: tests fail first on old code;
AX-only behavior is unchanged; empty-AX image-only positive and absent
target negative cases pass. Uncertainty must remain uncertainty.

### M3 Actuation And Outcome Proof

Code binds every visual target to the current goal/task and exact
PID/window/capture. Convert normalized image coordinates using the exact
capture transform, never desktop/gaze coordinates. Cua atomically consumes
the matching capture. Cancellation, moved/closed/foreign windows, changed
session and stale captures refuse before input. Never substitute a sibling.
The read transport's capture_id passes unchanged to the act transport;
missing capture_id always refuses visual input, never a fallback click.
Prefer AX/DOM identity when it can ground the same intended target.

Presence does not imply authorization. Preserve deny strings, protected
actions, typed literal authority and consent. Unidentifiable or potentially
protected visual targets cannot silently become harmless clicks.
Verify fresh visible outcomes separately; a generic screenshot hash change
or animation is not task progress. Test forged visual completion, offered
buttons, changed subject, stale/replayed frames and already-complete goals.

Proposed focused lane `p4-vision-authority`: all negative controls refuse;
zero unexpected input dispatches or false completion claims.

### M4 Real Apps Through The Signed Product

Compare the pre-vision signed candidate and the new signed candidate on
the same controlled goals and verifier, not standalone API scripts.
Include genuine missing-AX surfaces and withheld-AX ablations; label them
separately. Use normal app launches, never accessibility-enabling flags.
Chrome/Safari: only owned windows/public pages. Notes: reuse the ONE
labelled test note, retain it. TextEdit: owned synthetic document only.
Spotify: search/navigation first; playback only with independent local
device attestation, never change routing. Calculator: owned surface only.

Run via the serialized lane and desktop lock. Assert app state and truthful
completion separately, preserve original failures, publish actual timing
including capture/upload/refinement and all refusals/cancellations.
No claim about physical Fn/microphone follows from MCP trials.

Promotion requires existing P4-5: >=95% strict independently verified
success, Wilson intervals reported, p50 <=4000 ms, zero false_done, plus
zero wrong-window/unauthorized mutations. No criterion changes to force
promotion. Source+negative-controls alone justify a bounded experimental
candidate, not enabling this by default or installing it.

## Gates And Non-Goals

G1: user approves this amendment once. G2: fresh read-only independent
review accepts boundaries and checks before production code. No helper
agent is launched without user authorization. G3 serialized checks;
G4 fresh review; G5 real-app/budget proof; G6 human try; G7 truthful
handoff, commits only if asked. No phase acceptance is self-issued.

No app flags/settings/extensions, app-specific screenshot recipes, driver
upgrade, new dependencies, public raw-coordinate tool, whole-desktop
capture, private note/browser capture, secure-field recording, policy
bypass, signature bypass, automatic install or threshold reduction.

## Progress / Discoveries / Decisions / Outcome / Handoff

Research and read-only probe complete. User approved G1 and read-only reviews.
M1 transport implemented: 25 focused checks pass.
M2 combined scoped capture, conditional capture and opt-in routing:
41 focused checks pass after failing-first regressions.
Production image inference/input/proof callbacks are NOT fully connected.
New M3 driver gap is independently confirmed; complete input is blocked
on the proposed driver-scope amendment, not silently reduced to clicks.
Current candidate 53e remains uninstalled. P4-5/P4-6 remain false.
Read-only experiment exposed both absent-target boxes and uncertain
editability; these must shape the implementation, not be relabelled green.
Original G2 b0eba62d PASS; complete-input follow-up FAIL on the installed
driver's absent non-click capture-ID admission. No Cua changes made.
