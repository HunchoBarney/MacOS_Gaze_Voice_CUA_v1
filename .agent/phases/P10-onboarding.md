# P10 — onboarding ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: agent+voice · Depends on: P3, P6; consumes P7/P8/P11/P12 readiness
> Branch: `ship/v1-p10` · Acceptance: `.agent/acceptance/P10.json`
> Contracts: §3 public capabilities, permissions, tracker readiness

## Purpose

Make first use install, grant permissions, use Fn/pill; demonstrate three
real useful tasks within three minutes and provide trustworthy everyday
feedback, read-back, supported undo and actionable errors.

## Context

Read PROGRAM desirability, SHIP-PLAN C3 and current capability handoffs.
`UI/OnboardingChecklist.swift` suggests screen questions while that
executor remains unavailable. `Settings/Permissions.swift`, SettingsView,
VoiceController and TrackerHost expose pieces of readiness; complete
setup and packaged behavior remain unproven.

## Reuse decision

Reuse existing SwiftUI/VoiceStyle components and Apple's supported TCC/
Settings guidance, accessibility and system UI. Consume actual executor
capability/readiness rather than inventing a parallel configuration
framework. Use existing task receipts and local diagnostics for feedback.
No third-party analytics or replacement design system is needed.

## Owned paths

```text
Sources/JevVoice/UI/OnboardingChecklist.swift
Sources/JevVoice/UI/OnboardingFlow.swift
Sources/JevVoice/UI/SettingsView.swift
Sources/JevVoice/UI/ContentView.swift
Sources/JevVoice/UI/VoiceStyle.swift
Sources/JevVoice/Settings/Permissions.swift
Sources/JevVoice/Settings/Config.swift
Sources/JevVoice/Voice/VoiceController.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Support/FeedbackStore.swift
Sources/JevVoice/Support/TesterMetrics.swift
Tests/JevVoiceAppTests/UXOnboardingTests.swift
Tests/JevVoiceAppTests/UXConfigDefaultsTests.swift
Tests/JevVoiceAppTests/VoiceToolResultTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorOverlayTests.swift
scripts/verification-lane.sh
.agent/phases/P10-onboarding.md
.agent/acceptance/P10.json
.agent/results/P10/**
.agent/PROGRESS.md
```

## Non-goals

For the competitive dictation work, consume P3's actual mode and quality
contract. If personalization/correction learning is introduced, provide
explicit local controls, deletion and honest capability status. Distinguish
recognition corrections from stylistic rewrites; never collect private
dictation content by default. COMPETITIVE's editing measures are separate
from successful insertion and from source-only UX tests.

No fake magic moments, unavailable command suggestions, TCC bypass,
per-app setup rituals, forced profile cloning, invented undo support or
new external analytics service.

## Milestones

### M1 — actual capability and permission readiness

**Change:** connect setup steps to actual speech, driver, browser and
tracker readiness. Guide required Microphone/Accessibility/Screen
Recording/Camera and enabled Automation/calendar/contact permissions.
Explain Chrome's real per-launch consent/Safari setting accurately.
Distinguish first grant, revoked permission, missing resource, no network
and genuine ready state. Cold local readiness cannot wait on a cloud key.

**Check:** add and run `scripts/verification-lane.sh p10` → nonempty
existing UX/readiness suites; denied/revoked/missing states cannot show
ready or suggest unavailable commands. No implicit input from calibration.

**Evidence:** `.agent/results/P10/contract-review.md`, `source-review.md`
and permission/capability state matrix.

### M2 — three real moments and daily trust

**Change:** guide read my emails, look + open this, add an event. Use
existing configured accounts; record account/setup preconditions honestly.
Wire <=300ms required acknowledgment, new S-FEEDBACK goal, progress for
long tasks, bound read-back, cancellation, actual reversible undo,
that-was-wrong feedback and redacted local diagnostics/metrics.
Maintain honest done/already/blocked/uncertain/handed-back outcomes.

**Check:** `scripts/verification-lane.sh p10`; normal-product flows show
the real result or useful remedy. UI status cannot complete before the
executor's independent proof; undo applies to the exact owned action
only. Inspect real light/dark and accessibility states in the app.

**Evidence:** `.agent/results/P10/integration.json`, observed outcomes,
read-back/undo/cancel cases and redaction checks.

### M3 — first-use and human qualification

**Change:** run the signed bundle on a clean Jev profile with declared
test-account readiness. Do not pre-seed first-run completion flags for
this measurement. Group this human session with P11/P12/P13 where the
same frozen artifact and conditions satisfy their criteria.

**Check:** three actual moments <=3 minutes from declared first launch,
with permission/setup time visible; no recurring Jev-controlled prompt.
Physical Fn/pill and gaze selection work, failures have an actionable
remedy and the user can finish without developer tools.

**Evidence:** `.agent/results/P10/qualification.json`, event timestamps,
actual permission prompts, human checklist and signed artifact identity.
Required integrated lane plus independent review passes.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P10-1 | M1 | capability/permission/readiness |
| P10-2 | M2/M3 | three actual first-run moments |
| P10-3 | M2 | honest feedback, progress and errors |
| P10-4 | M2 | bound read-back, supported undo and cancel |
| P10-5 | M2/M3 | local metrics, feedback/redaction and UI |
| P10-6 | M3 | human G6 and independent review/handoff |

## Gates

G1/G2 pending. G3 uses the serialized lane. G5/G6 need actual accounts/
permissions on the frozen artifact; a unit fixture is not first-use
proof. Missing capability keeps the phase open, rather than replacing a
demonstration with canned data. Physical requirements stay explicit.

## Progress

- [x] Draft/default-fail criteria prepared.
- [ ] M1 readiness.
- [ ] M2 daily UX.
- [ ] M3 first-use qualification.

## Surprises & Discoveries

Development installation and a checklist do not prove a portable first
run. Permission grants cannot be assumed from the developer's existing
TCC state, and macOS-owned behavior must be described accurately.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Onboard against real capabilities and reuse current UI | Complete setup without advertising unimplemented features |

## Outcomes & Retrospective

No first-use timing or human success claimed. Six criteria remain false.

## Handoff

Next: freeze actual capability readiness contracts after P3/P6 and related
executor handoffs. Preserve existing preferences; a migration cannot
silently grant permissions or enable dwell. A broken new flow retains a
usable permission/settings path and reports its actual blocker.
