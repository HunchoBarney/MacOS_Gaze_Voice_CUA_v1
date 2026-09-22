# Voice simplification and ready microphone

**Date:** 2026-09-21. **Status:** Implementation authorized and in progress; automated verification underway, physical acceptance pending.

## Goal and scope

Make Fn immediately accept speech through an already-running microphone pipeline,
and leave one understandable production voice path before adding more features.
Keep native Swift, Apple SpeechAnalyzer, Jev, Cua, and the existing two modules.

This is a bounded follow-up to [SYDNEY-VOICE-PLAN.md](SYDNEY-VOICE-PLAN.md), not an
instruction to resume the whole migration. [SPEC.md](SPEC.md) and [PLAN.md](PLAN.md)
retain the other product requirements and acceptance gates. On implementation,
update the specification's idle-microphone policy to the behavior below: hardware
may remain active while ready; idle audio is neither retained nor transcribed.

Exclude model-prompt changes, stability-timer tuning, Cua execution optimization,
context/gaze work, live dictation, new frameworks, and UI redesign. Keep expensive
execution-check concerns as separate work rather than expanding this cleanup.

## Starting evidence

- `VoiceController.swift` mixes the production Cua route with a roughly 227-line
  legacy streaming/execution block and related state throughout the controller.
- Capture and interpretation both reconcile ranged transcripts; the coordinator
  also generates a capture identity separate from the capture's actual identity.
- Each hold builds and starts an audio engine after speech preparation. Eight
  recorded attempts reached first audio in 219–322 ms from capture startup;
  another spent 2,556 ms in synchronous audio-input setup on the main actor.
- Latest review regression: two tooling tests passed; 274 Swift tests reported,
  including 21 skips, with zero failures. Log: `.context/voice-review/default-tests.log`.
- Physical acceptance remains failed: unexplained capture termination,
  post-handoff recognition revision, and downstream execution failures remain
  recorded in [EVIDENCE.md](EVIDENCE.md). Cleanup does not erase these failures.

## Intended ownership and behavior

| Responsibility | Owns |
| --- | --- |
| Audio input | Long-lived engine, selected device, and admission of audio into a hold |
| Speech session | One hold's recognition, authoritative transcript revisions, and finalization |
| Intent coordinator | Pending/consumed speech, interpretation, and handoff |
| Existing task runtime | Execution, targets, task cancellation, and outcomes |

Reuse current components where practical. The UI displays capture and task state
separately; tasks may execute while listening. No generic workflow framework or
second executor is needed.

Once ready, the microphone stays running and idle buffers are discarded before
recognition. Fn down admits audio into a fresh session. Fn up closes admission,
drains accepted audio, and finalizes that session without stopping the microphone.
Prepare the next session outside the normal Fn path. Keep bounded buffering for
accepted audio; do not add pre-Fn history or continuously transcribe silence.

The macOS microphone indicator remains active while the hardware is in use.
Stop the hardware on quit, sleep/lock, loss of permission, or device interruption.
Reestablish readiness after recovery without reopening a speech session. Respect
the selected device and device changes; never silently substitute an unavailable
explicit selection. Initial preparation must report readiness truthfully.

## Work sequence

### 1. Remove the legacy route

Inventory the current dirty/untracked baseline and preserve a recoverable snapshot
before editing; this worktree already contains substantial unfinished work.
Trace old recognizer/executor/parser uses, including conditional fixtures and UI.
Move still-required behavior tests to production seams before removing their old
implementation. Remove legacy controller branches and exclusively used helpers;
retain shared values that still have a current use. Retire obsolete tests explicitly,
and keep unimplemented behavior recorded as open rather than claiming replacement.

**Done:** One production interpretation/execution route; relevant lifecycle tests
exercise it. Ordinary command behavior and model judgments are unchanged.

### 2. Simplify state ownership

Carry the same capture identity through recognition, interpretation and diagnostics.
Have one owner reconcile recognition ranges; pass its snapshots to consumers.
Keep submitted-span tracking separate from mutable recognition. Separate capture
state from task progress, and remove redundant flags and cleanup branches.

**Done:** Start, release, cancel, failure and late callbacks have clear owners.
Cancellation, no replay, intentional repetitions, literal content and manual mode
retain their existing behavior. Every capture has an observable terminal outcome.

### 3. Keep audio ready between holds

Separate microphone lifetime from speech-session lifetime. Move expensive device
setup off the UI/Fn critical path using one clear audio owner. Prepare recognition
for the actual input format. A finished SpeechAnalyzer is terminal: use a fresh
prepared session rather than attempting to restart it or accumulating one endless
transcript. Reuse the existing bounded feed and finalization behavior where suitable.

**Done:** Ready-state Fn presses do not recreate/start microphone hardware or wait
for routine asset preparation. Only in-hold audio reaches recognition; consecutive
holds remain independent, and release preserves accepted trailing audio.

### 4. Verify and document

Start with affected existing capture, Fn, transcript, coordinator and production
controller tests. Add coverage only for changed lifecycle behavior and genuine
gaps. Run `make test`, `make app`, strict/deep codesign verification, and
`git diff --check`; verify a clean disposable checkout of the complete intended
changes as required by [DEVELOPMENT.md](../DEVELOPMENT.md).

With scoped live authorization and the shared desktop lock, compare microphone
readiness and first accepted audio before/after. Report cold preparation separately
from warm holds, sample counts and failures. Physical acceptance includes at least
five immediate-release and two longer-hold trials, checking first/final words,
before-release handoff, duplicate effects and UI responsiveness. Record recognition,
handoff and desktop outcome separately; simulated Fn events are not physical proof.

**Done:** Warm input admission measurably improves, affected checks pass, and the
identified build passes the physical voice trials. Unresolved physical failures or
external execution failures remain explicit; do not claim overall migration completion.
Update architecture/usage docs and build-specific evidence to match delivered code.

## Preservation and execution boundary

Keep credentials, preferences, app identity, dependency pins, unrelated work and
`development/` intact. Do not replace the installed app or Driver as cleanup.
Local identity/cancellation checks and no-replay accounting remain; removing them
is not a substitute for eliminating setup work or duplicate ownership.

Implementation was authorized by the user on 2026-09-21. Execute these steps
in order with focused, reviewable changes; use existing live-test authorization
only where it actually applies. Physical trials require user participation.

Progress: [x] legacy removal · [x] state ownership · [x] ready microphone implementation · [ ] verification/physical acceptance

Current refresh (2026-09-22): candidate `8cb7278a…34fc7e5` passes default tests,
release/signature and clean-checkout verification. The30-hold microphone runner
remains permission-blocked; physical acceptance is pending the
[coordinated trial sheet](SYDNEY-VOICE-TRIALS.md). See the latest EVIDENCE.md entry
for current semantic failures and separate recorded/interpretation timings.
