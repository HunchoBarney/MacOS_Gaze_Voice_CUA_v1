# Exact Window Owner Repair

Purpose: an explicit existing window must select its owning process of
the requested app, not falsely report closed because another instance
appears first. No other window may be substituted.

Reproduction: signed5ac before coordinate driver, existing synthetic
PID29033/WID48895, app=com.apple.TextEdit, owned-pilot-20261110 results.
Blocked177.631875ms before Jev, while independent native oracle proves
the unchanged baseline41 bytes in the exact window. AppResolver.resolve
takes the first of multiple same-bundle processes; run and preview then
look only under that PID. This is not a chooser/completion test result.

Owned source: Sources/JevVoice/Drive/DriveLoop.swift and
Tests/JevVoiceAppTests/DriveLoopTests.swift only, plus phase evidence.
No AppResolver API/first-match semantics change, public MCP schema,
model/provider/threshold change, app flags, new permission or install.

## Binding Algorithm Before Any Action

Replace/wrap run's initial async resolver with one PRIVATE detailed
target helper, before either fast-lane dispatch or normal PID binding.
Use the SAME helper in preview before its pinned validation.

Get resolveDetailed. Preserve its existing app for normal/single-process
cases and explicit task.pid (never rebind explicit PID). Only when PID
is absent, windowID is supplied and the already selected exact bundle
has multiple DISTINCT positive candidate PIDs, inspect every candidate.
Do not rely on sorting/first-match order. Read scoped list_windows(pid)
through observe/listedWindowRows. No launch, activation, input or model.
For each candidate, consider only rows for the pinned ID:
zero means not owner; exactly ONE row with pid==candidate proves that
candidate; a missing/foreign pid or duplicate rows refuses immediately.
Require exactly ONE owner candidate overall, else refuse. No fallback
to the first process, a sibling window or another bundle. Cancellation
checked around reads. The selected app keeps its actual bundle/name.

In run's PRE-BIND fast-lane block, use var FastResolution. A pinned
app-scoped result with the SAME resolved bundle gets
fast.pid=task.pid ?? bound.pid. A different nonempty app bundle refuses
rather than substituting. Preserve existing app-free media/system/gaze
policy handling; do not accidentally disable explicit global voice
commands just because voice captured a window. Main bind uses this
detailed result before pid=resolved.pid. Preview uses it before its
list_windows/get_window_state. Later window/context checks remain.

## Tests And Gates

Test first against real DriveLoop with a custom AppResolver containing
old-first same-bundle positive PIDs, driver responses keyed by PID, and
stubbed unpaid driver/chooser seams. Existing single-PID helper cannot
reproduce this. Cover run, preview and fast app-scoped owner; foreign
bundle, missing pin, duplicate/ambiguous claims and unknown-owner rows;
explicit PID remains authoritative; no model/input/launch on refusal.
Positive tests assert exact selected PID/WID and no wrong-owner state.

G2 bounded plan review, focused G3 guard through serialized lane (respect
space guard), source/component G4, fresh signed candidate from frozen
sources, ONE affected owned pilot then three matched A/B repetitions.
5ac-before and new-before use same chooser and coordinate driver:
that A/B isolates this binding change. Original a1c chooser failure
stays separate; do not call two-source deltas an isolated chooser A/B.
Keep all failed pilot evidence and explicit fixture lifecycle.

Disk guard unchanged; no new build below its floor, no arbitrary cleanup.
Daily app untouched. Existing restored TextEdit48894 retained and its
process never terminated; own synthetic48895 only. P4 FAIL/open.

Plan review5e375408 returned FAIL, listing necessary wiring details.
This written contract makes each placement and exact-row requirement
explicit. The suggested unconditional fast-bundle mismatch refusal is
narrowed to NONEMPTY app bundles to preserve existing app-free commands.
No app-source code changed pending accepted G2.

## Implementation Evidence

G2 follow-up5e375408 PLAN PASS before app code. Ten new boundary tests
written first. Initial guarded before run:278 tests,21 failed assertions,
all in new tests; the existing268 stay green. This includes genuine
wrong-PID run/preview/fast-path failures and ambiguous-owner exposure.
Two test-fixture errors are distinguished: ordinary list_apps metadata
is permitted before binding, and spoken app qualifiers do not accept
dots in a bundle ID. Fixed fixture expectations/name before accepting
the after result, without relaxing owner/model/input assertions.
After:278 tests, zero failures, verification lane green.

Run starts resolveDetailed asynchronously, retaining the full candidate
set. The shared helper is applied before app-scoped fast dispatch and
before normal PID binding; preview uses it too. Resolving is deliberately
lazy for app-free fast commands: their existing policy runs without
window inventory. The app-free regression asserts zero driver reads.
Explicit preview PID uses the caller's PID, as normal execution does.
No AppResolver or public interface changed.

Evidence: native workspace staging/
vision-pinned-owner-20261110.artifacts/pinned-owner-{before-retry,after}.log.
Signed pilot and matched A/B remain unproven. P4 stays FAIL/open.
