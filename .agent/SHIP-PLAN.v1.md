# Historical snapshot · pre-v2 delivery plan

Read the [active C1–C3 roadmap](SHIP-PLAN.md) for current direction. The
text below is the pre-v2 working copy, not a current runbook, candidate
selection, permission or status record. In particular, do not run its
example benchmark command; use the approved corpus tag and current harness.

# Jev Voice v1 shipping plan

Updated 2026-11-15 after the whole-program review and the user's requests
for substantially faster interaction, faster delivery, and open-source-first
implementation.

Latest direction: keep Jev as the primary semantic decision model,
Cua/native execution, and GPT-6.1 Terra through the explicitly authorized
API when needed. Pursue Wispr Flow dictation quality and leadership in
every shipped category. `.agent/COMPETITIVE.md` defines the comparisons;
the follow-up audit is
`results/P4/jev-first-competitive-audit-20261115.md`.

Voice-provider update, C1 R10: the user chose OpenAI Realtime after
local-model startup and empty-final failures. The [reviewed contract](results/P4/c1-r10-realtime-contract.md)
is implemented in the normal voice path: Realtime input/output and server
turn detection, with direct native controls, Jev/Cua unfamiliar work and
the existing admission, target and outcome gates. Local ASR/VAD/TTS are
explicit diagnostics, not startup requirements. The signed candidate
passed G4; G5/G6 and C1 acceptance remain open.

## Authority and current state

The user authorized updating the plans and documentation. This document
organizes implementation; it is not evidence of implementation approval,
an independent G2/G4 verdict, an unlimited experiment budget, or permission to
replace the installed application. Follow G1–G7 for phases and release;
use [PLANS §3](PLANS.md#3-choose-the-proof-before-starting) for bounded bug proof.
Routine work inside an approved milestone continues without new approval
for each edit. Material contract, provider, permission or scope changes
return to the decision that owns them.
The user's later Terra API approval establishes that fallback route;
do not ask for that provider choice again. Implementation and benchmark
execution still follow their scoped phase/run contracts.

`.agent/PROGRAM.md` owns release requirements and the speed-goal table.
`.agent/PLANS.md` owns execution rules. `.agent/CONTRACTS.md` owns frozen
interfaces. `.agent/REUSE.md` records reuse decisions and primary sources.
The phase plans below own implementation and acceptance mappings.

The factual baseline is
`.agent/results/P4/jev-program-review-20261115.md`. Its historical findings
remain evidence, not promises: P0 13/13, P1 11/11, P2a–P2d 8/8 each,
P3 0/8 and P4 4/6. P5–P13 now have draft plans and default-fail criteria;
creating those documents does not mean those capabilities shipped.

The primary application checkout is `jarvis-v1-agent` on `main` and
contains the landed C1 source and tracked evidence. The old P3 closeout
and vision-driver worktrees were removed; paths to them in historical
receipts aren't setup instructions. See the [checkout setup](../README.md#start-developing)
for private replay inputs and the optional experimental driver lanes.
Preserve recordings, receipts and signed rollback artifacts.

## Product outcome

Ship the original four hero jobs: inbox/messages by voice; tasks in the
user's logged-in Chrome and Safari; look-and-command with a voice-only
alternative; calendar/reminders/notes. Target macOS 26 and M1/8GB.
Installation should be install, finish permissions and speech readiness, then
speak. The user's 2026-11-16 direction makes continuous conversation the default;
Fn remains an optional override. Explicit off/pause choices persist.
No per-app enablement, manual recipes, browser restart rituals or developer
toolchain should be necessary for normal product use.

The source foundation stays: one transcript of record, one turn authority,
one TaskLoop, pinned driver, native/DOM input and independent outcomes.
Use the cheapest capable route: direct native operation, typed script,
validated replay, DOM/AX decision, then general visual reasoning.
Default Realtime readiness requires its confirmed connection and healthy
native audio. Explicit local diagnostics remain independent of cloud
readiness; they are not an automatic runtime fallback.

## Delivery order

Three candidate boundaries replace the long chain of tiny signed
experiments. They organize P0–P13; they do not replace phase acceptance.

| Candidate | User-visible result | Phase work | Exit evidence |
|---|---|---|---|
| C1: fast ordinary use | Continuous listening, fast dictation, app focus, keys, scrolling and grounded controls, with optional Fn | P3 remainder; P4 proof/observation work; P11 early dwell default; P12 manifest/staging preparation | Same-method before/after ledger, current source review, exact owned-target outcomes, one coherent signed candidate and real hands-free proof |
| C2: complete task routes | General recovery, Chrome/Safari tasks, hero actions and repeat work | P5 → P7, then P6 → P9; P6 can advance once its P3 interface is ready | Each public capability reaches its real executor; independent results and category budgets |
| C3: release candidate | Production eyes, complete onboarding, portable signed app | P8/P11 integration; P10/P12 completion; P13 plus remaining P3/P4 qualification | Clean-user install, physical Fn/pill/gaze, resources, matched competition, all acceptance and final ship decision |

Within approved phase work P8 can advance after P2a on a disjoint change
set under PLANS §5. P12 dependency/license/staging checks begin in C1
so packaging defects surface early; full P12 acceptance still waits for
integrated product dependencies. Sequence changes that share an interface,
file or verification resource through the integration owner.

The DAG distinguishes **implementation readiness** from **phase
acceptance**. A downstream implementation may consume an upstream
interface after its contract and relevant source delta are independently
reviewed and its affected checks pass. Record that handoff by source hash,
interface version, remaining failures and consumer list. An open G5/G6
does not disappear; downstream and release acceptance still depend on it.
No failing task may be moved to a different slice to improve a score.

## C1: R10 qualification

The following checklist and receipts describe **R10**. They do not select
the next app to launch. The later first-minute candidate's Desktop 2 test
did not establish a switch; product work is paused. Use the owning issue's
current candidate/action record (PLANS §5) before any authorized retest.
Do not rewrite earlier qualification results or treat this plan as permission
to launch either candidate.

Current status, 2026-11-17: R10 is landed on `main`; the independent
[source and signed artifact review](results/P4/c1-r10-g4-artifact-review.md)
passed. Use the [R10 physical checklist](results/P4/c1-r10-physical-check.md)
and confirm actual listening readiness before timing speech. The physical
hands-free and Fn/pill checks, blocked MCP scroll evidence, latency/quality
goals and stated comparison gaps still keep G5/G6 and C1 acceptance open.
The [c292 report](results/P4/c1-report.html) is historical evidence, not an
R10 baseline or a launch location.

### 1. Bind one candidate and its rollback

The R10 receipt binds current source, runtime, resources and signed bytes.
R10 uses the canonical Cua 0.38 pin; the 0.45.4 driver and SDK are separate
experiments. The original daily app was absent at staging and wasn't
restored; verified R9-2 is the recorded fallback. The private R10 archive
can stay inside the checkout, but verify its unpacked app outside synced
Documents without re-signing. A docs or setup change doesn't require
rebuilding unchanged binaries. Preserve the reviewed artifact and fallback
until a replacement is explicitly approved.

The initial audit found missing P3 harness assets in the sibling closeout
worktree. C1 bound the required imports and their provenance in
`results/P4/c1-harness-imports.json`. Reuse those reviewed assets. A named
lane is not automatically runnable in another checkout; preserve hashes
and inherited changes when carrying the harness forward.

### 2. Restore independent evidence requirements

P4 owns the D120/D121 review. `kind_supported` must not erase an
independently established exact/hidden-state requirement. Scroll operation
selection must not stand in for authorization unless caller intent,
direction, region and scope are actually proven equivalent.

Represent observed facts, model judgments and code proofs distinctly.
Keep presence, identity, location, authorization, target safety and
consequence verification separate. Batch independent questions over the
same observation; preserve independent meanings. Do not synthesize raw
model scores, lower thresholds or resample unchanged questions until they
pass. Existing legitimate native geometry and continuity proofs remain
subject to current identity, provenance and freshness checks.

First counterexamples: hidden persistence with a visible success message;
an exact requirement with a non-exact proof; a high scroll-operation score
on the wrong panel/direction; and a changed account/document behind an
apparently identical view. Add meaningful guards in the existing suites.
P11-M0 corrects fresh-profile dwell to off and reviews preference migration
before a new daily candidate is offered.

### 3. Attribute time, then remove the demonstrated work

Extend `Sources/JevVoice/Support/LatencyLedger.swift`; do not create a
second timing framework. Correlate Fn release, audio drain, ASR final,
admission, app/window lookup, queueing, driver state, native AX, capture,
encoding, each model call, dispatch, settle, verification and completion.
Record counts, bytes, cache hits, process resources and overlapping spans.
Keep diagnostic profiles separate from the normal timed run.

D121's 22.412–24.167s command time contains 15–16 visual calls and
6.982–8.458s logged visual inference. The remaining 14.271–15.709s is
unattributed, not established driver overhead. Explain it before assigning
blame or claiming savings. Preserve the historical raw rows.

Start with three ordinary operations on controlled targets: focus a
running app, dictate into an owned focused field, scroll the current
owned window. Use the existing harness/recordings. Expand only for the
changed mechanism or a required gate, not another Safari tuning campaign.

### 4. Qualify the speech-to-insertion path

R10 admits the final transcript for the matching committed Realtime input.
Server turn detection handles hands-free speech; Fn uses a manual commit on
the same transport. Keep partial feedback distinct from final admission
and count exactly one insertion/action. Measure audio drain, final arrival,
admission and verified insertion on the current path, including final
words and exact content. Don't count a preview as completed dictation.

Preserve exact literal/Unicode/selection behavior and captured focused
field/window identity. Use direct AX insertion where supported and fresh
readback of the effect. Fallback is legal only after definitive unsupported
status before mutation; an uncertain mutation cannot be retried blindly.
Keep slow CoreGraphics inventory independent of foreground monitoring;
window-list row order is not focused-window identity.

Preserve the historical local-ASR 34/35 signed versus 35/35 unsigned
availability and typing regression evidence. The local replay suite
still exercises that diagnostic path; it does not qualify Realtime
startup, speech or latency. Confirm a healthy microphone and a
connected Realtime session, not simply a process or a health file.

Use COMPETITIVE's 24-clip Jev/Wispr pilot, then its separate held-out
qualification after fixes stabilize. Measure names/numbers/code/negation/
tail, exact insertion, raw WER and necessary editing. Test permitted
personalization separately; do not rewrite literal output or silently
amend the current ASR/admission contract. Realtime final transcription
and direct insertion are the ordinary dictation path, with no default
Jev/Terra cleanup call.

### 5. Verify a coherent candidate

Use focused serialized checks, then the required full lane and source
review at the candidate boundary. Do not call the old default settle
delay a new fix: DriveLoop already disables redundant settle reobserves,
and eligible native dispatch already uses D14's session pacing/wait mode.
Revalidate an optimization only when the measured path actually pays it.

C1 records actual achievement against PROGRAM's new speed goals. It is
not P3/P4 or v1 acceptance. Stage the artifact separately and prepare
installation evidence before requesting replacement of the daily app.

## C2: finish the missing executors

### P5: Terra recovery behind the Jev-first path

Use a maintained Swift Responses SDK when it satisfies the contract;
the shortlist and gaps are in REUSE.md. `OpenAIResponsesClient` is a
product adapter, not a reason to recreate an SDK. `RecoveryDecider`
(previously planned as `SolDecider`) uses the approved `gpt-6.1-terra`
API and shared observation/action/verification contracts. Connect Jev
escalation under the existing task and turn authority. Cua/native tools
execute; neither model gets an independent input loop.

Use documented persistent transport, stable prompt prefixes and scoped
state. Serialize mutations; independent safe reads can overlap. A batch
has explicit step preconditions and stops on changed state. A model
cannot create an authoritative goal, input permit, coordinate or safety
approval merely by returning JSON. Unknown safety events fail closed.
`pending_safety_checks` require the user's actual decision.

Complete `ask_about_screen` and `web_lookup`, with source-grounded answers,
and preserve interruptible Codex delegation for appropriate complex or
background work. Establish newly bound targets for legitimate app/document
transitions; never carry stale refs or fake continuity across them.
Use direct operations where grounded and Jev for needed semantic choices.
Terra handles actual planning/generation needs, unsupported visual
reasoning and bounded recovery; it need not wait for a pointless Jev call
on an obvious generation request. Missing permissions/policy refusals
need a remedy, not a stronger model. Terra cannot authorize an uncertain
mutation retry. Select effort from matched quality/latency evidence and
keep all recovery work away from routine dictation and direct commands.

### Bounded routing-policy comparison

Keep Jev as primary. Compare Jev-only against Jev with Terra recovery
using the same executor and independent verifier. Terra-only may be a
small diagnostic reference on the uncertain subset, not a replacement
tournament. Verify the actual API model/tool configuration before live use.
No new ChatGPT OAuth integration is needed for this approved API route;
existing Codex delegation stays separate. Terra is not an audio model.

Prepare 24 frozen observations spanning native, browser, pixel-only,
absent/ambiguous, exact/hidden and changed-context cases; three repeats
per policy. Then compare those two policies on five representative live
tasks with five repetitions each. Freeze expected outcomes, prompts,
executor/verifier, task membership and deadlines before the experiment.
Report decision-only and end-to-end comparisons separately. Do not combine
a model swap and an observation rewrite into one causal claim.

Proposed run ceiling: 500 provider requests or USD25, whichever
comes first, including warmups and retries. This ceiling is a proposal,
not a spending grant. The old 30-request TypeSafe synthetic-fixture grant
is separate and must not be repurposed. Stop/report an incomplete
comparison at the cap; no automatic extension or winner from partial data.

Evaluate strict success, wrong actions, false Done, p50/p95, cost,
requests and resources, plus escalation cause/rate, recovery yield and
unnecessary escalations. A generative model's self-written confidence is
not a calibrated substitute for an existing gate. Promote only with
reviewed evidence handling and equal-or-better strict success, no new
critical failure, acceptable tail latency and category budgets. Do not
reduce escalation by accepting a wrong Jev choice. Do not call both models
for every action. Haiku/Gemini and a broader replacement search are outside
this plan. Preserve the existing Jev pricing and allowed vendor boundary.

### P7: persistent browser work

Consume P2b: Chrome DevTools MCP primary, Safari Apple Events and Cua
fallback. Keep the real logged-in Chrome session and one persistent
browser connection; document Chrome's actual at-most-once-per-launch
consent behavior. No mandatory forked profile or per-command reconnect.
Use compact DOM/AX references, visibility/completeness, extraction,
condition-based settle and fresh results. A DOM row is not proof it is
rendered. Preserve generic screenshot fallback when DOM cannot ground.
BrowserDecider uses direct/Jev decisions where sufficient and the same
Terra recovery adapter when needed; it is not automatically Terra per step.

### P6: complete the four hero jobs

Typed native/script/browser operations provide inbox/message actions,
calendar/reminders/notes and `inbox_brief`. Use code for contacts,
accounts, dates and timezones, literal preservation and input validation.
Argv-only execution; no model-generated shell command or script.
Use existing OS runners or packaged compiled helpers, never require
the tester to install a Swift/Python development toolchain.

Read-back/confirmation for send/book/delete binds exact target/content.
Independently read the result; executing a command is not proof it
succeeded. Tests use controlled fixtures/accounts and never contact
real recipients. A built-in adapter accelerates an application; generic
control remains available without an app-specific recipe.

### P9: validated repeat work

Reuse Cua recordings and typed operations. Compile only verified traces,
parameterize literals, freshly bind semantic locators, keep consent and
postconditions, version the result and retire failing skills.
Historical coordinates are hints requiring current validated grounding.
Do not replay cached coordinates, old approvals, or an uncertain partial
mutation. Failed replay falls back safely; it never invents Done.

## C3: eyes, onboarding and distribution

P8 integrates the P2a Core ML/onnxruntime-node result into the production
Electron utility process, including the measured CPU detector fallback.
Verify real camera/preprocessing/inference/target latency, durable
calibration, no-face recovery, wake and contention with speech.
The seeded 5–7ms inference result is not whole-pipeline FPS.

P11 delivers resolved target identities, hover highlight/confidence,
separate selection, opt-in dwell with >=1s plus look-away, adaptive
sampling and tracker smoke checks. Geometry guidance applies to Jev's
overlays/disambiguation; it cannot resize another app's controls.
No raw gaze coordinates become decider authority. Voice-only use remains.

P10 makes first run capability-aware, including the original three
moments: read emails, look + open this, add an event. Complete permission
and readiness guidance, supported undo, read-back, honest remedies,
feedback/redacted diagnostics, settings and local tester metrics.
Do not advertise unavailable commands or use fake success onboarding.

P12 seals one portable runtime, including node, tracker/ONNX, browser
tooling, driver/SDK and required pruned models. Verify model-weight and
binary licenses separately from SDK licenses. Apply the existing private
tester Keychain/build-time key policy, spending caps and key rotation.
Prove normal GUI launch, helper autospawn, Keychain/TCC behavior,
relocation and no-checkout/no-Homebrew/no-cache startup. Verify signing
outside the synced checkout. Preserve the old verified app until an
approved replacement passes. Public notarization/auto-update are not
added to the existing private tester release.

## Qualification and honest shipping

P13 freezes one signed candidate. Cover native input and exact editing,
Calculator, menus/chords/drag, Chrome/Google/Safari, Notes/TextEdit,
Spotify, target switches, cancellation, ambiguity, stale callbacks and
protected controls. One clearly labeled synthetic Notes note may be used;
leave existing notes untouched and the synthetic note afterward. Confirm
Spotify is on this Mac before playback; otherwise record the case blocked.

Use the separate test account for mutating benchmark tasks. Existing reset
scripts can destroy unsaved state: do not run the old general TextEdit
reset on the personal desktop. One desktop lock owner at a time.
Backend-sensitive outcomes need actual result receipts/readback; pixels
cannot establish an unobservable persisted transaction.

Keep five evidence classes explicit: source; synthetic fixture/replay;
signed packaged app; physical human; remote/provider. Fixtures do not
prove acoustics, replay does not prove Fn, a signed CLI run does not prove
GUI startup, and a typed diagnostic does not prove microphone operation.
Reuse the 35 recordings. Perform the required normal physical population
once on the final artifact; do not repeat it after each internal patch.
Any population change must be decided before collecting evidence.

Measure active speech and eyes together on M1/8GB. Report formal RSS/CPU
and supplemental physical footprint, memory after repeated use, cold/warm
readiness, first partial, transcript final, dispatch, effect and verified
completion. A quick refusal stays a failure; failures do not disappear
from the denominator or become successful timing rows.

Use PROGRAM's minimum repeats and Wilson bar. P95 from three runs is not
a reliable tail claim. Compare identical task/start/input conditions
against Codex CU and Browser Use. The matched Wispr Flow quality/insertion
comparison and complete category scorecard in COMPETITIVE are required
evaluation work, not optional extras. Additional peers are bounded by
coverage need and the run contract. Vendor benchmarks and
documentation are architecture references, not a matched speed ranking.
No "fastest" claim without matched success and timing evidence.

P4-5/P4-6 stay open until their real criteria pass. Jev remains the primary
model; report Jev-only and hybrid results separately so Terra recovery
cannot be labeled as Jev passing its old slice. Preserve task populations,
historical results and P3's failed signed row.

All original release bars remain necessary. The new aggressive goals are
also reported at C1/C2/C3. A miss must be addressed or presented for an
explicit ship decision; an agent cannot quietly revert the goal or claim
it was achieved. Formal acceptance changes require a reviewed amendment.

## Execution discipline and evidence

Each phase has explicit owned files, reuse choices, commands, failure
cases, acceptance mapping and recovery instructions. Files shared across
phases have one writer at a time; consumers are reviewed at contract
boundaries. Follow PLANS §§3–6 for delegated investigations, independent
review and Mac admission; delegation does not change the approved scope.

Use the existing verification lane, benchmark, native witnesses and
LatencyLedger. Add capabilities to those tools only for a concrete
measurement gap. In particular, bench §7 currently accepts `mcp_stdio`;
script/replay/voice evidence must use a real public entrypoint, with any
new injector reviewed before adoption. Calling a private method is not
normal-product proof.

For future live runs, the common wrapper is:

```sh
python3 scripts/with-desktop-lock.py python3 bench/run.py --tag p5 --set test-user --runs 5 --timeout 120 --binary "$JEV_CANDIDATE_BINARY" --out "$JEV_PHASE_RESULTS"
python3 bench/report.py "$JEV_PHASE_RESULTS"
```

The phase owns its tag/manifest and exact controlled tasks; substitute its
declared tag. `JEV_CANDIDATE_BINARY` identifies the frozen signed executable,
and `JEV_PHASE_RESULTS` is a new ignored output file chosen in G2.
Missing credentials, zero selected tasks, stub/dry-run, wrong subject or
wrong injector fails qualification. Human-only cases remain human-only.
OS mutating/live work and paid calls need their existing scoped authority.

Every investigated defect starts with a reproduction or falsifiable
counterexample, at most three hypotheses and a declared time/command
budget. Make one coherent fix, run the affected checks, then repeat the
same measurement. After three unsuccessful focused attempts, review the
cause/path rather than another prompt tweak. Keep required full checks
and signing at candidate boundaries; do not extend retries/deadlines to
manufacture success.

Evidence records include source/runtime hashes, model IDs, configuration
without secrets, OS/hardware, population, harness revision, observed
outcomes, all failures, latency distributions and remaining limitations.
Independent reviewers own acceptance verdicts. G4 source readiness does
not close pending G5/G6; the final judge consumes their bound evidence.

There is no invented completion date. The next deliverable is the bounded
C1 change; progress is reported by completed behavior and remaining
blockers. Investigations and model comparisons stop at their declared
budgets instead of consuming the release indefinitely.

## Phase index

- [P3: voice](phases/P3-voice-one-brain.md)
- [P4: shared loop](phases/P4-taskloop-jevdecider.md)
- [P5: general decider](phases/P5-general-decider.md)
- [P6: script lane](phases/P6-script-lane.md)
- [P7: browser lane](phases/P7-browser-lane.md)
- [P8: eye core](phases/P8-eye-core.md)
- [P9: skill compiler](phases/P9-skill-compiler.md)
- [P10: onboarding](phases/P10-onboarding.md)
- [P11: eye polish](phases/P11-eye-polish.md)
- [P12: packaging](phases/P12-packaging.md)
- [P13: release qualification](phases/P13-release-qualification.md)
