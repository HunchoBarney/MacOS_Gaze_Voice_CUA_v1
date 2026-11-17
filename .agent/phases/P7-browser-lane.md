# P7 — browser-lane ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: agent+voice · Depends on: P2b, P5 · Branch: `ship/v1-p7`
> Acceptance: `.agent/acceptance/P7.json` · Contracts: §1, §2, §3, §5, §7, §8

## Purpose

Make normal voice browser tasks fast on real logged-in Chrome and Safari
using DOM/native references, with generic visual fallback and verified
results. Avoid rebuilding sessions and reinterpreting screenshots for
routine actions.

## Context

P2b selected DevTools primary and Cua fallback. Read that phase's handoff,
SHIP-PLAN C2, REUSE and CONTRACTS §5. Existing
`Drive/BrowserSupport.swift` and `BrowserActuation.swift` provide primitives;
the complete driver/decider set and browser_task route remain incomplete.
Consume a reviewed P5 interface milestone; do not infer its final PASS.

Latest routing: direct grounded DOM operations, then Jev for semantic
choices, then the approved Terra API recovery adapter when needed.
BrowserDecider is not an automatic general-model call per step.
See COMPETITIVE for category clocks, all-task reliability and paired
completion/latency reporting.

## Reuse decision

Reuse Apache-2.0 Chrome DevTools MCP, the pinned Cua browser API and
Safari's supported Apple Events API. Reuse licensed Browser Use DOM/
session ideas/helpers where compatible. Do not import its arbitrary-code
agent loop or cloud dependency. Keep the existing transport when it can
supply the documented MCP contract. Record tag/notice/API compatibility
and real-profile attachment behavior at G2.

## Owned paths

```text
Sources/JevVoice/Browser/**
Sources/JevVoice/Drive/BrowserDecider.swift
Sources/JevVoice/Drive/BrowserSupport.swift
Sources/JevVoice/Drive/BrowserActuation.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Voice/RealtimeVoiceClient.swift
Sources/JevVoice/Contracts/JevContracts.swift
Sources/JevVoice/Settings/Permissions.swift
Tests/JevVoiceAppTests/BrowserDriverTests.swift
Tests/JevVoiceAppTests/BrowserDeciderTests.swift
Tests/JevVoiceAppTests/BrowserActuationTests.swift
Tests/JevVoiceAppTests/VoiceTaskContractTests.swift
scripts/verification-lane.sh
bench/run.py
bench/lib/mcp_stdio.py
bench/lib/results.py
bench/lib/verifiers.py
bench/selftest.py
bench/tasks/p7-*.json
bench/reset/p7-*
Package.swift
Package.resolved
Makefile
ThirdParty/OPEN_SOURCE_NOTICES.md
.agent/phases/P7-browser-lane.md
.agent/acceptance/P7.json
.agent/results/P7/**
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

## Non-goals

No mandatory alternate browser profile, per-site recipes, model-generated
JavaScript, automatic dialog acceptance, hidden scope expansion or
browser restarts as a normal per-command setup step.

## Milestones

### M1 — persistent drivers and snapshot authority

**Change:** implement ChromeDevToolsDriver, SafariAppleEventsDriver and
CuaBrowserDriver behind §5. Add a bundled fixed `DOMSnapshot.js`, accurate
visibility/completeness, scoped node references, navigation/extract and
condition-based settle. Package resources through the existing build.
Keep one browser-level connection and bound tab/origin/navigation state;
invalidate references after changes and reconnect with a new generation.

**Check:** add and run `scripts/verification-lane.sh p7` → nonempty
driver/decider/actuation suites pass; wrong tab/origin, off-screen rows,
stale refs, detached nodes, unknown dialogs, injected page instructions
and disconnects do not authorize unintended input.

**Evidence:** `.agent/results/P7/contract-review.md`, `source-review.md`
and connection/reference lifecycle cases.

### M2 — normal browser tasks and visual fallback

**Change:** connect browser_task through the real coordinator; choose
DOM/native operations first, return fresh action state and use read-only
extract for content. A failed DOM binding escalates to P5 pixels under
the same user/task authority. Preserve general screenshot coverage,
independent outcomes and cancellation. An AX/DOM row is not rendered
evidence. Guard deterministic sequences at each changed state.

**Check:** `scripts/verification-lane.sh p7` plus controlled Chrome and
Safari cases → navigation, input, keys, scrolling and extraction work
through the public route; reflows/cancel/reconnect do not duplicate an
action. Verify the currently loaded page rather than a queued navigation.

**Evidence:** `.agent/results/P7/integration.json`, connection count,
actual consent prompts, route selection and independent DOM/native oracle.

### M3 — matched browser qualification

**Change:** freeze tagged tasks, any necessary reviewed bench injector,
signed candidate and reference pixel route. Use SHIP-PLAN's desktop-lock
command with tag `p7`. Include real logged-in profile behavior without
reading unrelated tabs/accounts; controlled tasks use owned tabs.

**Check:** >=90% strict success, p50 <=15s, >=2x faster than the matched
Sol-pixel path; >=5 repetitions on hero tasks and PROGRAM Wilson bar.
The Sol path is a historical benchmark reference, not the production
fallback. Compare the configured Terra-pixel path as well to isolate
DOM savings; if the old reference is no longer applicable, record and
review a versioned baseline amendment before qualification.
Separate loaded-page action goals S-NATIVE/S-VISUAL from navigation/network
completion totals. No false Done, unsafe dialog acknowledgment or repeat
mutation. Required integrated lane passes.

**Evidence:** `.agent/results/P7/qualification.json`, matched raw rows,
p50/p95, requests/bytes/connection counts and source/runtime manifest.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P7-1 | M1 | three drivers, persistent session and reuse |
| P7-2 | M1 | snapshot/ref/visibility/consent boundaries |
| P7-3 | M2 | public route, extraction, settle and pixel fallback |
| P7-4 | M2 | cancel/navigation/reconnect result correctness |
| P7-5 | M3 | strict browser bar and pixel comparison |
| P7-6 | M3 | independent review and handoff |

## Gates

G1/G2 pending; no browser installation/profile mutation or paid run is
authorized here. G3 uses the single lane. G5 owns one desktop lock and a
declared profile/tab set. G6 checks real-profile setup once and a normal
browser task in the final product session. Chrome's actual consent may be
once per browser launch; do not promise OS behavior beyond what is proven.

## Progress

- [x] Draft and default-fail criteria prepared.
- [ ] M1 drivers.
- [ ] M2 integration.
- [ ] M3 qualification.

## Surprises & Discoveries

The current runtime's small browser helpers do not prove a persistent
production browser lane. Modern Browser Use documentation includes cloud
and arbitrary-code behavior that must not be copied into Jev's authority.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Consume P2b, persistent DOM first, generic pixels retained | Reduce round trips while preserving arbitrary-surface capability |

## Outcomes & Retrospective

No driver promotion, capability switch or new live result. Six criteria
remain false until independent evidence is available.

## Handoff

Next: verify current DevTools API against P2b and the P5/P4 contracts.
On failure preserve existing Cua/native fallback before mutation; an
uncertain browser mutation is verified or handed back, never replayed
blindly. Close only owned sessions/tabs.
