# R7 conversation amendment

G2 PASS42753e08 (twelve criteria met), approved before amendment production edits.
Supplement to c1-r7-native-scroll-contract.md. Core R7 is
implemented and compiles: c1-r7-core-focused.json/log,12checks,1opt-in skip,
zero failures. Production ownership remains the same seven files; checks remain
in the four existing files. No thresholds, models, public DTOs, audio/VAD/ASR,
dependencies, settings, permission/grant rules or native-proof timing changes.

Consumer-fixture ownership correction: DriveSessionCursorTests.swift also needs
its two existing label tests to supply the unique owned pid/window inventory
now required by R7. These tests still require unverified completion without
native viewport proof; their dispatch/session assertions remain unchanged.
The old missing-anchor semantic fixture explicitly sets ongoing duration.
The first full consumer run executed518tests/3skips and found only these three
outdated fixtures (five assertions). No production relaxation is justified.

## Evidence and reassessment

The production conversation factory before R7 was exercised through14real Jev
requests, no actions/microphone. Exact requests/responses:
c1-r7-semantic-before/. Actual model1.14.0. All six initially labelled positives
refused; five are unambiguous scroll requests. "Could you nudge this down a bit?"
without a prior referent is ambiguous and must remain honestly labelled so.
Its original positive expectation is preserved in the before evidence.

"Scroll down." selected scroll.99 but addressed/complete were.87, window scope
support.18, normal amount confidence.58, direction support.85. These questions
conflate lexical intent with permission/feasibility and omit actual native
1/3line defaults. Window scope is already captured and freshly checked by code.

Three bounded read-only hypotheses are retained, no unchanged rerolls:

1. c1-r7-semantic-meaning-prototype/,22requests, exact recipe
   c1-r7-semantic-probe.py: explicit semantic meaning and defaults.
2. c1-r7-semantic-meaning-refined/,29requests, recipe
   c1-r7-semantic-refinement.py: separate linguistic completeness from
   capability, hypothetical proof sufficiency, bounded relative movements.
3. c1-r7-semantic-followup-prototype/,36requests, recipe
   c1-r7-semantic-followups.py: separate amount qualification, single/ongoing
   duration and references to a verified native subject.

The third prototype's original five clear positives meet all established
semantic gates; the ambiguous "nudge" still refuses. Small-amount support for
"Move the page a little farther down" improves. The extra reference Choice
creates artificial competition between a current window and the same window's
prior verified scroll. The extra continuous_requested Noul treats an implicit
stopping policy as a required literal phrase. Do not keep tuning these duplicate
questions or select winning answers from different runs.

Reassessed composition: keep only the new scroll_extent Choice and
verified_scroll_reference Noul. Code already knows that ongoing continuation
uses the last verified anchor. Strengthen the existing continue_supported Noul
to cover the WHOLE ongoing instruction, including absence of extra end/region/
count/compound conditions; it remains an independent>=.90 support check.
All other existing semantic gates and>=.90 thresholds stay.

The probes also exposed a duration defect: "A little more" selected
continue_scroll.93 with support.91 in prototype2. The old decoder would start
ongoing repetition, despite a bounded request. This was model-only reproduction,
not an executed desktop action.

Source review found another bypass: a semantic fallback.task still reaches the
legacy text scroll parser. That can ignore the semantic whole-goal refusal or
apply its old counted-scroll cap. A generic conversation task must bypass that
parser while preserving all other existing fast lanes and the full generic goal.

## Concrete implementation

1. Use the final prototype's semantic definitions and native1/3line defaults in
   conversationRequest. Keep kind/scope/complete/addressed/direction/amount/support
   and bounded_window_scroll judgments separate. Remove its two diagnostic-only
   questions continuous_requested and scroll_reference. No new serial inference.
   Define the current-window default only for unqualified window-local requests;
   explicit other targets and unresolved references cannot use it. Model questions
   judge requested scope, never issue OS permission or invent window/process IDs.
2. Keep scroll_extent(single/ongoing/clarify),>=.90 confidence. A small additional
   movement is single; "keep scrolling" is ongoing. A named end condition,
   compound or exact-unit/count instruction stays whole in the generic workflow.
3. For an ongoing result, require the existing complete/addressed gates,
   extent=ongoing and strengthened continue_supported>=.90. Its exact plan is
   repetition of the existing native verified scroll in the same window/document/
   region/direction/amount, with normal user-stop/edge/safety cancellation behavior.
   No new anchor is invented; memory must exist and match current captured scope.
   Extra until-visible/count/region/app/action conditions cannot enter this loop.
4. For a single result, require bounded_window_scroll>=.90, plus existing
   direction/independent-direction-support and amount/independent-small gates.
   verified_scroll_reference>=.90 uses the actual stored native viewport only
   when memory exists and its app/window still matches captured scope. A value
   <=.10 uses the existing fresh scope Choice and scope-request support; values
   between these bounds clarify. A missing anchor cannot satisfy a positive
   reference. Model output never supplies native viewport identity or coordinates.
   Keep source state app/window and conversation facts matched to the decoder
   context; do not turn a stale request into new execution authority.
5. Extend internal WindowScrollRequest with an optional existing native viewport
   anchor, validated to the same window and supported axis. Pass it directly
   through the existing native executor, reusing sameTarget/region/document/
   freshness checks. No new proof kind. Direction reversal is one bounded
   movement in the same native region; changed subjects refuse. Keep existing
   fresh-continuation policy unchanged.
6. Typed "again"/bounded follow-ups keep their current original words. Do not
   rewrite them to an older goal or enter the generic repeat handler; their new
   request was independently interpreted against verified memory. Generic repeat
   retains its existing verified-history rules and never inherits a typed request.
7. Add an internal allowParsedScroll(default true) through coordinator Work and
   DriveLoop.Config. VoiceController sets it false for generic conversation.task
   results. This suppresses only the legacy parsed-scroll fast path, preserving
   other fast lanes and the full generic goal. Typed requests and independently
   authorized ongoing continuation use their explicit routes. No fallback may
   turn weak whole-goal support into one-movement completion.

## Required controls and final evidence

Write the new controls before these edits. Demonstrate existing-surface red
controls for bounded "more" becoming continuous and extra end conditions being
ignored. Add typed/native controls before extending the API:

- single/ongoing disagreement, weak duration or full-continuation support;
- "until visible", compound, exact amount, changed app/window/region, stale
  context and missing/weak native reference cannot enter an infinite/plain loop;
- "a little more" is exactly one native movement; reversal preserves native
  region/document, direction and amount;
- a semantic fallback cannot enter parsed scroll, including counted requests;
- typed "again" retains current text; generic repeat never copies its intent;
- existing permission, deny, cancellation, no uncertain retry and native
  independent consequence controls remain.

Apply the final recipe from source, then run the actual production factory and
decoder against the retained requests and the real provider once. Preserve every
failed result; no packet assembled from different successful rerolls. Correct the
ambiguous nudge expectation explicitly, retaining its original before label.
Test follow-up memory as a controlled semantic fixture and retain current-window
mismatch controls. These do not prove actual voice or an app effect.

Then affected consumers, production build, immutable snapshot, separately signed
final-r7, package controls, fresh G4 and unchanged real TextEdit workload. Native
direction/amount/cancellation and real microphone/speaker/latency remain distinct
gates. This amendment claims no50ms achievement or phase acceptance.
