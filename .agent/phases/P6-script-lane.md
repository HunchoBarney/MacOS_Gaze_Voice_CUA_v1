# P6 — script-lane ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: agent+voice · Depends on: P3; browser variants consume P7
> Branch: `ship/v1-p6` · Acceptance: `.agent/acceptance/P6.json`
> Contracts: §3 realtime, §4 ScriptIntent, §7 bench, §8 ledger

## Purpose

Complete inbox/messages, calendar/reminders/notes and morning brief using
fast typed operations, with real results and read-back for consequential
actions. Reach them through the normal voice/typed task interface.

## Context

Read SHIP-PLAN C2, REUSE, P3's current handoff and CONTRACTS §3/§4.
`Voice/RealtimeVoiceClient.swift` marks run_script/inbox_brief unavailable.
`Drive/VoiceTaskCoordinator.swift` owns dispatch; FastLane provides
existing native primitives. The ScriptIntent registry/executor is absent.
An interface-ready P3 handoff permits implementation; physical P3
acceptance remains open. Gmail/Slack web variants require P7 readiness.

## Reuse decision

Use Apple-supported EventKit, Apple Events dictionaries, Shortcuts and
existing native/browser drivers. Inspect existing integrations before
writing an app adapter; use maintained compatible FOSS where available.
Use Foundation for dates/timezones and structured serialization.
Keep argv validation/registry as minimal product glue. Do not distribute
raw Swift helpers requiring Xcode; use OS runners or compiled helpers.
Record helper/binary/license and permission requirements at G2.

## Owned paths

```text
Sources/JevVoice/Scripts/**
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Voice/RealtimeVoiceClient.swift
Sources/JevVoice/Contracts/JevContracts.swift
Sources/JevVoice/Settings/Permissions.swift
Sources/JevVoice/main.swift
Tests/JevVoiceAppTests/ScriptIntentTests.swift
Tests/JevVoiceAppTests/ScriptExecutorTests.swift
Tests/JevVoiceAppTests/VoiceTaskContractTests.swift
Tests/JevVoiceAppTests/VoiceToolResultTests.swift
Tests/JevVoiceAppTests/PolicyTypedPayloadTests.swift
Tests/JevVoiceAppTests/PolicyScopedGrantsTests.swift
scripts/intents/**
scripts/verification-lane.sh
bench/run.py
bench/lib/mcp_stdio.py
bench/lib/results.py
bench/lib/verifiers.py
bench/selftest.py
bench/tasks/p6-*.json
bench/reset/p6-*
Makefile
ThirdParty/OPEN_SOURCE_NOTICES.md
.agent/phases/P6-script-lane.md
.agent/acceptance/P6.json
.agent/results/P6/**
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

## Non-goals

No model-generated shell/script/JavaScript, new general planner, real
recipient sends during tests, app-specific enablement prerequisite or
claim of persistence from a successful process exit alone.

## Milestones

### M1 — typed registry and safe execution

**Change:** define entries for read/brief/draft/message operations,
calendar events, reminders and note operations. Each entry carries
typed args, declared target/account, allowed argv/native helper,
confirmation class, verifier and supported reversal. Resolve contacts
uniquely; compute dates/timezones in code. Add NSAppleEventsUsageDescription
and other required usage strings in the existing Makefile-generated
bundle metadata. Preserve global deny policy in every lane.

**Check:** add and run `scripts/verification-lane.sh p6` → nonempty
registry/executor/policy tests pass. Quoting, Unicode, shell metacharacters,
unknown args, ambiguous contacts, changed recipient, canceled approval
and uncertain subprocess result cannot produce unintended input.

**Evidence:** `.agent/results/P6/contract-review.md`, `source-review.md`;
G2 records reuse, chosen packaging shape and consumer review.

### M2 — real hero routes and consequence proof

**Change:** connect run_script and inbox_brief through normal admission.
Cover Mail/Gmail, Messages/Slack through supported native/browser routes,
Calendar, Reminders and Notes. Read-back binds recipient/content/time;
affirmation authorizes that exact unchanged action. Read results back
from native/API/DOM state; report uncertain if persistence cannot be
proven. Keep prepared drafts separate from actually sent messages.

**Check:** `scripts/verification-lane.sh p6`; controlled front-door
cases show advertised tools reaching real executors and correct results,
wrong-account/target refusals and cancel behavior.

**Evidence:** `.agent/results/P6/integration.json` with capability,
entrypoint, typed args without secrets, consent binding and result oracle.
Use test accounts/owned fixtures; no production message or data mutation.

### M3 — latency, injection and app breadth

**Change:** add tagged corpus/oracles to the existing bench. Review any
§7 injector change needed to reach the normal script route; drive_until
alone does not prove that route. Use P7 for actual browser variants.

**Check:** SHIP-PLAN desktop-lock command with tag `p6`; required signed
hero runs and injection/permission/cancellation cases. Per-intent success
>=99%, p50 <=1.5s, brief <=5s; PROGRAM Wilson requirement and zero
unauthorized/duplicate/false-Done results. Report S-NATIVE/S-WORKFLOW.

**Evidence:** `.agent/results/P6/qualification.json`, result readbacks,
spend/resource rows and candidate manifest. `scripts/verification-lane.sh all`
is the integrated boundary gate; independent review closes criteria.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P6-1 | M1 | typed registry, packaged helper and reuse |
| P6-2 | M1 | argv/injection/target/consent failures |
| P6-3 | M2 | all hero families through public routes |
| P6-4 | M2 | independent results and supported undo |
| P6-5 | M3 | per-intent/brief performance and safety |
| P6-6 | M3 | authorized independent review/handoff |

## Gates

G1/G2 pending. G3 uses the serialized lane. G5 mutations are only in the
declared isolated fixtures/test accounts. Physical voice evidence is
shared with final P3/P10/P13 qualification, never inferred from typed
invocation. G6 checks one useful hero flow, read-back and cancellation.

## Progress

- [x] Draft and default-fail acceptance prepared.
- [ ] M1 registry/executor.
- [ ] M2 normal-product hero routes.
- [ ] M3 live qualification.

## Surprises & Discoveries

The current example registry invokes a Swift source helper; the shipped
product cannot rely on a developer toolchain. Resolve that packaging
detail at G2 without changing the argv/confirmation safety contract.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Native/OS/FOSS operations first; same authority across lanes | Complete fast hero work without a bespoke automation framework |

## Outcomes & Retrospective

No executor or benchmark has been implemented by this documentation pass.
All six criteria remain false.

## Handoff

Next: approve the exact registry/helper/permission contract and P3 handoff,
then M1. Keep incomplete capabilities honestly unavailable until connected.
On failure preserve receipts and disable only the invalid new registry
entry; do not fall through after an uncertain mutation or lose generic
native/browser/visual capability.
