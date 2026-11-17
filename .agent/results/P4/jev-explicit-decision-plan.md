# P4 D16 — Explicit candidate decisions ExecPlan

> Status: contracted
> Track: agent+voice · Parent: `.agent/phases/P4-taskloop-jevdecider.md`
> Acceptance: `.agent/acceptance/P4.json`
> Contracts touched: private chooser judgments and optional observation context

## Purpose

Make each action's evidence concern that exact action, and keep the same
proposal when requesting visual grounding. Batch judgments whose evidence
already exists so correct selection and completion need fewer serial requests.
This is a correctness change with a performance hypothesis, not a speed claim.

## Context

The user approved the recommended first decision-flow change on 2026-11-12:
"ok do what you gotta do just fix the mistakes and overall make it more correct
make sure you follow the research". This follows the recommendation to implement
item 1, then perform a clean isolated signed-app comparison. It does not authorize
installation, changed model/pricing policy, relaxed gates or the separate
observation/driver optimizations.

Read `.agent/PROGRAM.md`, `.agent/PLANS.md`, `.agent/CONTRACTS.md`,
`.agent/results/P4/jev-decision-architecture-diagnosis.md` and
`.agent/results/P4/jev-decision-speed-research.md`.

Current problems:

- `Sources/JevVoice/Drive/JevChooser.swift:118-122` removes candidate details
  before primary inference; the full map returns only during refinement.
- Primary applicability says whether any offered action fits. The selected
  action can enter the fast path without its own support judgment. Existing
  refinement does ask candidate-specific support, but only conditionally and
  in another request over the same evidence.
- Primary goal selection is followed by a separate support request even
  though every possible fact is already present.
- `Sources/JevVoice/Drive/JevDecider.swift:249-286` turns semantic uncertainty
  into visual recovery without carrying the candidate being considered.
- `Sources/JevVoice/Drive/JevVisualDecision.swift` initially asks operation,
  presence and box to independently infer "next". Its second stage already
  binds an explicit proposal and native identity; reuse that stage.

These are source-level defects to reproduce. Existing model captures do not
prove that correcting them will make the .86 candidate-support refusal pass.
P4 remains 4/6 until independent qualification says otherwise.

## Owned paths

Production edits are limited to:

```text
Sources/JevVoice/Drive/JevChooser.swift
Sources/JevVoice/Drive/JevDecider.swift
Sources/JevVoice/Drive/JevVisualDecision.swift
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Drive/DriveLoop.swift
```

Existing test/verification homes and evidence:

```text
Tests/JevVoiceAppTests/JevChooserTests.swift
Tests/JevVoiceAppTests/JevDeciderTests.swift
Tests/JevVoiceAppTests/JevVisionTests.swift
Tests/JevVoiceAppTests/JevAdaptiveTests.swift
Tests/JevVoiceAppTests/JevObservedGoalTests.swift
Tests/JevVoiceAppTests/JevExactReplacementTests.swift
Tests/JevVoiceAppTests/JevNativeChoiceDiagnosticTests.swift
scripts/verification-lane.sh
.agent/results/P4/**
.agent/PROGRESS.md
.agent/phases/P4-taskloop-jevdecider.md
.agent/CONTRACTS.md
```

The inherited dirty tree belongs to the user. Freeze before hashes and copies
of edited files; compare the D16 delta against those copies, not the old Git
commit. All listed paths are already within the parent P4 ownership list.

## Non-goals

No native-read, driver, pacing, ASR, app-recipe, installed-app, dependency,
public MCP or executor change. No extra serial planner per action. No numerical
threshold reduction, artificial round cap or alternative route to Done.
No resumption of the old D15 preview. Preserve all historical evidence.

## Milestones

### M1 — Reproduce composition failures

Before production edits, extend existing tests using the production chooser,
decider and visual factory with inference simulated at their existing seam.
Reproduce these three failure families:

1. A strong global applicability answer can accompany a selected candidate
   whose own support is low, while another candidate has high support.
2. A visual fallback can change the native proposal's operation; an unbound
   presence answer can block a subsequently well-grounded target.
3. Goal-fact support needs another request despite all candidate facts being
   available, and selected-fact support must never be borrowed from another.

Also specify negative cases before implementation: malformed selected support,
model mismatch/cancellation, raw selection below its existing floor, changed
task/window, stale proposal, wrong literal/key, missing target, wrong subject,
partial native evidence and failed fresh verification.

### M2 — One candidate registry and explicit answer composition

In `JevChooser`, expose code-owned candidate details in the primary state.
Ask one support Noul per concrete action in the same primary request as the
step Choice. Each question names its actual record in state; question IDs
alone do not supply meaning. Preserve literal operation distinctions,
unfinished-work semantics, no-repeat rules and exact user constraints.

Consume only the chosen candidate's finite support >=.90, the existing raw
Choice floor and existing applicability gate. Never substitute another
candidate's score or fabricate a distribution. Replace the redundant
same-evidence action refinement with these batched judgments. Preserve an
explicit selected proposal ID and fixed rejection category for recovery.
Update privacy-safe diagnostics to describe the new stage honestly.

Batch per-fact whole-goal support with primary goal selection. Keep completion
>=.95, fact selection >=.90, selected fact support >=.90 and all existing
native/freshness checks. Retain the existing focused goal-recovery path and
its actual dependent supported-fact selection. Exact-replacement and derived
readonly proof consumers keep their current gates and authority.

### M3 — Carry a proposal into visual grounding

Add optional private proposal context to `TaskObservation`, default nil.
Create it from an actual code-owned candidate, bound to the task/window and
source step. It is a hypothesis, not action authority. Do not carry an old
AX token into a new snapshot or accept caller-supplied proposal metadata.

When a concrete candidate needs visual evidence, carry its semantic identity,
operation and authorized argument expectations into the existing visual
request. Reject an incompatible operation, literal or key in code. A
set_value replacement must never become type_text insertion. Reacquire fresh
target references through the existing grounding machinery.

Validate/reset proposal context on task changes, intervening actuation and
terminal results. An invalid model response follows invalid-choice recovery,
not an unrelated visual plan. Empty/inadequate AX can still use the general
visual route; do not restrict image capability to native-listed targets.

Move authoritative visual target presence to the existing bound grounding
request, separately for each pixel/native proposal. Keep its >=.95 gate.
Presence, location, authorization, protection, editability and consequence
remain distinct; consume the same native candidate's complete answer set.
Do not fall back to pixel permission after native permission fails. The
first-stage Box remains a proposal and can never establish presence.

Keep the existing maximum two pre-action visual requests; no third planner
request. Previously early-rejected unbound presence can now reach the bound
check, so rejection-path request counts are intentionally not wire-identical.
Uncertain or malformed unused branches do not authorize a selected branch.

### M4 — Focused verification, source review and isolated proof

Add D16-specific lane entries and update existing filters when an affected
test is renamed, so historical lane commands cannot silently select zero tests.
Commands:

- `scripts/verification-lane.sh p4-explicit-decision-regressions`
  → new counterexamples fail before, pass after; no model or desktop access.
- `scripts/verification-lane.sh p4-explicit-decision-consumers`
  → affected chooser, decider, visual/native proof, TaskLoop, DriveLoop and
  voice/control/preview consumers pass, with skips stated.
- `python3 scripts/check-owned-paths.py P4`
  → staged scope checked; separately compare all changed D16 paths against
  the frozen baseline because unrelated unstaged work is present.

Use the existing build guard and serialized lane. Bound each test invocation;
do not repeat unrelated historical lanes. Retain before/after output and
request counts. No shipping test injection or new test-framework scaffold.

After fresh source PASS, stage isolated signed before/after apps with identical
driver/runtime resources. The current pre-D16 source includes trace-only D15;
freeze it so the comparison cannot silently attribute that delta to D16.
Reconcile staging admissions against those actual hashes, without changing old
receipts or silently reusing an invalid baseline.

Use the existing owned synthetic fixture and signed-app harness: one candidate
pilot, then one clean matched comparison only if the pilot verifies. Keep
the original identity/readiness guards, goal deadline, independent oracle,
failure records and cleanup. A readiness failure stops the run; do not raise
limits or retry until green. No unrelated everyday-app sweep is included.

## Acceptance mapping

- P4-2/P4-3: revised private decision contract preserves loop-owned execution,
  cancellation, consent, literal authority and fresh outcome proof.
- P4-5: independent signed results must meet the unchanged >=95% success,
  p50 <=4 s and zero-false-Done bar. This small comparison alone cannot
  establish release reliability or physical Fn/pill behavior.
- P4-6: fresh judge evaluates the real delta and evidence. Only that verdict
  can change acceptance; tests alone cannot complete P4.

## Gates

- G1: user go-ahead for the recommended first refactor recorded above.
- G2: independent judge 511e9c51 returned PLAN_VERDICT PASS and
  CONTRACT_VERDICT ACCEPT before tests/code. Its implementation risks are
  retaining focused goal recovery, invalidating proposal context and proving
  the old unbound-presence rejection. No material plan findings remain.
- G3/G4: pending fail-first checks, implementation and fresh source review.
- G5: conditional isolated proof as described; no result yet.
- G6: physical UX qualification remains unproven; no daily install.
- G7: truthful handoff; no commit/push without the user's authorization.

## Progress

- [x] G2 contract accepted.
- [x] M1 counterexamples reproduced.
- [x] M2/M3 implemented with unchanged hard gates.
- [x] M4 affected checks and fresh source review pass.
- [ ] Isolated signed evidence recorded with its actual verdict.

## Surprises & Discoveries

The primary chooser deletes the detailed candidate map rather than supplying
it to its first decision. This is a separate concrete information-loss finding
from the earlier independent-question diagnosis.

## Decision Log

2026-11-12: user go-ahead starts the researched decision-contract amendment.
Observation and driver performance work stay separate. D15's old canonical
request-equivalence evidence remains historical; D16 intentionally changes
judgment composition and must not claim those requests are unchanged.

## Outcomes & Retrospective

M1 reproduced on the frozen production source: six initial regressions fail
(17 assertions), then nine including argument/staleness cases fail (29 assertions).
M2/M3 now implement candidate-specific support and same-request goal support,
remove the redundant action re-questioning, and carry a private proposal into
the existing visual grounding stage. Focused goal recovery remains.

The proposal includes the known native document subject and exact literal/key;
it contains no AX token. It survives only the next recorded non-actuating
reobserve. A weak selection with adequate native evidence stays in semantic
recovery. No candidate coverage (global applicability below .3 and every
candidate support below .9) may request general pixels even if AX reports a
complete tree: completeness does not imply that a custom-drawn target exists
in that tree. No candidate is authorized by this routing.

Source inspection found two additional boundary cases and extended the
existing regressions before fixing them: a completion receipt could return an
action before its support was checked; a native document could change within
the same window during image recovery. The intermediate failing capture is
`jev-explicit-decision-boundary-before-r2.log`. Completion proposals now return
reobserve until a consumer admits their proof; only validated action composition
can return an action ID.

G3: nine regressions pass in `jev-explicit-decision-after-r2.log`.
All346 affected consumer checks pass, zero skips/failures, in
`jev-explicit-decision-consumers-r2.log`. Existing fixtures were adapted to the
new batched response shape and request counts; numeric and native proof checks
remain. Eight canonical request/outcome/count traces are retained in that log.
D16 changes question composition; no D15 request-equivalence claim is made.

The frozen source receipt and generated delta are
`jev-explicit-decision-source.json` and `jev-explicit-decision-delta.patch`.
Five production files differ out of103 source entries; zero other production
files differ from the D16 baseline. Twelve of13 frozen owned files changed.
The staged-only ownership check reports zero staged files; the hash comparison
supplies the actual unstaged source-scope evidence.

G4 fresh reviewer `de8b6c5e` returns SOURCE PASS / PHASE FAIL with no material
D16 source findings. Receipt: `jev-explicit-decision-source-review.md`.
Both isolated D16 driver variants now build, sign and retain frozen nested
payloads. The one approved synthetic pilot runs through the signed daemon:
blocked in2428.328167ms, target/other activations0/0, false Done0. Presence .97
passes; location .89 and authorization .92 fail their unchanged .95 gates.
Resources close cleanly. This is a product refusal, not a setup failure.

The conditional comparison is stopped at the failed-pilot gate. No before
source build, speed gain, model reliability gain or P4 acceptance is claimed.
Results: `jev-explicit-decision-results.md` and its self-contained HTML report.
All346 consumer checks and the source review remain valid; source hashes match
the signed candidate after execution. No install, commit/push, or process remains.

## Handoff

Worktree: `jarvis-v1-agent`, inherited `ship/v1-p3` branch with existing
uncommitted work. Preserve it. Parent P4 remains open. This plan is the exact
D16 delta boundary; the research documents provide rationale, not extra scope.
