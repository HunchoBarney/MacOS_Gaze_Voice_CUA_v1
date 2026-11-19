# P5 — general-decider ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: agent+voice · Depends on: P4 · Branch: `ship/v1-p5`
> Acceptance: `.agent/acceptance/P5.json` · Contracts: §1, §2, §3, §7, §8

## Purpose

Keep Jev as the primary semantic chooser and add GPT-6.1 Terra API
recovery for genuine planning, generation or unresolved UI reasoning.
Cua/native tools act through the existing loop; neither model gains
execution, permission or completion authority.

## Context

Read PROGRAM, PLANS, SHIP-PLAN C2, COMPETITIVE, REUSE and the CONTRACTS
shipping queue. The user explicitly approved Terra API access; a new
ChatGPT sign-in implementation is not a prerequisite.
`Sources/JevVoice/Drive/DriveLoop.swift` currently constructs JevDecider;
escalation can hand back rather than invoke the planned general decider.
`VoiceTaskCoordinator.swift` owns public task dispatch and terminal UX.
`Voice/RealtimeVoiceClient.swift` marks screen questions/web lookup
unavailable. `Agents/CodexRuntimeBridge.swift` is a distinct existing
complex/background route; preserve it.

P4's reviewed interface/source milestone can unblock implementation,
while upstream G5/G6 remains explicitly open. Freeze its source hash and
contracts. P4 acceptance is never inferred from that handoff.

## Reuse decision

First evaluate MacPaw/OpenAI against the actual `gpt-6.1-terra` API's Responses computer actions,
pending_safety_checks, streaming/cancellation and required transport;
SwiftOpenAI is the second candidate. Both are MIT community clients.
Record exact tag/API gaps and notices at G2. Use URLSession/platform
support only for a documented SDK gap and keep `OpenAIResponsesClient`
a thin product adapter. Keep TaskLoop, Cua, Codex and existing JSON types.

## Owned paths

For KAR-15 the P3 integrator owns the shared RealtimeVoiceClient wire changes
and the new ControlReplyEnvelope decoder/tests. P5 has no competing writer.

```text
Sources/JevVoiceCore/Models/OpenAIResponsesClient.swift
Sources/JevVoiceCore/Models/ComputerUseProposal.swift
Sources/JevVoice/Drive/RecoveryDecider.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Voice/RealtimeVoiceClient.swift
Sources/JevVoice/Contracts/JevContracts.swift
Sources/JevVoice/Support/LatencyLedger.swift
Tests/JevVoiceTests/OpenAIResponsesClientTests.swift
Tests/JevVoiceAppTests/RecoveryDeciderTests.swift
Tests/JevVoiceAppTests/TaskLoopTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift
Tests/JevVoiceAppTests/VoiceTaskContractTests.swift
Tests/JevVoiceAppTests/CuaPolicyTests.swift
Package.swift
Package.resolved
ThirdParty/OPEN_SOURCE_NOTICES.md
scripts/verification-lane.sh
bench/run.py
bench/lib/mcp_stdio.py
bench/lib/results.py
bench/lib/verifiers.py
bench/selftest.py
bench/tasks/p5-*.json
bench/reset/p5-*
.agent/phases/P5-general-decider.md
.agent/acceptance/P5.json
.agent/results/P5/**
.agent/CONTRACTS.md
.agent/PROGRAM.md
.agent/PROGRESS.md
```

## Non-goals

No ASR replacement, separate execution loop, desktop code-as-action,
automatic safety acknowledgment, model-written permission/confidence
tokens, provider/pricing change without its decision, or new background
agent features. EyeTracking source is outside this phase's owned paths.

## Milestones

### M1 — SDK-backed adapter and authority boundary

**Change:** freeze SDK/contract choices; list failure cases before code.
Implement typed Responses proposals and RecoveryDecider (the earlier
unimplemented plan called it SolDecider) using existing
TaskLoop execution/verification. Preserve exact literals, snapshot-bound
targets, caller scope and cancellation after every await. Unknown tool/
safety events block. A sequence checks each step and stops on changed
state; it never bypasses consent. Add a `p5` verification-lane mode for
the named existing/new tests; a missing mode is not a passing check.

**Check:** `scripts/verification-lane.sh p5` → nonempty targeted suites
pass; unknown action, pending safety without consent, stale completion,
wrong scope, interrupted stream and duplicate delivery produce no
unauthorized input or false Done.

**Evidence:** `.agent/results/P5/contract-review.md` and
`source-review.md`, including adopted package/version/license,
counterexamples, consumer review and exact source hash.

### M2 — public routes and escalation

**Change:** wire Jev escalation, screen questions and web lookup through
normal task admission. Preserve code-owned goal/target scope, source
citations for lookup, effort escalation on failed verification, bounded
no-progress recovery and cancel/barge-in. Keep low-risk native work out
of general reasoning. Reuse Codex delegation and honest session limits.
Route an obvious generation/planning request directly to Terra; do not
add a pointless failed Jev call. On UI uncertainty, refresh missing evidence
where useful, then use bounded Terra recovery. A permission denial is
not cured by escalating models. No parallel speculative Terra call on each
Jev step, no silent quota-driven switch to another model/billing route.
Terra accepts images/text, not audio or Realtime sessions.

**Check:** `scripts/verification-lane.sh p5` plus normal-product controlled
cases → each available capability reaches its executor and independently
observed result; low confidence escalates under the same turn; cancellation
cannot cause late input. No private test entrypoint labeled as voice.

**Evidence:** `.agent/results/P5/integration.json` with request/turn IDs,
route, actual outcome, cancellation/refusal cases and observation lineage.

### M3 — matched routing-policy and live qualification

**Change:** implement the frozen manifest and entrypoint mapping in the
existing benchmark. CONTRACTS §7 permits only mcp_stdio today; review any
required normal-product injector before adding it. Run SHIP-PLAN's bounded
routing-policy comparison under the scoped request/dollar run contract.
Compare Jev-only with Jev plus Terra recovery; Terra-only is an optional
diagnostic reference on the uncertain subset, not a replacement search.

**Check:** use SHIP-PLAN's desktop-lock benchmark command with tag `p5`
and the frozen signed binary. `scripts/verification-lane.sh all` passes
at the candidate boundary. Independent judge inspects full task rows and
red-team evidence, not command exit status.

**Evidence:** `.agent/results/P5/qualification.json`, routing-comparison
report and artifact manifest. Complex slice >=80%/p50 <=60s with the
PROGRAM Wilson rule; zero safety/false-Done/duplicate violations.
Report S-VISUAL/S-WORKFLOW gaps, p95, counts, cost and combined resources,
plus escalation cause/rate, recovery success and unnecessary escalations.
No added model calls or latency regression on the direct path.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P5-1 | M1 | SDK reuse and typed adapter |
| P5-2 | M1/M2 | authority, consent, cancellation, independent outcomes |
| P5-3 | M2 | public screen/lookup/escalation routes |
| P5-4 | M2 | effort, progress, recording and existing delegation |
| P5-5 | M3 | bounded Jev-only/hybrid comparison and recovery decision |
| P5-6 | M3 | complex slice, red-team and resources |
| P5-7 | M3 | independent review and handoff |

## Gates

Source/run G1/G2 pending; the Terra API provider choice is authorized by
the user. Calls follow the scoped run and existing spend policy. G3 uses the single
lane. G4 is an authorized independent reviewer. G5 requires a frozen
subject, nonempty declared population and independent oracles. G6 shares
the final normal task/cancel/safety-check session where applicable.
G7 records scoped changes and commit/install proposals; no automatic push.

## Progress

- [x] Draft plan and default-fail criteria prepared.
- [ ] M1 adapter/contract.
- [ ] M2 normal-product integration.
- [ ] M3 qualification and handoff.

## Surprises & Discoveries

The existing integrated general decider is missing; Codex delegation is
not evidence that this seam is implemented. SDK support for a model does
not establish support for every computer-use/safety/transport event.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-17 | Accept only the P3 host's isolated, non-executing Close/Minimize answer ticket | It cannot enter Jev/Terra routing, the shared tool catalog, generic context or any executor. No new provider or model. |
| 2026-11-15 | SDK-first adapter; model comparison remains a bounded proposal | Reuse infrastructure and compare fairly without changing pricing/policy silently |
| 2026-11-15 | User retained Jev and approved Terra API fallback; planned RecoveryDecider supersedes the Sol-specific name | Compare the value of recovery rather than running a replacement-model tournament |

## Outcomes & Retrospective

No implementation or phase acceptance claimed. All seven criteria start
false; update only from independent evidence.

## Handoff

Next: obtain G1/G2, inspect the exact SDK event surface and P4 handoff,
then implement M1. Keep the old configured path and signed app available.
If comparison/transport cannot satisfy the authority contract, retain the
incumbent and record the specific gap rather than weakening verification.
