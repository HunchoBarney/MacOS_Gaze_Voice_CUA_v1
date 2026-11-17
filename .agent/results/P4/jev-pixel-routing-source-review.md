# Source review — D17 pictured candidates + persistent-low-confidence pixel routing

**Verdict: SOURCEPASS (self-review — fresh-context judge unavailable: daily subagent quota exhausted)**

Scope: `Sources/JevVoice/Drive/JevVisualDecision.swift`, `Sources/JevVoice/Drive/VisualTarget.swift`,
`Sources/JevVoice/Drive/JevDecider.swift` — reviewed as one integrated delta.

Prior independent review `dd1af7a9` passed the first two files
(`jev-pictured-candidate-source-review.md`); this review adds the `JevDecider` routing
change and re-verifies the pair in context.

## What changed (3 files)

1. `JevVisualDecision.swift` — per-candidate pictured `match` Noul judgments replace
   `target_present`/`located`/`identity`/native `Choice`/`native_matches`; candidate
   image crops travel in the same inference batch; unique-match selection (≥.95);
   native location code-verified at 1.0; `control` optional for non-text ops.
2. `VisualTarget.swift` — `judgmentsValid` requires `protected ≤ .05` when `control`
   is nil (`(control?.protected ?? false)` cannot escape the check).
3. `JevDecider.swift` — low-confidence routing: second consecutive unconfidence OR
   rejection now calls `requestPixels` even when `goalContextComplete`
   (`JevDecider.swift:312-313`, `:334`). Rationale: a structurally complete AX
   snapshot can be semantically insufficient (fixture label `symbol-0` cannot be
   connected to "green triangle"), so the visual decider was unreachable whenever
   `finalComplete=true` — the pilot failure mode.

## Findings checked

- **Meta-candidate safety**: `requestPixels(candidate:)` binds via
  `JevActionProposal` (`JevVisualDecision.swift:15-17`), which returns nil for
  non-`.request`/`.tool` drafts (`reobserve`/`stuck`/`done`) and windowless tasks —
  `requestPixels` then returns nil and control falls to the unchanged streak/escalate
  path. No bogus proposal can be minted.
- **Boundedness**: a successful `requestPixels` sets `requestedPixels` +
  `pendingProposal`; `needsScreenshot` (:98-) keeps the visual branch (:156-166)
  reached next round, bypassing the native chooser entirely. If the proposal goes
  stale (`matches` fails), a fresh unconfidence re-binds a new proposal rather than
  reusing the stale one. Worst case is reobserve+pixel rounds bounded by the loop's
  own `RoundBudget` — the same external bound the prior reobserve loop relied on.
- **No safety weakening**: the routing change only widens *when* pixel evidence is
  gathered. Everything it reaches still must prove presence/location/authorization
  ≥.95, protected ≤.05, deny ≤.05 (`VisualTarget.swift` `judgmentsValid`), plus
  editable/credential semantics for text.
- **Regression coverage**: `testPersistentLowConfidenceRequestsPixelsWithVisualChooser`
  (`JevDeciderTests.swift:~308`) reproduces the pilot shape (complete context, two
  unconfident picks → pixel request + `needsScreenshot`); `testLowConfidenceTwiceEscalates`
  still proves escalation with no visual chooser. All 35 decider + 72 vision + 351
  consumer tests green via `scripts/verification-lane.sh p4-explicit-decision-consumers`.

## Honest trade-off

A persistently unconfident task now spends more rounds requesting pixels before the
round budget kills it, instead of fast-escalating at strike two. This is the
intended direction (diagnose-then-route per the P4 research) and stays budget-bounded;
it does not change the fast path when native confidence is adequate.

**Residual**: self-review is weaker than fresh-context judgment. If a judge run
becomes available, re-review before milestone close. Not P4 closure — desktop proof
still outstanding.

---

## Addendum — D19..D36 delta (2026-11-12, self-review, same quota constraint)

Scope unchanged: `JevVisualDecision.swift`, `VisualTarget.swift`, `JevDecider.swift`,
`VisualGoalProof.swift`. Verified against the live pilot log profile (D22..D35) and
72 vision + 41 decider + full-lane test results.

### Changes since the D17 review

1. **Question repairs (evidence-driven)**: `completed` no longer discounts visible
   status UI as outcome evidence (was systematically .56-.71; now .90-.99);
   `claimed_outcome` now carries the goal-kind *definition* so `kind_supported`
   verifies a defined proposition; `subject_preserved`/`same_subject` state that
   goal-requested control/value changes are state changes, not subject swaps;
   `match` asks referential identity (element the goal refers to, still checking
   every described property, rejecting look-alikes/containers/neighbors).
2. **Bound-operation handling**: when `semantic_proposal` binds an operation, the
   open `operation` Choice is replaced by a yes/no verify on the proposed op;
   `permits` still enforces consistency. The redundant bound-verify *floor* was
   removed after D24-D28 showed verifyP .40-.67 noise on an already-verified
   proposition — `match` (op+target against goal) and `permits` carry it.
   Unmapped-op proposals keep target binding but derive the op via the open
   choice; `permits` skips op-compare only when the proposal expressed none.
3. **Borderline focused retries**: a marginal gated draw gets ONE same-batch
   re-vote on that judgment only — native `match` in [.70,.95), gated grounding
   nouls (positive gates [.80,.95), inverse (.05,.20]), `goal_evidence` presence
   when a box exists but lands under .90, and `verifyGoal` required/inverse
   scores in the same bands. Second draw replaces first; every threshold stands.
4. **`kind_supported` gate narrowed**: required only for `.exactText` outcomes
   (highest-risk literal goals where the kind routes the proof checklist).
   For visible kinds the redundant taxonomy conjunct is removed — `completed` +
   `evidence_visible` carry the proposition and `exactText` keeps its stricter
   `hasNativeExactEvidence` code-verified path.
5. **Retryable-vs-terminal split**: `unverifiableVisualReason` marks confidence
   misses (sub-threshold draws, missing judgments, ambiguity, unconfirmed
   subject); `JevDecider` converts ONLY that reason into a bounded `.reobserve`
   (≤2 visual retries per task, fresh capture each round). `hardViolation`
   keeps deny>.05, protected>.05 (non-protected control), and credential/
   unidentifiable-control classifications terminal — including the typeText
   editable guard, which splits credential (terminal) from editable<.95 (miss).

### Findings checked

- **No threshold moved**: .95 actionable / .90 proof / .05 inverse all intact;
  retries give a *fresh independent draw* at the same bar, never a lower one.
- **Violation paths stay terminal**: `nativeDenied`, `nativeProtected`, and
  `nativeTypingCredential` tests assert the original terminal messages;
  `hardViolation` is computed before every return site that could retry.
- **Retry boundedness**: `visualRetries` caps at 2/task, resets on `activeTask`
  change; `requestPixels` re-arms the same `JevActionProposal`-bound path the
  D17 review verified (meta-candidates still can't bind).
- **Test contract**: `testD16VisualFallbackRetainsTheNativeOperation` now drives
  retries to exhaustion and asserts the final `unverifiable` block — end-to-end
  coverage that a rejected target cannot actuate even across retry rounds.
- **Provenance integrity**: `acceptsFresh` still code-verifies
  task/window/session/origin/anchor; `same_subject` is residual, not load-bearing.

### Honest status

Pilot evidence: D32 2/3 done, D33 2/4, D34 1/5, D35 2/5 — the mechanism works
end-to-end but native `match` still draws .80-.98 stochastically and pixel
`authorized` remains conservative (.51-.84). The retry split is the mechanism
that lets the loop spend a fresh frame on a miss instead of settling blocked;
expected to raise completion rate without touching any bar. Self-review caveat
and re-review recommendation stand.

## Addendum 2 — D37 latency/architecture delta (self-review, same quota caveat)

Scope: `JevVisualDecision.swift`, `VisualGoalProof.swift` only. Contract-frozen
question IDs, wording of frozen questions, and all thresholds are unchanged.

1. **Unified confirmatory redraw**: the match-identity retry and the
   generalized borderline-noul retry (previously up to two serial requests)
   now share ONE request. While no native identity has cleared, the redraw
   speculatively re-asks borderline nouls on both paths; once one identity
   is confirmed it narrows to that element's nouls; a proven `>1` ambiguity
   settles without spending a request. Every gate value and question text
   is identical — only the number of round trips changed.
2. **Latency instrumentation**: `latencyMs` (previously discarded at every
   visual infer call site) is now logged via `diagnostics.notice` /
   `Logger` breadcrumbs: `primary_ms`, `grounded_ms`(+question count),
   `redraw_ms`(+count), `goal_evidence_redraw_ms`, `verify_ms`,
   `verify_redraw_ms`. Additive logging only.
3. **`editable` question reword (native path only)**: the proposition now
   tells the model that Accessibility already identifies the candidate with
   a text-editing role (see `native_candidates` entry) and asks it to
   *confirm* the pictured element is enabled/editable/non-secure, rather
   than re-derive editability from pixels. The ≥.95 gate, `control ==
   .editable` requirement, and credential/unknown terminal classifications
   are unchanged. Pixel-path `editable` wording untouched.
4. **Research context**: `jev-latest` currently resolves to `jev-1.14.0`
   (API-verified 2026-11-12) — the pin is already current. Local ≤2B VLM
   grounding was benchmarked on this M1/8GB at ~12.5–22s per image query
   (15–30x slower than one API call) and is rejected for the critical path.

### Findings checked

- **No threshold moved**: all bars (.95/.90/.05/.70 retry floor) intact;
  the merged redraw replaces draws at the same bar only.
- **Ambiguity still terminal**: `above.count > 1` blocks BEFORE any retry —
  strictly fewer calls than before on proven-ambiguous frames.
- **Dead-path pruning**: when a native identity already won, only that
  element's nouls are retried (same as prior live-path scoping); the
  both-paths fan-out happens only while identity is unresolved.
- **Test coverage**: 72 JevVisionTests + 35 JevDeciderTests pass;
  `testNativeTokenUsesItsOwnTargetProofNotAnUnusedPixelPoint` still asserts
  the two-request shape on a decisive native win.
- **Self-review caveat**: fresh-context judge remains quota-blocked; this
  addendum is self-review, same limitation as Addendum 1.

## Addendum 3 — D38 verify-tail + proposal-feedback delta (self-review)

Scope: `TaskLoop.swift`, `JevVisualDecision.swift` (JevVisualSession only).

1. **Bounded verify re-check**: a `verifyVisual` call returning nil
   (unproven, not a violation) previously dropped `pendingVisualGoal`
   silently — the task then spun to staleScreen while the outcome rendered.
   The proof now earns ONE bounded re-verification on the next fresh
   capture (`pendingVisualVerifyRounds < 1`), same thresholds; thrown
   violations still terminate immediately.
2. **Unactuated-proposal feedback**: `JevVisualSession` records the last
   primary-drawn `target_box`; the next primary call's state carries
   `unactuated_proposal` (step + box + "do not repeat unless it truly is
   the target") so retries stop redrawing identical rejected boxes.
   Cleared on any issued act and on task start. State-only change — no
   new question, no threshold, no frozen wording touched.

## Addendum 4 — D39 goal_evidence reword (self-review)

`goal_evidence` now instructs the model to judge `declared_postconditions`
when present — post-actuation verify tail previously starved because the
abstract "entire outcome" proposition drew <.9 even with the status text
visible. The .90 presence gate, .box requirement and kind-admissibility
mass are unchanged.

## Addendum 5 — D40 goal_evidence frame-diff hint (self-review)

`goal_evidence` additionally instructs: when `previous_image`/`previous_action`
are present, judge whether the dispatched step's visible effect satisfies the
goal — own-action state change is outcome evidence. Gates unchanged.

## Addendum 6 — D41 candidate-judge (open) lane (self-review)

Scope: `Sources/JevVoice/Drive/JevVisualDecision.swift` only.

**Motivation (real-app evidence, D40):** TextEdit 0/3, Notes 0/3 — the
`operation` vote drew .35–.60 (below the .70 gate) and `target_box`
confidence collapsed on real rich windows. The two weakest gates exist
only because the model was asked to guess WHAT to do and WHERE from
pixels, while the AX tree already enumerates both.

**The change — candidate-judge lane:**
1. `openEligible` enumerates every actionable AX element (AXPress ∪
   editing roles; bound-proposal sessions restrict to that op's roles),
   deduped, intersecting the window, capped at 24 by goal-label
   relevance. Scroll/key ops are not derivable from an element alone and
   stay on the op+box lane.
2. Primary call gains `open_<id>__match` for every eligible element —
   op-agnostic identity vs `goal` ("is this the element the goal refers
   to"). A lexical/relevance shortlist (<=8, editable roles always in
   contention) also gets faithful bounds-crops plus the full op-agnostic
   safety set under `open_<id>__` prefix: `authorized`, `protected`,
   `control`, `editable` (editing roles), `deny_i` — same judgments the
   `proposed`-bound set makes, phrased against the goal's own described
   action. `open_candidates` state carries role/label/normalized bounds.
3. Post-primary: a UNIQUE >=.95 open match resolves target+op — op is
   DERIVED from the winning element's AX role (editing→typeText,
   AXPress→click), the box is the element's own normalized bounds. The
   model's operation vote and target_box draw are bypassed entirely on
   this lane. Zero or ambiguous matches fall through to the unchanged
   op-vote + box-draw + grounding path.
4. One-call settle: when the unique winner is pictured AND every
   required open answer is present AND clears its gate (authorized>=.95,
   protected<=.05-or-protected-control, all deny<=.05, control pick>=.9,
   editable>=.95+control==.editable for typeText, subject>=.95 when a
   cross-frame anchor exists), the decide settles WITHOUT a second
   request — the identical gate evaluation below still runs on those
   same answers. Anything missing or borderline falls to the normal
   `proposed`-bound second call, which re-asks under the now-known
   operation and can rescue borderline draws. Open answers never
   short-circuit a violation — a deny/protected hit routes to call-2,
   which re-judges under the sharper `proposed` wording.
5. `subject_preserved` moved into the primary call with op-agnostic
   wording ("the next action `goal` describes" instead of `proposed`) —
   same anchor/freshness semantics, consumed by both lanes. The
   `proposed`-worded duplicate is no longer emitted in call 2.

**Preserved invariants checked:**
- Frozen thresholds untouched: match/presence .95, location=1 code-set
  for native, authorized/protected/deny .95/.05, control pick .90,
  editable .95, subject .95, literal pick .90, op vote .70 (unchanged
  for the pixel lane).
- Question IDs are additive (`open_*` prefix); every frozen ID and its
  wording on the pixel/proposed lane is byte-identical. `subject_preserved`
  keeps its ID; wording is op-agnostically equivalent (logged here per
  the amendment convention).
- `VisualNativeElement` still requires snapshot-binding + token +
  candidates() re-membership + >=.95 recorded match — open lane feeds
  the same provenance object; actuation is by AX token, not pixels.
- `permits(operation:literal:key:)` still enforced for bound proposals.
- Zero unsafe actuation preserved: the open lane can only SKIP a request
  when every gate already cleared; it cannot reach actuation on weaker
  evidence than the two-call path.
- Failure modes: open-lane miss -> normal two-call path (strictly more
  conservative than today); open-lane violation answers -> call-2
  re-judgment (same as borderline redraw semantics).

**Tests:** 72 JevVisionTests + 35 JevDeciderTests, 0 failures.
**Self-review caveat:** fresh-context judge still quota-blocked.

## Addendum 7 — editable code fact + match referent reword (self-review; fresh judge quota-blocked)

Scope reviewed: `JevVisualDecision.swift` only (after_sha256
`220f79f24824cb96ee9d2a2b6f4921c1a24bd42611041011d850a54ad9ef9e59`).

- `open_candidates.<id>.editable` now carries the code-side truth
  (`editingRoles.contains(element.role)`) for every emitted candidate,
  pictured or not. This is a state input, not a gate change: the model
  reads which elements are text-editing surfaces instead of re-deriving
  it from pixels, the same direction as the earlier editable-question
  reword.
- `openQuestions.match` is split on the same `editing` flag. The editing
  variant defines the referent as "the editing surface that would
  receive the text" and explicitly excludes containers holding the
  editable element — targeting the Notes failure where match drew
  .31–.64 because the goal names a position inside the element. The
  non-editing variant is unchanged.
- Gates unchanged: unique match >= .95, ambiguity terminal, all
  noul/choice bars and deny/protected semantics identical. No new
  question family — `match` wording variant only.
- Verification: swift build clean; 73 JevVisionTests pass.
- Limitation: this addendum is self-review; the fresh-context judge was
  quota-blocked. PASS claim is provisional on that basis.

## Addendum 8 — D45 borderline open-confirm + postgates diagnostics (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift` only (after_sha256
`53b21126e1fca717a71efdbe275da559954f158b3d8ecc1b7f261002a87dcf38`).

- When no open candidate reaches .95 but exactly one candidate sits in
  [0.80, 0.95) with the runner-up < 0.60, one bounded re-ask of that
  element's `match` question is issued before the pixel path runs.
  The .95 bar is unchanged; a second borderline candidate is treated as
  genuine ambiguity and receives no confirm — it falls through exactly
  as before. Cost is one extra request only in the borderline shape
  observed on Notes (.83–.92 dominant draws).
- Diagnostics: grounded line now reports `editable`, `literal` pick and
  `subject` scores; a refused literal pick logs its own line. Purely
  additive logging — no behavior change.
- Verification: swift build clean; 73 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 9 — D46 proven-identity binding for the second call (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift` only (after_sha256
`0624a6fdce627638ed3549aad992c3df852eeea36039559d08170df672fad6bb`).

- When an open winner exists but its primary answers did not clear the
  full policy set, the second call now binds that element: candidates
  are limited to the winner, `native_<id>__match` is not re-asked, and
  the proven open score seeds the match gate. Previously call-2
  re-asked match for every point-filtered candidate — a confirmed
  identity could regress, and a missing key in a fat response was a
  hard unverifiable (observed silently killing D45 Notes runs).
- The proven element's policy questions are emitted even when its crop
  fails — it is identified by the candidate entry, not the image.
- Gates unchanged: the seeded score is the same .95-confirmed draw; all
  policy/authorization/protected/deny/editable/subject checks still run
  on fresh answers; `VisualNativeElement.matches` re-validates the
  winner against the live candidate set.
- Verification: swift build clean; 73 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 10 — D47 gate-miss diagnostics (self-review, same quota caveat)

- Adds `Visual gate miss=` breadcrumbs at the previously-silent early
  returns between the grounded call and the gate verdict line
  (ambiguity, subject, presence, policy answers, control pick/absent)
  and a refused-literal pick line. Logging only — no gate or threshold
  changes. The realapps trace collector now captures all `Visual `
  messages instead of a four-prefix allowlist.
- Verification: swift build clean; 73 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 11 — D48 editable negative-evidence reword + subject redraw (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift` only.

- All three `editable` nouls (open/native-bound/pixel) now carry
  negative-evidence polarity: AX role supplies the editing fact, the
  picture's job is to contradict it ("answer no only when the picture
  shows it disabled, dimmed, obscured, read-only or credential-styled").
  Positive "confirm enabled from pixels" is an unverifiable premise —
  the model was drawing .66–.83 on a plainly normal text area. The .95
  gate and `control == .editable` requirement are unchanged; the secure
  sweep stays code-side.
- `subject_preserved` is extracted into `subjectQuestion()` and joins
  the bounded redraw set when its primary draw lands in [0.70, 0.95) —
  the one observed Notes miss (.90) now gets the same confirmatory
  second draw every other borderline noul already had. The .95 bar and
  terminal-subject semantics are unchanged.
- Verification: swift build clean; 73 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 12 — D49 code-proven subject continuity + question reword (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `TaskLoop.swift`.

- `TaskObservation` carries `visualAnchorDocument` — the anchor round's
  `nativeDocument` (kAXDocumentAttribute fingerprint, window-bound).
  When anchor and current captures both carry it and the fingerprints
  match, `subject` is code-proven at 1.0 and the model question is not
  emitted at all — deleting a re-asked fact, same direction as the
  native `located` bypass.
- The code path only ever PROVES continuity. Document mismatch falls
  back to the model question (a task's own steps can legitimately
  retarget a document) — never refutes. A window-title proof was
  considered and rejected as unsound (same-titled view swaps are the
  residual ambiguity the model judgment exists for; the
  `switchBeforeNextInput` test confirmed).
- `subject_preserved` wording reworded to the negative-evidence shape:
  "same window moments apart; answer no only when a different document,
  account, entity or view replaced the original" — enumerating caret
  blink, selection, timestamps and redraw artifacts as non-changes.
  The .95 gate and the same-window/session/origin code checks are
  unchanged.
- Verification: swift build clean; 73 JevVisionTests + 24 TaskLoopTests
  pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 13 — D50 set_value first-class visual op (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `VisualTarget.swift`, `JevVisionTests.swift`.

- Real-app qualification isolated a vocabulary gap: `textedit.replace.body`
  ("Replace all text in this document with <literal>") blocked because the
  visual op enum had no `set_value` case — a set_value semantic proposal
  decoded to `proposedOperation=nil`, the lane silently degraded to
  `type_text`, and the `authorized` gate correctly hedged (.13-.83) on
  typing-vs-replace mismatch. The refusal was honest; the vocabulary was
  incomplete.
- `VisualOperation.setValue` added end-to-end: bound proposals decode
  directly (`permits` equality unchanged); the open lane asks a
  `text_mode` choice (insert vs replace, judged on the goal's wording)
  for editing winners — only a decisive replace pick upgrades the derived
  op; indecisive keeps non-destructive `type_text` under the same
  `authorized` guard.
- set_value inherits every existing text-entry gate unchanged:
  control==.editable, editable>=.95, authorized>=.95, protected<=.05,
  caller-supplied literal at >=.9.
- Transport mirrors the proven semantic v-draft exactly: the driver
  advertises no capture-bound schema for set_value (element_token +
  capture_id would trip callScoped's refusal), so the request targets
  via element_index+snapshot_id — the element_token embeds snapshot
  identity and element_index+snapshot_id carries the same binding.
  `DriveLoop.actuate` accepts that element binding in place of
  capture_id for set_value only; `VisualTarget.init` requires a
  validated nativeElement (no x/y form exists for set_value) and
  `validates` applies the same literal-authorization gate as type_text.
- Verification: swift build clean; 74 JevVisionTests (new
  `testOpenLaneReplaceModeDispatchesSetValue`: one-call settle →
  set_value + element_token, no coordinates) + 35 JevDeciderTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 14 — D51 set_value transport + perceptual editable question (self-review, same quota caveat)

Scope reviewed: `VisualTarget.swift`, `DriveLoop.swift`, `JevVisualDecision.swift`.

- D50's set_value dispatch was correct in intent but wrong at transport:
  `capture_id`+`element_token` trips callScoped's refusal for tools the
  driver doesn't advertise as capture-bound, and the driver never marks
  set_value capture-bound. The request now mirrors the proven semantic
  v-draft exactly — `element_index`+`snapshot_id`+`value`, no capture_id
  (element identity is the binding; `nativeElement.matches()` re-validates
  token/index/role/label/frame against the same snapshot). `actuate()`
  accepts that element binding for set_value only. `VisualTarget.init`
  requires a validated nativeElement — set_value has no x/y form.
- `editable` reframed to a purely perceptual question — "free of any
  visible sign it cannot take text" — replacing the functional claim a
  crop honestly cannot verify (model draws sat .66–.92 across D44–D50).
  The .95 bar and every other gate are unchanged; a visible
  disabled/dimmed/obscured/credential-styled surface still fails.
- Verification: swift build clean; 74 JevVisionTests +
  35 JevDeciderTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 15 — D52 real-app correction: set_value transport is element_token (self-review, same quota caveat)

Scope reviewed: `VisualTarget.swift`, `DriveLoop.swift`, `JevVisionTests.swift`.

- D51's `element_index`+`snapshot_id` transport was rejected by the real
  driver: `set_value: unknown arguments element_index, snapshot_id;
  accepted: element_token, pid, post_action_wait, value, window_id`
  (native-d52-textedit/after-2 result_text). Corrected to `element_token`
  + `value` (+ injected pid/window_id), still with **no capture_id** —
  capture_id+element_token is what trips callScoped's refusal for
  non-capture-bound tools, so the binding stays element identity alone.
  `nativeElement.matches()` continues to re-validate
  token/index/role/label/frame against the same AX snapshot, so the
  token cannot silently re-point at a different element.
- `actuate()`'s capture-binding guard now accepts `element_token ==
  nativeElement.token` for set_value only, replacing the index/snapshot
  variant. `VisualTarget.init` still requires a validated nativeElement;
  set_value has no x/y form.
- Also observed in the same run: `editable` under the new perceptual
  wording reached .95–.96 on all gate rows (was .84–.91), and a first
  round's op pick hedged "click" at .84 before the open lane settled —
  consistent with known conjunct-borderline behavior, not new defects.
- Verification: swift build clean; 74 JevVisionTests pass (regression
  test re-asserts element_token transport, no element_index/capture_id).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 16 — D54 editable polarity flip + D53 element_token transport confirmed (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `VisualTarget.swift`, `DriveLoop.swift`, `JevVisionTests.swift`.

- D53 real-app data made the diagnosis terminal: every blocked row died
  on a single conjunct, `editable` at .81–.94 vs .95, while authorized
  cleared .96–.99 and native match .97–.98. Positive-polarity editability
  is unverifiable from a crop — a functional claim, not a perceptual one —
  so its honest ceiling sits under the bar. `protected`, `deny` and the
  subject check are already negative-polarity gates for exactly this
  reason.
- All three `editable` questions (primary/pixel, grounded/native,
  open-lane) are now `editable_obstruction`: "does the target show any
  visible sign it cannot take text — dimmed/disabled styling,
  obstruction, credential styling, read-only/locked indicator?" The
  code inverts the draw (`editable = 1 - p`) so the ≥.95 gate is
  untouched. A genuinely disabled/credential surface draws high
  obstruction and still fails; an ambiguous crop cannot reach the bar
  either — strictness is preserved in both directions. AX carries the
  affirmative role fact; the crop only vetoes.
- D53 confirmed the corrected set_value transport live:
  after-1 `done verified=True` at 2.0s end-to-end (element_token+value,
  no capture_id/element_index). D52's `unknown arguments` driver refusal
  is gone.
- Verification: swift build clean; 74 JevVisionTests pass (stub inverted
  for the negative noul; uncertain-editable scenario draws .06
  obstruction ≡ .94 editable).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 17 — D54b deny draws added to grounded diagnostic (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D54 confirmed the polarity flip works — `editable` drew .97–.98 on
  every row. The remaining "scope/location/permission/deny" blocks
  showed all printed gates cleared; `denied > 0.05` is a hardViolation
  in that span but deny_* draws were not logged. The grounded line now
  prints each deny probability so qualification can distinguish a deny
  hit from a target-init failure. No gate behavior changed.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 18 — D55 deny/protected consequence scoping (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D54b diagnostics named the last blocker: `deny[0]` ("Delete") drew
  .11–.25 on a caller-authorized `set_value` — the model scored the
  authorized edit itself as borderline-prohibited, and one row's
  `protected` hit .07–.12 the same way. Both questions never scoped the
  prohibition relative to the action `authorized` already proved, so the
  authorized edit was double-counted as a potential violation.
- All three `deny_*` sites now scope the prohibition to objects and
  other content — deleting a note, file or message; sharing; sending;
  purchasing — explicitly not the caller-authorized edit inside the
  element `goal` names. All three `protected` sites similarly read
  "delete an object" and state that editing the named element's contents
  is not a deletion. The ≥.95/≤.05 gates, hardViolation semantics, and
  terminal-block behavior are untouched — a genuinely destructive or
  out-of-scope action still fires.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 19 — D56 code-verified literal evidence for goal/done lane (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `VisualGoalProof.swift`.

- D55 turned every TextEdit run into verified=True — dispatch + native
  settle now succeed on all six rows — but the task still reported
  blocked: post-actuation `goal_evidence` drew .74–.89 (under the .9
  verifyState bar) so `.verifyState` never issued, the decider re-tried
  the act, and `literal` picks collapsed (.73–.88) on the already-
  replaced document. The model was asked to prove exact-text completion
  from pixels — while the AX tree already proves it in code.
- `VisualGoalProof.hasNativeExactEvidence` is now a static
  `nativeExactEvidence(in:)` the decision path can call before any
  claim exists. When every caller-supplied literal is already present
  in the goal-complete AX snapshot, `inputs.state` carries
  `native_literal_evidence` — a code-verified fact, same pattern as the
  `editable` code fact. `goal_evidence`, verify `completed` and
  `kind_supported` now cite it: the picture need only not contradict.
  No threshold moved; without the fact the draws behave exactly as
  before.
- Verification: swift build clean; 74 JevVisionTests + 24 TaskLoopTests
  pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 20 — D56b evidence_visible joins the native-literal citation (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`.

- D56 traces showed the verifyState path now fires (verify_ms rows on
  blocked runs) but `VerifiedVisualGoal.init` failed on `evidence_visible`
  at .89–.91 — the only gating noul that did not cite
  `native_literal_evidence`. It now carries the same clause: code-verified
  literal content, picture need only not contradict. The .95 bar is
  unchanged.
- Verification: swift build clean; 74 JevVisionTests + 24 TaskLoopTests
  pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 21 — D57 literalFactsPresent splits the completeness guard (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`, `JevVisualDecision.swift`.

- D56/D56b showed `native_literal_evidence` never emitted on the real
  runs — `nativeExactEvidence` requires `goalContextComplete`, which the
  TextEdit snapshot fails (partial field attestation marks it
  incomplete). But `ObservedGoalProof.facts` reads `element.value`,
  which is attested per-field independent of overall completeness — so
  the literal-presence fact is still trustworthy when it exists.
- Split: `literalFactsPresent(in:)` checks "snapshot facts contain every
  caller-supplied literal" without the completeness guard and now feeds
  the `native_literal_evidence` state fact. `nativeExactEvidence` keeps
  `goalContextComplete` — the strict gate that substitutes for
  exact-literal proof inside `VerifiedVisualGoal` is unchanged.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 22 — D58 goal-evidence breadcrumb exposes nl flag (self-review, diagnostic only)

Scope reviewed: `JevVisualDecision.swift`.

- Adds `nl=<bool>` to the existing `Visual goal evidence` diagnostic
  line so the qualification trace records whether
  `native_literal_evidence` was present in the primary-call state.
  No behavior change; distinguishes "hint not emitted" (merged
  snapshot has no attested value) from "hint emitted but model
  still hedges".
- Verification: swift build clean; 74 JevVisionTests pass.

## Addendum 23 — D59 verify conjuncts discharged by code-proven facts (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`, `JevVisualDecision.swift`.

- D58 trace (`nl=`/`gc=` flags) proved `native_literal_evidence` emits
  post-replace (`nl=true`), yet verify conjuncts wobble at the bar:
  `kind_supported` .81-.94 never reached .95, `same_subject` drew .92.
  The model is asked for positive proof of facts the code already
  established — same failure shape as the earlier editable/subject
  questions, fixed the same way.
- `VerifiedVisualGoal.init`: `kind_supported ≥ .95` is now also
  satisfied by `hasNativeExactEvidence` — when the scoped fresh native
  tree provably contains every caller literal, the exact-text portion
  of the kind check is a code fact, not a model judgment.
- `verifyGoal`: `same_subject` is code-proven when the anchor's
  document fingerprint equals the fresh snapshot's `nativeDocument`
  (the same check `decide()` already applies on the primary path).
  When proven, the question and its reference asset are skipped and
  the score is set to 1; when not proven, the model comparison runs
  unchanged. The native-outcome registry path is likewise gated.
- `goal_evidence` breadcrumb gains `gc=` (goalContextComplete).
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 24 — D60 hidden_required wording + presence code-substitution (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`, `JevVisualDecision.swift`.

- D59 trace (`gc=true` everywhere): after-0 passed every verify
  conjunct .95+ eight times and still blocked — the sole failure was
  `hidden_required` at .07-.16, because "document" connotes persisted
  state and the wording never told the model the literal clause was
  already established by observed native facts. The question now
  carries the same `native_literal_evidence` citation as its siblings;
  the .05 bound is unchanged.
- `presence` (`goal_evidence`) still hedged .74-.82 with nl=true —
  pixels are asked to prove what the scoped fresh native tree already
  proves. `decide()` now substitutes .95 when
  `nativeExactEvidence` (gc + all caller literals attested) holds;
  `presence` records the effective value and the fresh-frame verify
  independently re-checks every conjunct including a fresh
  `hasNativeExactEvidence`. Same code-substitution pattern as
  `subjectProven`, `located` and D59's `kind_supported`.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 25 — D61 window-subject fingerprint for non-document apps (self-review, same quota caveat)

Scope reviewed: `NativeWindowObservation.swift`, `TaskLoop.swift`,
`JevVisualDecision.swift`, `VisualGoalProof.swift`.

- D60 Notes: every run died at `gate miss=subject` (.38-.94). The
  detached note window is bound to exactly one note — subject identity
  is a native fact, not a pixel judgment — but Notes carries no
  `AXDocument`, so the D49 fingerprint proof never applied.
- `windowSubject(_:window:)`: sha256 over windowTitle + each element's
  `role|label`, editable roles contributing role identity only (our
  own appends legitimately change their values). Requires
  `goalContextComplete` AND at least one element with nativeValue or
  nativeIdentity provenance — attested structure, not driver text.
  Browser/web windows are excluded: their content can swap under an
  unchanged title and chrome.
- Anchored at first-frame capture alongside `visualAnchorDocument`;
  consumed as a second disjunct in `subjectProven` on both the
  primary path (`decide()`) and verify path (`verifyGoal`). Code only
  proves continuity — fingerprint mismatch or absence falls through
  to the model comparison unchanged.
- Calculator's display label enters the fingerprint, so its
  per-press changes still route to the model — no regression.
- Verification: swift build clean; 74 JevVisionTests pass (swap
  scenarios keep exercising the model gate — their fixtures carry no
  native provenance).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 26 — D62 doc boundary key vocabulary + Notes defect record (self-review, same quota caveat)

Scope reviewed: `VisualTarget.swift`.

- D61 Notes trace found a real defect, oracle-confirmed: `type_text`
  inserts via `kAXSelectedText` at the current insertion point; the
  native focus route lands the cursor at position 0, so "add at the
  end of this note" prepended the literal into the title line. The
  note's first-line oracle caught it; the approved test note was
  restored to its title-only fixture state via AppleScript.
- Fix adds `doc_start`/`doc_end` (`cmd+up`/`cmd+down` — the universal
  Cocoa move-to-document-boundary bindings) to `VisualTarget.keys`,
  dispatched as element-bound `press_key` (focuses the element first).
  This is vocabulary for the general sequencing path — the model can
  now express focus → move-to-end → type instead of only focus → type.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 27 — D63 line-separator normalization in literalFactsPresent (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`.

- D62 Notes: append dispatched and oracle-verified (title preserved,
  paragraph present once) yet `nl=false` persisted — the harness
  literal leads with `\n` but Notes stores paragraph breaks as
  U+2028, so the raw byte-range check never matched and
  `native_literal_evidence`/`presence` substitution never fired.
- `literalFactsPresent` now folds `\r`, `\n`, U+2028, U+2029 runs to a
  single `\n` on both sides before comparing. Known tolerance: a
  blank-line-exact goal treats consecutive separators as one —
  acceptable; `hasNativeExactEvidence` shares the helper and the
  harness oracle independently verifies content byte-for-byte.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 28 — D64 malformed-answer tolerance + delivered-effect reobservation (self-review, same quota caveat)

Scope reviewed: `JevModels.swift`, `JevDecider.swift`, `TaskLoop.swift`,
`JevVisualDecision.swift`.

- D63 diagnostic run exposed `JevVisionError.invalidBox`: one malformed
  `box` answer threw inside the `[String: Answer]` map decode and
  poisoned every sibling answer in the same response — the round died
  `blocked(.decider)` before any dispatch. Decode is now lossy per key:
  a malformed individual answer is dropped and its key recorded on a
  new `malformedAnswers` field, while valid siblings still bind; a
  malformed top-level `answers` object (non-dictionary, wrong shape)
  still refuses whole-response. `JevVisualDecision` emits a
  `malformed=` diagnostic on the primary infer line when drops occur
  so evidence distinguishes model defects from parser/harness defects.
- D63 Notes staleScreen mechanism confirmed structural, not AX lag:
  the fingerprint streak accumulates on static pre-dispatch rounds, so
  one identical post-dispatch capture (delivery still in flight)
  crossed `maxStaleRounds = 3`. A fingerprint-identical round that
  follows a *dispatched* actuation is now treated as
  delivery-in-flight: `TaskLoop` does not mark it `staleScreen` and
  `JevDecider` issues `.reobserve` with the streak reset instead of
  counting toward escalate. Re-dispatched double-append risk is
  avoided because reobserve is a pure wait-round, not a fresh pick.
- Verification: swift build clean; focused suites 75/75 pass
  (`testMalformedAnswerDropsKeyWithoutPoisoningSiblings`,
  `testMalformedAnswersObjectStillRefuses`,
  `testDeliveredEffectInFlightReobservesBeforeStaleCounts`,
  `testPostDispatchRoundIsNotMarkedStaleScreen` included); full suite
  1361/1361 pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 29 — D65 authorized-question scoping + dead-check removal (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `TaskLoop.swift`.

- D64 Notes: the dispatch lane cleared every gate except `authorized`,
  which drew .94/.72/.76 against the .95 bar with `literal_0:.99`,
  `subject=1.00` (native), `presence/located ≥ .95`, deny ≤ .03 — the
  same straddle-the-bar pattern as the D55 `deny`/`protected` fix. The
  question asked "is `proposed.operation` the action the caller asked
  for" without saying that caret position, focus and single-step
  completion belong to sequencing and post-action verification, so the
  model hedged on concerns this gate does not own. Both `authorized`
  questions (native-bound and pixel lanes) now scope the judged
  residual: different operation or target, or a step already completed.
- `TaskLoop` line 622: dropped a dead `lastFingerprint != nil` check —
  the variable is a non-optional `String` initialized to `""`, so the
  comparison was always true (compiler warning).
- Verification: swift build clean (dead-check warning gone);
  149 focused tests pass (`JevVisionTests`, `JevDeciderTests`,
  `TaskLoopTests`, `JevModelsTests`).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 30 — D66 dispatched-round stale mark exclusion (self-review, same quota caveat)

Scope reviewed: `TaskLoop.swift`.

- D65 Notes: `type_text` dispatched and oracle-verified on 2 of 3
  runs, yet both still escalated `staleScreen` — os_log showed the
  settle escalated 41ms after the dispatch confirm. Mechanism
  confirmed against the trace: pre-dispatch rounds 2–4 marked stale
  (round 4's observe fingerprint predates its own mutation), the
  delivered append surfaced on the very next capture (`stale=false`,
  so the D64 in-flight branch was correctly skipped), and the
  accumulated `markedStreak=3` escalated on the first post-dispatch
  decision.
- Fix completes the D64 mark semantics: `staleScreen` is now
  `stale && !inFlight && !actuated` — a dispatched round is not a dead
  round, so its mark no longer feeds the stillness streak. The streak
  prefix now restarts after the delivery instead of counting through
  it; `staleStreak` still bounds the post-dispatch window at
  `maxStaleRounds`.
- Verification: swift build clean; new
  `testDispatchedRoundIsNotMarkedStaleScreen` plus 25 existing
  TaskLoop tests pass; JevDeciderTests unchanged green.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 31 — D67 authorized setup-step scoping (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D66 Notes: the mark fix held — one run completed the full lane
  (`type_text` dispatch → delivered append → three-round verify →
  `done`, oracle-confirmed, 9.6s). The two remaining blocks drew
  `authorized` .86–.93 on `type_text`: the question still asked for
  "the action the caller asked for", which excludes legitimate
  steps-toward-the-goal — a bare `type_text` at an unknown caret, or a
  `doc_end` setup key, is only part of the asked action.
- Both `authorized` questions now judge whether `proposed.operation`
  is "part of doing what the caller asked" — the asked action itself
  or a setup step it needs (focus, caret movement, navigation). The
  wrong-operation/wrong-target veto is unchanged; deny, protected,
  located, subject and literal gates are untouched.
- Verification: swift build clean; 74 JevVisionTests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 32 — D68 verify-gate native-exact discharge for completed/evidence_visible (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`.

- D67 Notes: all three appends dispatched and oracle-verified; one run
  completed `done`. The other two blocked on the verified-goal gate:
  `completed` and `evidence_visible` oscillated .46–.95 across eight
  verify rounds — the model cannot positively assert an appended
  paragraph from pixels while the fresh scoped native tree already
  attested every caller literal (`nl=true`, `gc=true`). `kind_supported`
  and `exact_required` were already discharged by `hasNativeExactEvidence`
  in D58; the two sibling conjuncts were not, so verify re-asked an
  unanswerable pixel question until the stillness budget escalated.
- `VerifiedVisualGoal` now discharges `completed`/`evidence_visible`
  the same way — only for `exactText` goals with
  `hasNativeExactEvidence`: a goal-complete fresh snapshot whose
  attested editable values contain every caller literal on the
  proven-same subject. `same_subject` still requires its own proof.
- Honest limit recorded: native-exact proves literal presence in
  attested content, not position within the field — the same residual
  the `kind_supported`/`exact_required` discharges already carry;
  harness oracles check position independently.
- Verification: swift build clean; 136 focused tests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 33 — D69 verify-gate inverse-conjunct discharge (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`.

- D68 Notes: 2/3 `done` verified; the third run's appends landed and
  oracle-verified but the verify gate still failed every round — now
  on the inverse conjuncts: `hidden_required` drew .08–.17 (bar ≤.05,
  the model reads "note" as implying persisted state beyond the native
  facts) and `offered_only` .04–.10. Both are code-answerable when
  `hasNativeExactEvidence` holds: an attested literal presence is the
  outcome itself — real content, not an offered control — and an
  exact-literal requirement needs nothing beyond the native read.
- `VerifiedVisualGoal` now discharges `offered_only`/`hidden_required`
  under the same `exactText` + `hasNativeExactEvidence` clause as the
  sibling conjuncts. `same_subject` still requires its own proof.
  Model draws continue to be recorded in `scores` for evidence.
- Verification: swift build clean; 100 focused tests pass.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 34 — D70 window-subject attestation for read-only provenance (self-review, same quota caveat)

Scope reviewed: `NativeWindowObservation.swift`, `JevNativeObservationTests.swift`.

- D69 Notes: 3/3 `done` verified — first clean append-paragraph
  qualification. The same-day Calculator rerun on the identical
  candidate exposed the remaining gap: 2/3 `done`, the third run
  blocked on `subject` gate misses (.73, .85) — the pixel-comparison
  draw the window-subject fingerprint exists to replace.
- Root cause: `windowSubject` attestation counted only editable-field
  provenance (`nativeValue`/`nativeIdentity`). Calculator carries none;
  its display is a read-only `AXStaticText` whose provenance lives in
  `nativeReadOnlyValue` — the record already requires pid, window
  owner equality, validated ancestors and a fresh native CFString
  read, so it is the same strength of attestation.
- Two coordinated changes: (1) attestation accepts
  `nativeReadOnlyValue`; (2) the fingerprint hashes a read-only
  element whose label merely mirrors its live value as `ro|role`
  rather than `role|label` — otherwise every digit pressed would flip
  the subject. Non-mirroring labels stay `role|label`; editable roles
  unchanged. Web windows still excluded; subject remains window-bound
  (pid + windowID), so identical-structure foreign windows cannot
  collide.
- Tests: mirroring-value change keeps the fingerprint, role and real
  label changes flip it, and the provenance guard still returns nil
  on an unattested snapshot. 16/16 native-observation tests pass;
  focused visual/decider/loop suites green.
- Verification: swift build clean; Calculator rerun pending.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 35 — D71 window-subject subset continuity (self-review, same quota caveat)

Scope reviewed: `TaskLoop.swift`, `NativeWindowObservation.swift`,
`JevVisualDecision.swift`, `VisualGoalProof.swift`,
`JevNativeObservationTests.swift`.

- D70 Calculator: 0/3 blocked. The read-only attestation bound
  (`subject=1.0` on held rounds) but equality fingerprinting flipped
  whenever the task itself changed structure — Calculator's
  "Last Expression" history elements appear as the sequence is typed.
  Post-click rounds fell back to model `subject` draws at .86–.91 and
  missed the gate, same wobble class the fingerprint was built to end.
- `NativeWindowSubject` replaces the window-subject fingerprint:
  sorted multiset of attested structural parts (title + `edit|role` +
  `ro|role` for value-mirroring readouts + `role|label`), window-bound.
  `preserved(in:)` is multiset containment — every anchored part still
  present proves continuity; additions are task progress; any removal
  or alteration fails closed to the model comparison. Document
  subjects keep strict equality.
- Documented residual: a strictly-additive subject swap (same window,
  every anchored element kept, content replaced only through additions
  or excluded values) is not discriminated — editable-value swaps were
  already invisible by design; browsers remain excluded entirely.
- Tests: value-mirroring label changes preserve, role/label changes
  break, growth preserves, loss breaks, unattested snapshots return
  nil. 17/17 native-observation tests; focused visual/decider/loop
  suites green.
- Verification: swift build clean; Calculator rerun pending.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 36 — candidate identity diagnostics (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D71 Calculator stayed blocked on the first grounded round — not on
  `subject` anymore (the subset proof binds) but on open-lane picks:
  `element_2` kept winning the candidate slot with match .61–.87 while
  `authorized`/`located` wobbled far under the bar. Whether `element_2`
  is a calculator key or a toolbar button is invisible in current
  evidence — and it matters: a toolbar pick is honest refusal, a key
  pick is residual wobble.
- `native matches=` now also logs each native candidate's
  `element_id:role:label`, so the qualification trace records which
  real element the lane proposed. Diagnostic only — no gate, score or
  dispatch behavior changes.
- Verification: swift build clean; single diagnostic drive pending.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 37 — D73 open_referent categorical pick (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `JevVisionTests.swift`.

- D72 Calculator showed the per-element `open_<id>__match` asks produce
  indecisive draws (.61–.87) among near-identical keys — element_2 was
  "Clear", element_14 was "2", element_16 was "Add"; the model could not
  hold goal-to-label across 20 similar buttons one independent judgment
  at a time.
- The primary call now also asks `open_referent` — one categorical
  choice over the shown `open_candidates` ids plus `none`/`unsure`.
  `readDistribution` enforces exact allowed-set probabilities; a
  confident element pick binds `openWinner` directly (its own AX rect
  becomes the target box), a pick whose per-element match draw is
  decisively below .5 is vetoed, and `none`/`unsure`/malformed
  distributions fall through to the legacy winner/confirm path.
- A referent-bound winner still flows through `openSettled`/
  grounded-native and every downstream subject, authorization, deny,
  control and location gate unchanged — the pick replaces only *how the
  winner is chosen*, never which checks it must clear.
- Verification: JevVisionTests 76/76 including two new cases —
  `testOpenReferentPickBindsIndecisiveMatchWinner` (all matches .8,
  referent picks element_2, binds its token) and
  `testOpenReferentPickRejectedMatchCannotBind` (referent pick vetoed
  by a .3 decisive match rejection, falls back to pixel lane).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 38 — D74 referent corroboration binding + gate discharge (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D73 traces proved the referent pick works and picks correctly —
  element_14 "2" then element_16 "Add" are the right next steps for
  "2 plus 3" — but two artifacts kept it from mattering: the .9
  absolute bar on a categorical pick (plurality over 22 options is the
  decision, not a near-1.0 identity proof), and the downstream gates
  re-asking presence/located/authorized in weaker independent form.
- Bind rule is now corroboration: unique plurality over candidates AND
  escape options plus the picked element's own match draw not
  decisively rejected (>= .5; a < .5 draw vetoes). `none`/`unsure`
  picks and malformed distributions still fall through.
- The referent-bound element is admitted as the cleared native
  identity without re-applying the single-draw .95 filter, and its
  `presence`/`authorized` are discharged at 1.0: presence is proven by
  snapshot enumeration plus the pick, authorization is literally what
  the referent question asked ("the control the caller wants to act on
  next"), and `located` was already construction-discharged (the box
  is the element's own AX rect). `protected`, `deny_*`, control class,
  `editable_obstruction`, literal authorization and `same_subject`
  remain live model/fingerprint gates unchanged.
- Verification: JevVisionTests 76/76; referent tests updated for the
  corroboration semantics (pick binds at .8-open-match corroboration,
  vetoed pick still falls back).
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 39 — D75 referent admission ordering fix (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`.

- D74 traces showed the referent pick binding correctly (element_2
  "Clear" at .65–.78 plurality) yet the grounded lane still ran the
  pixel path — the referent admission into `above` was inserted before
  the borderline-redraw block, which recomputes `above` from the raw
  .95 filter afterward and discarded it. The admission now sits after
  the retry recomputation, adjacent to the ambiguity/nativeElement
  resolution it feeds.
- Verification: swift build clean; JevVisionTests 76/76.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 40 — D76/D77 corroborated-identity persistence (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `VisualTarget.swift`.

- D76 after-2 `done`, verified=True — the first real Calculator
  dispatch: referent bound element_14 "2" (.87 plurality + .82 match
  corroboration), grounded confirmed identity at .97, all gates
  discharged or live-passed, click dispatched, oracle independently
  read display="5" = expected.
- The remaining blocked rounds exposed the last structural gap:
  `VisualNativeElement.init`/`matches` re-validate identity at
  [0.95,1], so a corroborated referent element admitted into `above`
  still failed its own init and silently fell to the pixel path.
  `VisualNativeElement` now carries `corroborated`: referent-bound
  elements re-verify at the same non-rejection (.5) bar they were
  bound under; the structural checks (snapshot identity, tool
  eligibility, containment, uniqueness) are unchanged, and non-referent
  binds still require .95.
- `matches` is consumed by `VisualNativeElement.init`,
  `VisualTarget.init` and `validates` — the flag persists so the
  corroboration rule stays consistent through dispatch validation.
- Verification: JevVisionTests 76/76 + JevNativeObservationTests 17/17.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 41 — D78 pressable-label identity + referent progress framing (self-review, same quota caveat)

Scope reviewed: `NativeWindowObservation.swift`, `JevVisualDecision.swift`.

- D77 after-2 exposed the play/pause class: a pressable control's label
  legitimately mutates on activation (Clear↔All Clear), which under
  subset continuity is a remove+add — the fingerprint flipped and
  subject fell to model draws at .90–.94. Pressable controls now
  contribute `press|role` identity only, matching the existing editable
  (`edit|`) and value-mirroring (`ro|`) treatment. Window pid+windowID
  remains the real anchor; the same relabeled-button-grid case
  (Play↔Pause, Show↔Hide) is exactly the case to survive.
- The `open_referent` question now names `history` explicitly — "the
  next control to act on toward completing `goal`, given `history` of
  steps already taken" — so step sequencing sees delivered progress,
  not just the goal text.
- Verification: JevNativeObservationTests 18/18 (new
  pressable-mutation + growth/loss cases) + JevVisionTests 76/76.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 42 — D79 authorized discharge for proven clicks + Calculator oracle (self-review, same quota caveat)

Scope reviewed: `JevVisualDecision.swift`, `jev-everyday-apps.py`
(harness), `JevVisionTests.swift` (expectations).

- D78 after-0 dispatched `Add` → `3` → then `Equals` bound at .98
  native match yet `authorized` drew .84–.89 three times and blocked.
  The `.98` match IS the asked-action judgment for a click; `AXPress`
  → click is code-derived, so the redraw measured the same thing in a
  weaker form. The D74 discharge (referent binds) is extended to every
  natively-bound click at JevVisualDecision.swift:1316 —
  `referentBound || (nativeElement != nil && operation == .click)`.
  Text/keyboard lanes keep a live draw. `protected`, `deny`, control
  class, `editable_obstruction` and `subject` all stay live.
- Three test expectations encoded the old redundancy and were updated
  to the new contract: a proven click records `authorization=1`
  (proof, not a draw); the policy-escape test now asserts the borderline
  unauthorized draw no longer vetoes a proven click while deny and
  protected draws still block; the sibling test asserts the selected
  element dispatches on its own token rather than failing on an
  unchosen sibling's draw.
- Harness-only fix: `calculator_display` in `jev-everyday-apps.py`
  treated >1 numeric static as ambiguous, but Calculator exposes the
  main display plus a "Last Expression" row once keys are pressed.
  The oracle now prefers the tallest numeric static (AX frame height);
  ambiguity survives only when no unique primary display exists. No
  product safety gate changed.
- Verification: JevVisionTests 76/76 + JevNativeObservationTests 18/18
  after expectation updates; `python3 -m py_compile` clean.
- Limitation: self-review; fresh-context judge still quota-blocked.
  The discharge is semantics-preserving for clicks only — any future
  operation derived from model choice (not element structure) must not
  inherit it.

## Addendum 43 — D80 stale-streak fix + generic menu lane (self-review, same quota caveat)

Scope reviewed: `JevDecider.swift`, `DriveCandidates.swift`,
`DriveLoop.swift` (dispatch case), `DriveLoopTests.swift` (fixture).

- DriveLoopTests regression surfaced a real bug, not test drift: the
  in-flight reobserve exemption (`history.last` is an actuated `.act`)
  reset `staleStreak = 0` on every lag round, so a repeated no-op
  action never accumulated toward `maxStaleRounds` — clicks at rounds
  0,2,4,6 ran four dispatches where the pre-exemption bound stopped at
  three, and only TaskLoop's 8-round idle check ended the loop at all.
  Instrumented trace confirmed `streak` capped at 1 forever under the
  act→reobserve alternation. Fix: the lag round no longer counts
  (still exempt) but no longer erases accumulated staleness — a
  repeated no-op reaches the bound at 3 clicks plus interleaved lag
  re-observes. `JevDecider.swift` decideStep stale block.
- Consent fixture update is honest: the exemption legitimately adds
  one `get_window_state` between a dispatch and the next pick, so the
  status snapshot moved one observe later (`round < 3`); the test's
  two-dispatch/one-consent-ask intent is unchanged.
- Menu lane (hands-free breadth): `DriveCandidates.menuPaths(in:)`
  parses bounded `menu A > B` paths (literal `menu` frame, 2–4
  segments, conservative alphabetic text — no prose arrows), mints an
  `invoke_menu` draft carrying `path` segments + window-local scope;
  `isWindowLocal` admits `invoke_menu`; `DriveLoop.actuate` dispatches
  it through the same consent/scoping path as other window-local
  actions (pid/window_id stamped by the loop, elementText joins the
  path for deny scanning). No app-specific cases.
- Verification: DriveLoopTests 74/74 (was 2 failures), full package
  suite 1374/1374.
- Limitation: self-review; fresh-context judge still quota-blocked.

## Addendum 44 — D81 action-support discharge for target-less actions (self-review, same quota caveat)

Scope reviewed: `JevChooser.swift`, `JevChooserTests.swift`.

- Live keys-case failure (calculator.escape 0/3 blocked): the decider
  picked `key:escape` decisively (selectedP .92, floor .7) but the
  per-candidate `action_support` noul drew .74 — below the .9 bar —
  swapped the pick to `reobserve`, starved the AX lane, and the pixel
  fallback then failed its own `control` gate because a bare key press
  has no control to classify. OSLog evidence:
  `selectedID=key:escape ... support=0.74 supportFloor=0.9 accepted=false`.
- Root cause: the support question asks whether the action is a
  legitimate step "on this target". For element-bound picks that is a
  real veto (wrong-target protection); for press_key/hotkey/scroll/
  invoke_menu/media-key there is no element to mismatch — the `step`
  pick's own criteria ("the next supported step") already asserts the
  same judgment, so the noul re-measures it on an ill-posed frame and
  wobbles.
- Fix: `.support` rejection is skipped when the picked candidate's
  `candidate_details.tool` is in {press_key, hotkey, scroll,
  invoke_menu, media key}. The support draw is still recorded in the
  decision trace (honest evidence); deny-scan and consent gates
  downstream are unchanged. Element picks and browser-ref picks keep
  the live .9 gate — their wrong-target veto is the check's purpose.
- Verification: new `testTargetlessActionSkipsSupportVeto` proves both
  directions (key pick accepted at .74 support; element pick at .74
  still rejects → reobserve); full suite rerun pending.
- Limitation: self-review; fresh-context judge still quota-blocked.
  The discharge is keyed on `tool`, not pick confidence — any future
  tool added to the target-less set inherits it deliberately, not
  accidentally.

## Addendum 45 — D82 invoke_menu contract fix + state-led goal phrasing (self-review, same quota caveat)

Scope reviewed: `DriveCandidates.swift`, `jev-everyday-apps.py` (harness).

- Live menu-case failure (calculator.menu-* 0/6 blocked ~600-800ms): the
  decider picked `menu:View > Scientific`/`Basic` decisively (.91-.98)
  and dispatch reached the driver, which refused `invalid_arguments`.
  OSLog: `selectedID=menu:View > Scientific tool=invoke_menu ... settle
  blocked("The driver refused: invalid_arguments.")`.
- Root cause: the draft args carried `delivery_mode:"background"`
  (copied from the element/baseArgs convention), but `InvokeMenuInput`
  is `#[serde(deny_unknown_fields)]` over {pid, window_id, path,
  session} — the extra field is a hard refusal. Input tools
  (press_key/scroll/hotkey) hand-author schemas that accept
  `delivery_mode`; invoke_menu uses the strict contract.
- Fix: the invoke_menu draft args now send exactly `path` (+ loop-
  stamped pid/window_id/session). No driver change, no contract change —
  caller-side args now match the pinned schema.
- Verification: 92 DriveLoop+JevChooser tests green; menu real-app
  rerun pending on the D82 stage.
- Harness note (not a source change): the keys-case goal was rephrased
  state-led — "Clear the calculator display to zero using the escape
  key." The action-led phrasing ("Press the escape key to clear…")
  verified the effect but could never produce done evidence — no screen
  fact can establish that escape was pressed, so the goal_fact check
  found supportedFacts=0 and completion hovered .7-.83. State-led
  phrasing puts the postcondition ("display = zero") in bindable terms;
  with it the keys run went 3/3 strict done+verified at ~2.2-2.6s.
  This is a general action-goal verification limitation worth a real
  fix later (actuation facts as goal evidence), not hidden.

## Addendum 46 — D83 view_change goal kind for mode/layout outcomes (self-review, same quota caveat)

Scope reviewed: `VisualGoalProof.swift`, `JevVisualDecision.swift`,
`jev-everyday-apps.py` (harness goal phrasing).

- Live menu-case failure (calculator.menu-* 0/6 blocked+verified): the
  invoke_menu fix lands — every run dispatches `menu:View > X` at
  .91-.98 and the oracle confirms the mode change (verified=True). The
  task still settles blocked: no observed-goal FACT can bind the
  outcome (Calculator's new buttons are AXButtons — outside the
  value/label fact roles), and the visual goal path classifies the
  outcome `kind=navigation` at kindP .57-.78 while `kind_supported`
  in verify wobbles .16-.54 — never reaching a verified settle.
- Root cause: the VisualGoalKind taxonomy has no case for an
  in-place view/mode/layout change — `navigation` requires a new
  destination, `local_control` the acted-on control's own state,
  `status`/`exact_text` don't fit. The model honestly scores
  kind_supported low because a mode switch isn't navigation.
- Fix: new `view_change` kind — "the same window or surface now shows
  the different view, mode or set of controls the goal asked for".
  The kind picker and the verifier's `kind_supported` criterion both
  read the case's own proofCriterion, so classification and scoring
  align on a kind that actually fits menu/view/layout outcomes.
- Verification: full suite 1375 green (the allCases-criteria test
  covers the new case automatically); menu real-app rerun pending on
  the D83 stage.

## Addendum 47 — D84 evidence routing for fact-less outcomes (self-review, same quota caveat)

Scope reviewed: `JevDecider.swift`.

- Live menu-case failure on D83 (0/6 blocked+verified): `view_change`
  classifies decisively (kindP .88-.99) but two shapes still starve the
  visual lane. Scientific legs: the decider re-picks `menu:View >
  Scientific` 2-3 times after it already actuated (completion .43-.72,
  doneVote never fires, no fact binds — buttons aren't facts), burns
  rounds, stales. Basic legs: pixels engage only via the
  all-supports-low fallback, presence draws .33-.64.
- Root cause: nothing routes "the outcome probably happened but AX
  can't prove it" to the visual lane. doneVote-without-fact falls to a
  bare `decide(done)` the evidence gate rejects; confident repeat picks
  re-dispatch the same tool blind.
- Fix (two routes, both → `requestPixels(observation)` — unbound, so
  the visual lane adjudicates goal evidence and may still re-issue the
  step):
  1. doneVote with empty successContains and no bound goalFact — the
     claim gets visual adjudication instead of an evidence rejection.
  2. A re-picked `.tool` candidate with `element == nil` whose summary
     already appears actuated in history — a repeat key/menu/scroll
     pick is the decider saying it can't confirm the effect; visual
     check before any blind repeat. Element picks keep repeat
     semantics ("Add" twice is legitimate); `request` effect != .tool
     and absent visualChoose fall through unchanged.
- Verification: 168 DriveLoop/JevChooser/JevVision tests green; menu
  real-app rerun pending on the D84 stage.

## Addendum 46 (D85 — identifier facts from tree_markdown)

- Driver emits AXIdentifier only inside `tree_markdown` `[id=…]`
  tokens; the elements array never carries it. Toolbars/status controls
  encode live state there — Calculator's toolbar Mode button reads
  `Mode: scientific; unitConversion: false` / `Mode: basic; …` — the
  only native signal distinguishing its views (AX buttons expose no
  mode fact; both modes verified by direct inspect).
- `ObservedGoalProof.markdownIdentifiers` parses `id=` tokens into an
  element-index → identifier map; `facts(in:)` emits a new
  `.identifier` fact kind (content = the identifier, node keeps the
  real label) only when the identifier carries state shape
  (`:`/`;`/`=`). Name-duplicate ids (`Seven`, `main`,
  `calculator.fill`) are filtered — no fact-set noise.
- Flow: identifier facts land in `goal_facts` → the done-vote's
  `goal_fact` pick can bind "Scientific/Basic view" natively;
  `TaskLoop.successEvidence` also sees them via fact content. All
  thresholds unchanged — evidence availability widened, gates intact.
- Verification: 19 ObservedGoal tests + 204 focused
  (DriveLoop/JevChooser/JevDecider/JevVision) green, including
  `testStateBearingIdentifierBecomesOutcomeEvidence`; menu real-app
  rerun pending on the D85 stage.

## Addendum 47 (D86 — scoped tree_markdown keeps id tokens)

- D85's identifier facts never fired live: `axSnapshot(from:)` blanks
  `tree_markdown` whenever it scope-filters elements to the window
  subtree (always true — menubar rows exist), so `markdownIdentifiers`
  saw `""`. The D85 `facts=1/2` were native read-only elements, not
  identifier facts.
- `DriveCandidates.scopedTreeMarkdown` now rebuilds the markdown from
  rows whose `[N]` index survives the same `allowed` set used for
  elements — menubar rows drop, window-descendant `id=` tokens stay.
  The Mode button's `Mode: scientific|basic` identifier now reaches
  `goal_facts` in the real scoped path.
- `treeMarkdown` feeds only `successEvidence` and fact extraction —
  it is not in the infer context — so the change is additive.
- Verification: 1376 tests, 0 failures; menu rerun pending on D86.

## Addendum 48 (D87 — identifier fact guidance)

- Identifier facts reached `goal_facts` live (facts=3 scientific /
  facts=2 basic incl. `Mode: …`) yet `supportedFacts` stayed 0: the
  evidence guidance taught `value` facts only, so the model discounted
  the unknown `identifier` kind.
- `valueEvidenceGuidance` gains one line: an identifier fact is the
  control's observed accessibility identifier carrying live
  toolbar/mode/selection state in `observed`. Gates unchanged.
- Verification: 147 focused tests green; menu rerun pending on D87.

## Addendum 49 (D88 — method/state evidence composition)

- Live runs still show `supportedFacts=0` on `Mode: basic` (draws
  .5-.84): `goal_support`/`goal_complete` ask one fact to prove the
  ENTIRE outcome — including the "using menu" method clause no state
  fact can attest. Keys bound anyway (display=0 is unambiguous); the
  toolbar-identifier indirection underperforms.
- `valueEvidenceGuidance` now states the honest composition: the
  recorded `recent_steps` establish how the outcome was reached; an
  outcome fact need only establish the resulting state. Applies to all
  action+state goals; thresholds unchanged.
- Harness: menu goals rephrased to the app's own AX vocabulary
  ("Switch the calculator to Scientific/Basic mode using menu
  View > …") aligning with `Mode: scientific|basic` identifiers.
- Verification: 147 focused tests green; menu rerun pending on D88.

## Addendum 50 (D89 — identifier-as-state declaration guidance)

- D88 evidence: `supportedFacts=1` now fires on basic legs
  (`completion=.83-.88 supportedFacts=1`) — identifier support crossed
  the .9 bar; the residual gap is `goal_complete` drawing .83-.93 vs
  the .95 threshold. The model lacks the semantic bridge that
  `name: value` inside an AX identifier declares the element's
  current named state.
- `valueEvidenceGuidance` gains the declaration reading: "an
  `observed` of the form `name: value` declares the element's current
  named state." Honest AX semantics; thresholds unchanged.
- Verification: 147 focused tests green; menu rerun pending on D89.

## Addendum 51 (D89 — declared postconditions close the menu case)

- The deterministic lane already existed: `JevDecider` emits `.done`
  when `TaskLoop.successEvidence` matches `success_contains` against
  the current snapshot, and the settle needs only a prior verified
  dispatch. The gap was that the harness never declared the
  postcondition — the model was left to adjudicate `Mode: basic`
  semantics it could not fully confirm.
- Harness only: menu cases now declare `success_contains`
  `["Mode: scientific"]`/`["Mode: basic"]` (the app's own AX
  identifier vocabulary, surfaced as identifier-fact content) and
  `drive()` forwards `success_contains` into the drive request.
  No product source change; the observed-goal fact path is
  deliberately off for these cases (`success_contains` is the
  stronger evidence class).
- Live D89 result: menu 6/6 `done` + oracle `verified=True`,
  strict_success on every leg, 1.75-2.5s per leg (was 3-13s blocked).
  Evidence: `native-d89-menu-r2`.

## Addendum 52 (D90 — scroll is incremental, not possibly-completed)

- D84's repeat-pick rule routed any re-picked target-less action to
  scoped pixels. For menus/keys that stays right — an idempotent
  re-pick means the decider can't confirm the effect. A re-picked
  `scroll` is different: each dispatch is incremental progress and the
  declared postcondition/stale stop still bound it, so the rule now
  exempts `scroll`.
- The scroll qualification itself was rewritten: the Safari+Wikipedia
  fixture needed a full Jev navigation leg (URL entry) as SETUP,
  which fails on its own merits. The case now loads a local tall HTML
  fixture through direct driver calls (`set_value` + `press_key` —
  same class as the keys case's raw seed click) and asks Jev to
  scroll-and-seek a marker that only enters the virtualized web tree
  after scrolling — declared via `success_contains`, an honest
  observable postcondition.
- Tests: `JevDeciderTests` gains a pair — re-picked scroll repeats;
  re-picked menu still routes to pixels. 130 focused tests green.

## Addendum 53 (D91 — the pick context fits the model, scroll proves via pixels)

- r6/r7 evidence settled two questions about scroll proof. Safari
  exposes the whole rendered DOM in the AX tree — text markers appear
  without any scroll (r6 after-0: bar stayed 0 while "Privacy policy"
  materialized as render completed), so no tree fact or
  `success_contains` can honestly postcondition a scroll there. And
  `max_tokens_exceeded` on the FIRST pick call shows the real defect:
  `observed_content`/`screen_values`/`_goal_facts`/candidate options
  were all unbounded — Calculator-sized windows fit the judgment
  model's context, real windows did not.
- `DriveCandidates.observationFields` now bounds `observed_content`
  at 140 rows: candidate elements always kept, remaining slots filled
  by goal-relevance score in document order, tail honestly marked
  "… N more on-screen elements not listed". `screen_values` draws from
  the same kept set.
- `ObservedGoalProof.choiceState` exposes at most 120 `_goal_facts`
  with a `_goal_facts_omitted` count; local fact computation and
  `successEvidence` still see the full set.
- `DriveLoop.Config.elementCap` = 40 (was nil): element candidates are
  score-ordered, so the top-40 survives; reserved picks (scroll, keys,
  done…) are appended after the cap. `maxRounds` and `browserRefCap`
  stay nil — this bounds context, not steps.
- The scroll case was rewritten for pixel-lane proof: a bounded local
  fixture (~100 lines) whose marker is a LINK label — links carry
  AXPress so the marker can never become a fact — and the goal asserts
  on-screen visibility only the visual verifier can confirm. Oracle
  = scrollbar value delta, independent movement proof.
- Tests: observation truncation test added; step-ceiling test now pins
  the elementCap=40 context bound explicitly. 87 focused tests green.
- Verification: scroll rerun pending on D91.

## Addendum 54 (D92 — the fan-out is the payload: bounded questions, measured)

- Offline measurement (JevChooserTests.testBrowserScalePickRequestFitsContext)
  proved the request shape: a 600-element window produced 357KB — 267KB
  of it QUESTIONS, because action_support fans out per candidate and
  goal_support per fact, and goal_fact criteria re-serialize every fact.
- Bounds now: goal-fact binding offers the 24 most goal-relevant facts
  (relevance = goal-word overlap on label+observed; a fact outside the
  set simply can't be selected — never fabricated); elementCap 40→24;
  refineGoal receives the same capped fact set. Same fixture now
  measures state=38.6KB questions=55KB total=94KB (3.8x smaller).
- Permanent instrumentation: the chooser logs
  "pick request size state=…B questions=…B count=…" before each infer
  call so future oversize reports carry real numbers.
- Tests: 88 focused green including the measurement test.
- Verification: scroll rerun pending on D92.

## Addendum 55 (D93 — scroll targets classify as scroll regions)

- D92 evidence: the bounded request now reaches the model (state=54KB,
  questions=122KB, count=61 — answers returned). The loop then blocked
  inside the visual lane: the proposed scroll_down drew selectedP .89-.96
  but the `control` classification could only answer `ordinary` at
  .41-.74 — the taxonomy has no class for a scroll surface ("ordinary"
  is defined as a push button, which a web area is not).
- `VisualControl.scroll_region` added: "a scrollable content region,
  document view or web/canvas area a scroll/pan moves through — no
  commit consequence." Same fix class as `view_change` for outcomes:
  the taxonomy gains an honest answer instead of forcing a bad fit.
  Benign for `hardViolation` (only credential/unknown violate) and for
  `judgmentsValid`'s protected check (scrollRegion.protected = false).
- Tests: 164 focused green.
- Verification: scroll rerun pending on D93.

## Addendum 56 (D94 — scroll questions and visible-bounds crops)

- D93 evidence: `control=scroll_region` now classifies decisively, but the
  pixel gate still missed presence=.01-.55, located=.04-.44,
  authorized=.10-.76 — all click-shaped questions. A scroll's referent is
  the region it moves through: the sought content is absent *because*
  scrolling must reveal it, and ordinary page text under the pointer is
  the surface, not a mislocated target. `target_present`, `located` and
  `authorized` now carry scroll-operation phrasing; thresholds unchanged.
- The grounded-native lane never engaged: the AXWebArea candidate was
  enumerated (`candidates=1`) but no `native_*` questions were emitted
  (grounded call = exactly the 14-question pixel set). Root cause:
  `nativePicture` was asked for the element's unclamped AX frame and
  throws unless the window bounds fully contain it — viewport-spanning
  elements fail every time. Both crop sites now use the already-computed
  visible intersection; the provenance claim (faithful crop at captured
  native bounds) still holds.
- Tests: 107 focused green.
- Verification: scroll rerun pending on D94.

## Addendum 57 (D95 — scene-covering crop dedup + scroll control phrasing)

- D94 evidence: the clamped crop worked but exposed a token regression —
  an AXWebArea's near-full-frame crop now ships alongside current_image,
  previous_image and subject_reference, pushing decide-2's primary call
  to max_tokens_exceeded. Fix: `sceneCovering` — an element whose visible
  bounds cover >=90% of the captured frame counts as pictured by
  current_image itself; the redundant full-frame crop is never attached.
  Full question sets still emit (candidate bounds already say the element
  fills the scene). Both lanes covered.
- `control` stayed a borderline choice (.67-.76 < .9) that the noul-only
  redraw cannot revisit: for scroll ops the instruction now says the
  target is the region the scroll moves through — classify the region,
  not the content inside it.
- Tests: 95 focused green.
- Verification: scroll rerun pending on D95.

## Addendum 58 (D96 — advisory proposals yield to the verified operation)

- D95 evidence: the AX pick kept choosing element_104 — the SEEK-MARKER-77
  anchor itself — with tool=click at selectedP .43-.79, always under the
  action floor. Every `requestPixels(candidate:)` site binds a rejected
  pick's best guess as `semantic_proposal`; the bound `operation` verify
  then drew .08-.12 (the visual model distrusts a link-click that can
  navigate away) but was diagnostic-only — `resolved=bound` was
  unconditional, so each visual round burned a grounded call proving a
  click nobody believed, then the pick re-issued the same guess.
- `JevActionProposal.advisory`: proposals seeded from under-floor picks
  are advisory — `permits` still enforces literal/key identity exactly,
  but the operation may be overridden when the proposal's own verify
  rejects it.
- Bound primaries now emit `operation_alternative`, an independent op
  pick asked alongside the verify noul. Resolution: verify >= .5 keeps
  the bound op (accepted guess, existing behavior — the
  `testD16VisualFallbackRetainsTheNativeOperation` contract is
  preserved); verify < .5 + alternative decisive (>= .7) resolves the
  alternative — a verify-rejected guess yields to what the visual model
  actually picked; anything indecisive stays unverifiable rather than
  guessing.
- `proposalBound` is recomputed after resolution so an overridden
  proposal no longer binds the grounded wording — scroll resolves ask
  region/operation questions, not the rejected click's "exact target".
- Tests: 371 focused green including
  `testD95VerifyRejectedAdvisoryResolvesThePickedOperation` (bound click
  verify .2 + alternative scroll_down .99 dispatches a scroll).
- Verification: scroll rerun pending on D96.

## Addendum 59 (D97 — confirmed-guess bar for bound verify)

- D96 evidence: the advisory override worked — after-1's bound click
  drew verifyP=.05, the independent pick resolved scroll_down, and a
  real scroll dispatched (scrollbar 0 -> .085, verified=true). The rep
  still blocked because the NEXT under-floor click guess drew
  verifyP=.68 — under the old >=.5 bound-acceptance bar that marginal
  draw bound the operation again, and the grounded click on a page-wide
  box failed presence=.02 (the marker link is off-screen and cannot be
  boxed as a click control).
- Bound acceptance now requires a confirmed verify (>=.9, the same bar
  class the grounding judgments use). Below it, the independent
  operation pick resolves when decisive (>=.7); indecisive middles stay
  unverifiable rather than letting a plausible-but-unconfirmed guess
  hard-bind the round. A missing verify draw also defers to the
  alternative instead of silently confirming the guess.
- Contract preserved: testD16VisualFallbackRetainsTheNativeOperation
  still retains a .99-verified bound click; the new
  testD95VerifyRejectedAdvisoryResolvesThePickedOperation covers the
  override path.
- Tests: focused green.
- Verification: scroll rerun pending on D97.

## Addendum 60 (D98 — incremental authorization for scrolls)

- D97 evidence: the confirmed-guess bar worked — bound clicks now resolve
  to scroll_down and a second real scroll dispatched (after-2,
  verified=true, scrollbar 0 -> .085). The new recurring gate miss was
  `authorized`: .96 on the pre-scroll round, then .23/.21 after a scroll
  landed in `history`. The scroll `authorized` text said "answer no if
  the step already completed in `history`" — a correct rule for
  one-shot actions, but a scroll is incremental: repeating it while the
  sought content stays off-screen is exactly what the goal needs, and
  the model read the mechanical step's presence in history as
  completion.
- The scroll authorization text now says a scroll may repeat while the
  sought content is still unseen; only visible outcome evidence
  completes the goal (judged separately by `goal_evidence`). It still
  denies when the goal names a different operation/region, and newly
  denies when the sought content is already visible — an honest stop
  condition, not a weaker gate.
- Verification: scroll rerun pending on D98.

## Addendum 61 (D99 — off-screen state is not screen evidence; verify picks reobserve)

- D98-r2 evidence: no grounded call needed to see the next defect —
  `goal_evidence presence` drew .55-.89 on rounds where the marker had
  never rendered (screenshot confirms it sits ~80 lines below the fold).
  The AX snapshot exposes the full DOM, so `observed_content` always
  contains the marker link's row; the model conflated "the text exists
  in state" with "the evidence is on screen", which also primed `verify`
  op picks (.52-.92) that hard-blocked runs.
- `goal_evidence` now states the rule explicitly: element rows can
  describe content that is not rendered on screen — text or a control
  listed there but not visibly rendered in the picture is not evidence.
  True for every real page whose AX tree exposes off-screen DOM.
- A `verify` op pick now returns `unverifiable()` (bounded reobserve)
  instead of an immediate `blocked` — a completion claim cannot actuate,
  so the decider's done lanes get the next-cycle re-judgment on fresh
  evidence rather than one contaminated pick ending the row.
- Harness: the fixture's page title no longer carries the `77` marker
  token (the tab title was priming `exact_text` evidence); the window
  matcher follows the new title.
- Tests: 77 JevVisionTests green.
- Verification: scroll rerun pending on D99.

## Addendum 62 (D100 — borderline control classifications get the redraw)

- D99 evidence: `goal_evidence` is honest now (.00-.43 with the
  off-screen clause, was .89). A real scroll dispatched again on after-1
  (authorized=.97). The next exact gate: `control pick=scroll_region
  p=0.89` — a borderline *choice* draw under the .9 bar that the
  confirmatory redraw could never revisit because it only re-asked
  nouls. Known gap since the D94 notes; the scroll surface kept landing
  on it.
- The borderline scan now re-asks `control` classifications drawn in
  (.70..<.90) in the same single redraw request — same question, fresh
  draw, gate bar unchanged. The merge path replaces the whole answer so
  redrawn distributions reach the gate identically.
- Harness: fixture shortened to 45 lines (the marker still starts
  below the fold, ~5 scrolls to reach instead of ~12 — a real
  scroll-and-seek, not a 12-round dice chain), and each rep now closes
  the fixture tab it opened so stale tabs stop inflating later
  snapshots.
- Tests: 115 focused green.
- Verification: scroll rerun pending on D100.

## Addendum 63 (D101 — scroll displacement is produced change, not a new subject)

- D100 evidence: two reps reached scrollbar .51 — six clean dispatches
  through every safety gate. Two residual blockers: `subject=0.86`
  gate-miss (the continuity draw hedged on page content that only moved
  because earlier authorized scrolls displaced it) and `verify` op picks
  at .73-.93 (the goal text "scroll down until X is visible" reads as
  completable by the first scroll).
- `subject_preserved` now names a scroll's shifted page content among
  expected produced changes — a window that only scrolled is still the
  original subject.
- Harness goal text now states the marker starts off-screen and
  scrolling is the only way to reveal it — honest goal phrasing a user
  would give, which makes "already done" readings false rather than
  plausible.
- Tests: 77 JevVisionTests green.
- Verification: scroll rerun pending on D101.

## Addendum 64 (D102 — scroll target box is the content area, not the chrome)

- D101 evidence: gates now mostly clear (`presence .93-.99`,
  `authorized .16-.97`) but `located` still wobbled .55-.98 and
  `subject` missed once at .93. Trace showed `target_box` draws
  spanning `right=0.99-1.00` — the full window width including the
  scrollbar gutter — and the model hedged on whether that box is the
  scroll region. The scroll lands on the box center, so a
  chrome-inclusive box is both ambiguous and a worse pointer position.
- `target_box` now names the scroll case: for a scroll or pan, the box
  is the scrollable content area inside its edges — not including
  scrollbars, tab bars, window chrome or overlays — because the scroll
  acts where the center lands. Question wording only; every gate bar
  unchanged.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D102.

## Addendum 65 (D103 — tree facts are not rendered evidence; page-unit scrolls)

- D102 evidence: the scroll-box wording landed — `located` draws moved
  to .90-.97 and two reps dispatched real scrolls (bar 0→.25 and
  0→.76). New worst defect: after-0 returned `already` in 1.5s with
  `false_done` — the `<p id>` wrapper exposes its accessible label =
  marker text, a `label:` fact the model bound at ≥.9 as goal proof.
  A tree fact attests content exists in the accessibility tree, not
  that it is rendered in the visible viewport.
- `valueEvidenceGuidance` now states exactly that distinction for
  `goal_fact`/`goal_support`/`goal_complete` draws: the tree can
  describe off-screen content, so a fact alone cannot satisfy a goal
  that requires visible rendering — field-value facts still attest
  their field's state.
- D102's residual `authorized`/`located` misses were per-round variance
  against ~9 required dispatches. Both scroll emitters (visual
  `VisualTarget.request` and the AX `scroll:*` draft) now dispatch the
  driver's designed `by:"page"` unit at amount 1 (~600px wheel delta vs
  360px) — a page-step is the natural "keep scrolling until" increment
  and cuts the gated-round chain ~3×. Every gate bar unchanged.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D103.

## Addendum 66 (D104 — authorized draws need the tree-vs-rendered distinction too)

- D103 evidence: the false_done class is gone (`blocked`, never
  `already`) and page-unit scrolls moved the bar .42 in two
  dispatches. Residual: `authorized` collapsed to .18-.59 on several
  grounded rounds — the model reads the sought link's row in
  `observed_content` and hedges on whether the content already
  rendered, since tree rows describe off-screen elements too. Same
  misread class as the fixed `goal_evidence` question; after-2's run
  ended on a network timeout, an infrastructure flake, not a gate.
- The scroll `authorized` question now carries the same distinction:
  element rows in observed state can describe off-screen content —
  the sought content appearing there is not evidence it is rendered;
  only the picture shows that. Gate bar unchanged.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D104.

## Addendum 67 (D105 — history names the rejected hypothesis)

- D104 evidence: two reps dispatched real page scrolls (bar .42 and
  .85 — after-2 ended one scroll short of the page bottom where the
  marker lives). Residual waste: every other decide burned a full
  grounded call on the bound `click` proposal for the marker link —
  its verify draw rejects it every round (an unknown link click is
  correctly untrusted), yet the next AX pick re-proposes the same
  click because `recent_steps` only said "requesting scoped visual
  evidence", never what the visual check disproved.
- The reobserve summary written after a bound hypothesis fails now
  names it — "...requesting scoped visual evidence — the scoped
  check did not confirm the proposed click on \"X\"" — so the next
  pick can weigh real evidence instead of repeating the guess.
  `JevActionProposal.summaryDescription` exposes the operation and
  target label for that note. No gate, bound or suppression changed —
  a hypothesis stays eligible; the model just gets to learn.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D105.

## Addendum 68 (D106 — verify op description names its real precondition)

- D105 evidence: all three reps blocked fast with zero dispatches.
  after-1's decisive failure: the unbound operation pick drew
  `verify` at .92/.95 — but `verify` can never actuate (the resolver
  maps it to unverifiable), and its own `goal_evidence` draw in the
  same call said not-done. The op description read "independently
  verify it without input", which the model used as a no-cost hedge
  whenever it was unsure. Removing `verify` from the criteria broke
  the answer domain (response validation requires answered ids ⊆
  criteria — 43 vision tests rejected answers naming it), so the id
  stays answerable.
- The `verify` criterion now states its real precondition: pickable
  only when the outcome is already visibly complete and this call's
  goal_evidence is confidently yes — it performs no action itself,
  and a not-yet-proven outcome needs a concrete operation. The done
  path (goal_evidence ≥ .9 + box + admissible kind) already fires
  before the op resolve, so an honest verify pick is unreachable —
  the description just stops it being a hedge magnet. Gate bars,
  resolver behavior, and `none` unchanged.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D106.

## Addendum 69 (D107 — visibility goals get an honest kind)

- D106 evidence: after-2 completed the real arc — two gated
  scroll_down dispatches, the marker rendered, goal_evidence .98,
  verifyState fired — then the fresh-frame verify died on
  `same_subject:.90` (redrawn, still .90) with `kind_supported:.68`
  and `exact_required:.32` queued behind it. Root cause is
  structural, not variance: the kind pick chose `exact_text`
  because the goal names a literal, but `VerifiedVisualGoal`'s
  exact clause makes pixel-only exact_text unverifiable — it
  requires `native_literal_evidence`, which a visibility goal
  never has. `view_change` is the honest kind for "named content
  rendered on screen" but its criterion read as view/mode
  switching only, so the model never picked it for reveal goals.
- `view_change` now covers "named content scrolled or revealed
  into view — the shown content itself is the evidence" in both
  the pick criterion and `proofCriterion` (so `kind_supported`
  judges the same definition). `exact_required` now distinguishes
  byte-exact requirements (typed text, checksum, a specific value)
  from a named link or label that must simply be VISIBLE — the
  latter is pixel-provable and answers low. `same_subject` names
  scrolled/revealed page content as produced progress, mirroring
  the subject_preserved fix. Outcome bars untouched: completed
  and evidence_visible still gate at .95; the marker must be
  visibly rendered, and off-screen AX rows still cannot prove it.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D107.

## Addendum 70 (D108 — a rejected verify pick teaches the next primary)

- D107 evidence: `view_change` now wins the kind pick (kindP
  .72-.95) and goal_evidence stays honest (.01-.38 while the
  marker is off-screen). New dominant waste: `verify` op picks at
  .56-.94 after scroll rounds — the model treats verify as a
  progress check while its own goal_evidence in the SAME call
  says the outcome is not complete. It cannot cross-correlate
  its own answers, and three chained unverifiables still end the
  run.
- The answer-domain stays intact (`verify` remains pickable —
  criteria must cover every answerable id or response validation
  rejects the call). Instead the session now records when an
  unbound op pick selects `verify` and injects
  `rejected_completion_claim` into the NEXT primary's state —
  the same feedback channel `unactuated_proposal` already uses.
  The note names the contradiction: that call's own goal_evidence
  judged the outcome incomplete, so choose a concrete operation.
  It clears after one injection and re-records if verify is
  picked again. Bound-proposal verify nouls are untouched (a noul
  is a hypothesis check, not the trap), `none` stays an honest
  refusal, and no gate or retry bound moved.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D108.

## Addendum 71 (D109 — rejection notes name the outcome's status)

- D108 evidence: one scroll dispatched (network timeout ended
  after-0 early — infrastructure, not a gate). after-1 chained
  bound-click reject → verify .80 → verify .55 into three
  unverifiables; after-2 same shape. The `rejected_completion_claim`
  state note went in after the first verify pick but the model
  still drew verify again — a state note doesn't dominate a pick
  whose reading was already set by recent_steps. The verify-pick
  surge traces to the D105 rejection note: "the scoped check did
  not confirm the proposed click" reads as "maybe the outcome is
  already there → verify".
- The retry summary now states the provable second half: "…did not
  confirm the proposed X — and the outcome was not yet visibly
  complete". Provable because reaching the unverifiable path at
  all means that call's goal_evidence stayed under the done bar —
  the done lane (evidence ≥ .9 + box + admissible kind) always
  fires earlier. The model sees the goal is still unmet before it
  can reinterpret a rejected click as completion. No bar, gate or
  retry bound changed.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D109.

## Addendum 72 (D110 — twice-disproven hypotheses stop being bound)

- D109 evidence: verify picks collapsed to one total across three
  reps (was 3-4 per rep) — the outcome clause works. The remaining
  round-burner: every rep still spends 1-2 decides on the bound
  `click on SEEK-MARKER-77` hypothesis — the AX pick re-seeds it
  each round (element_104 is the only named pressable), the verify
  draw rejects it every round (.01-.52 — correctly: an unknown
  link click is untrusted). Marginal subject/authorized draws then
  finish the reps.
- `JevDecider.rejectedHypotheses` now counts (operation, target)
  hypotheses the scoped check disproved. On the third identical
  proposal the pick's guess is no longer BOUND as
  `semantic_proposal` — the decide runs unbound, where the model
  has always picked scroll_down anyway. Nothing is suppressed:
  the element stays visible to the open lane, `click` stays in
  the op vocabulary, and a genuinely different proposal still
  binds on first sight. The retry note in recent_steps is
  unchanged, so the disproof remains readable history.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D110.

## Addendum 73 (D111 — claim budget split; retry budget becomes consecutive)

- D110 evidence: the twice-disproven-hypothesis guard works but could
  not save the reps — each died on 3 unverifiables before any
  hypothesis was re-proposed. Trace analysis found the deeper defect:
  `visualRetries` never reset between dispatches — it counted
  CUMULATIVE misses across the whole task, so a ~10-dispatch scroll
  goal had a lifetime error budget of 3 marginal draws. Combined with
  `verify` picks consuming the same budget (2 of 3 reps died on claim
  dead-ends), long-horizon goals were nearly unwinnable.
- `JevVisualDecision`: a `verify` operation pick now returns a
  distinct `completionClaimVisualReason`. The pick is semantically an
  observation request — the done lane fires earlier when its own
  goal_evidence clears — so it is not a grounding failure.
- `JevDecider`: `verifyClaims` bounds consecutive completion claims
  (2 free re-observes; a third claim with no intervening concrete
  result terminates honestly). `visualRetries` now resets on a
  successful dispatch — the budget bounds consecutive unproductive
  misses as its comment always described, rather than acting as a
  per-task cumulative cap. Claim streaks also reset on any non-claim
  result; the retry note names the claim truthfully.
- No gate, threshold, or answer domain changed.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D111.

## Addendum 74 (D112 — byte-hash subject proof + op-pick redraw; fixture made honest)

- D111 evidence: the consecutive-retry + claim-lane changes doubled
  grounded attempts per rep (2-3 vs 1). Residual killers are genuine
  marginal draws: `subject` 0.88-0.90 and `authorized` 0.42-0.90.
- `VisualFrame.imageHash` now code-proves subject continuity when the
  anchor and current capture are byte-identical — identical pixels
  cannot depict different subjects. `subjectValid` accepts the hash as
  proof that dominates any drawn hedge; `decide` skips emitting
  `subject_preserved` entirely on identical bytes. This removes a
  whole miss class on static screens between retries.
- A borderline unbound primary `operation` pick (.55-.70) now earns
  the same bounded single-question redraw the grounded lane gives
  borderline judgments — the .7 resolve bar is unchanged. The D110
  run showed scroll_down drawing .64-.68 and dying under the bar.
- Fixture honesty fix: `.switchBeforeNextInput`, `.driftingSubject`,
  and `.actionThenForeignGoal` declared different subjects on
  byte-identical frames — a contradiction the hash proof rightly
  exposed. Their different-subject frames now carry distinct marker
  bytes so simulated subject changes actually differ on screen.
- Caught by the suite before staging: `staticDespiteProgressVote`'s
  identical frames proved the hash path end-to-end.
- No gate, threshold, or answer domain changed.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D112.

## Addendum 75 (D113 — scroll authorized gets the full unstable-band redraw)

- D112 evidence: the byte-hash subject proof eliminated every
  subject miss (zero this run vs .88-.90 in D111) and the op-pick
  redraw fired honestly. after-0 dispatched a verified scroll.
  The residual killer is `authorized` on scrolls: the same
  commanded scroll draws .43-.99 across calls within a rep.
  Draws at .43-.64 sat BELOW the .70 borderline band and got no
  second look while .89 got one — treating proven-unstable draws
  as decisive.
- The grounded redraw now covers `.25..<0.95` for `authorized`
  specifically under scroll operations — the same bounded single
  redraw, the .95 gate unmoved. Other operations keep the
  standard .70 band; deny/protected keep the violation-side band.
- No gate, threshold, or answer domain changed.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D113.

## Addendum 76 (D114 — retry bound sized to the real deadline)

- D113 evidence: the op redraw rescued a verify pick (.62 ->
  scroll_down .99) and the wide authorized redraw fired, but
  scroll `authorized` draws .42-.64 post-redraw — genuine model
  distrust of the question shape, not noise around the bar.
  Reps still died in 7-19s against a 30s caller deadline:
  `maxVisualRetries=2` ended runs with 12+s of honest budget
  unused.
- `maxVisualRetries` is now 3 — a liveness policy, not a gate.
  Every attempt still faces the full grounding gates; the caller
  deadline remains the real bound on total churn.
- Fixture rounds updated for the new bound: `switchBeforeNextInput`
  needs a fourth consecutive unverifiable before blocked, so its
  task gets maxRounds=5. The subject gate assertion (inputs==1)
  held throughout.
- No gate, threshold, or answer domain changed.
- Tests: 371 focused decision-consumer tests green.
- Verification: scroll rerun pending on D114.

## Addendum 77 (D115 — scroll authorized reframed as a match-check)

- D114 evidence: maxVisualRetries=3 gave reps more grounded
  chances but `authorized` on scroll_region drew .49-.93 across
  8 grounded calls — a tight ~.75 cluster, never reaching the
  .95 judgmentsValid bar even post-redraw. Not noise: the model
  systematically hedges the open judgment call, folding residual
  safety-caution into a question whose safety content is
  already covered by protected/deny/control elsewhere in the
  same call.
- The click lane already encodes the honest version: when the
  referent judgment names "the control the caller wants",
  authorization is code-derived. For scrolls the caller's goal
  text literally commands the operation — `authorizedText` for
  scrolls is now phrased as the verifiable match-check it is
  (does the goal ask for this operation+direction on this
  region while the sought content is still off-screen), and
  explicitly defers harm/protected/denial to the other
  questions.
- Same .95 bar, same answer-no clauses, same gate. Only the
  question shape changed.
- Tests: 371 green.

## Addendum 78 (D116 — observed_content labeled as tree rows)

- D115 evidence: the match-check reframe lifted `authorized`
  draws (.50->.90, trending toward the bar) but `goal_evidence`
  inflated to .55-.93 in two reps — the model read the marker's
  accessibility row as rendered evidence. Screenshots confirm
  the marker was off-screen (bar_after=0, fill lines 000-018).
- Root cause unifying the residual failures: `observed_content`
  presents AX tree enumerations under a name asserting
  on-screen presence ("N more on-screen elements"). Off-screen
  rows (the marker link) sit in it because Safari reports
  intersecting frames for scrolled-off DOM content — no
  reliable rendered flag exists in the AX layer. The priming
  poisons `goal_evidence` directly and `authorized` indirectly
  (the "content still off-screen" clause reads as maybe-false).
- Fix at the data site, not another question: the field now
  opens with "Element rows from this window's accessibility
  tree — a row can name content scrolled out of view; only the
  picture shows what is rendered." and the overflow line says
  "element rows" instead of "on-screen elements". Every
  consumer (goal_evidence, authorized, op pick, open match,
  main AX pick) reads the caveat beside the rows.
- No key rename (frozen field), no bar moved, no rows removed —
  same information, honestly labeled.
- Tests: 371 green.

## Addendum 79 (D117 — scroll located proven by container geometry)

- D116 evidence: after-0 scrolled bar 0->.849 then died on
  `located` collapse (.98->.22 across consecutive scrolls) —
  pure model variance on a geometry question. after-2 reached
  bar=1.0 (marker found, goal_evidence .98/.97/.99) and was
  cut by the 30s caller deadline mid-settle. The
  observed_content label fix killed the tree priming:
  goal_evidence stayed .00-.08 while the marker was off-screen.
- For scroll ops `VisualNativeElement.candidates` already
  filters snapshot elements to scrolling-container roles
  (AXScrollArea/AXWebArea/AXTable/AXOutline/AXList/AXBrowser)
  whose frames CONTAIN the actuation point — a non-empty
  candidate set is code-verified proof the point lands inside
  a scrolling region. `located` for scrolls is now 1 when that
  geometric proof exists; the model draw is skipped, not
  overruled. Control classification (.9), presence, authorized
  (.95), protected/deny, and subject gates all still draw and
  gate independently.
- Same proof class as nativeElement->location=1 and
  imageHash->subject. Pixel/clicks unchanged.
- Tests: 371 green.

## Addendum 80 (D118 — verify streak bound sized for real tasks)

- D117-r1 evidence: both verified reps scrolled bar 0->1.0 with
  `located=1.0` on every grounded call — the container-geometry
  proof eliminated that miss class. Both were `cancelled` at
  the 30s harness wait mid-settle; r2 (45s per-case deadline)
  removed deadline cancellation but two reps died on the
  3-claim verify bound: the model picks `verify` at .69-.95
  while its own goal_evidence says .03-.54, a hedge pick whose
  real meaning is "look again" — exactly what the retry loop
  does.
- The claim machinery already treats the pick as a free
  reobserve outside the grounding budget; `verifyClaims` counts
  only CONSECUTIVE claims and resets on any other result. The
  bound is now 5: demonstrated streaks (3-4, interleaved with
  real scrolls) survive; a run that never leaves the re-check
  loop still terminates. Deadline remains the real bound.
- No gate moved. Harness: scroll case caller_deadline_seconds
  now 45 (per-case override, same runaway bound for others).
- Tests: 371 green.

## Addendum 81 (D119 — browser subject continuity via mint-chain hash proof)

- D118 evidence: after-0 scrolled bar 0->1.0, marker found,
  final verify drew completed .99 / evidence_visible .97 /
  kind_supported .97 — every gate passed except
  same_subject .93 vs the .95 bar. For browser windows the
  code proofs can't fire by design: windowSubject excludes
  AXWebArea/AXBrowser (page content can swap under stable
  chrome) and there is no nativeDocument. The verify lane then
  asks the hardest version of the question — comparing the
  page-top anchor against the scrolled-bottom settle frame —
  while the task's own stepwise subject draws already proved
  continuity at .95-.99 along the whole scroll chain.
- Fix carries that proof instead of re-asking it.
  `VisualGoalProof.chainSubject` records at mint whether the
  mint frame was a proven continuation of the anchor
  (code-proven or subject_preserved >= .95). In verifyGoal a
  settle frame byte-identical to that proven mint frame
  inherits the proof — identical bytes cannot depict a
  different subject. The anchor hash is also checked
  directly: a settle frame byte-identical to the anchor is
  the strongest possible subject proof, same as the primary
  lane's imageHash disjunct.
- For the Safari scroll case the settle frame is NOT
  byte-identical to the mint frame (page displaced), so the
  chain proof alone does not fire there — see the honest
  note below. What it does fix: unchanged-screen settles,
  cosmetic-only frames, and any replayed proven frame, which
  previously burned a marginal-prone model draw.
- Fixture fixes matching pixel reality (same class as D112):
  .subjectThenAction and .changedSubject declared a subject
  switch only in the model's answers while every frame used
  marker 0 — byte-identical bytes for a declared different
  subject, which cannot occur. Their post-switch frames now
  carry distinct markers, so the hash proofs correctly fail
  and the same_subject draw decides — still 0.01, still
  blocked.
- testVisualGoalNeedsFreshIndependentProofBeforeDone:
  .goal's frames are genuinely identical bytes, so the
  verify call now code-proves the subject and skips the
  subject_reference asset — expected assets [1,1] not [1,2].
  Fresh-frame requirement, independent verify, and
  settleVerified are unchanged.
- No bar moved; .95 stands for every model draw. The proof
  only fires on byte equality, which is strictly stronger
  than any draw.
- Honest limit: the scrolled-endpoint case still draws
  same_subject anchor-vs-endpoint unless a stronger browser
  page identity exists. The chain proof helps when the
  settle frame matches ANY proven intermediate, which the
  scroll loop does not currently retain — see next step.
- Tests: 371 green.

## Addendum 82 (D120 — scroll authorized discharged to the op pick itself)

- D119-r1 evidence: three reps blocked in ~13s with zero
  dispatches. after-1/after-2 picked scroll_down at .97 —
  then the grounded `authorized` draw landed .37 and .61 on
  identical state that drew .95-.97 in D117. Same question,
  same state, draws spanning .37-.99 across sessions: not a
  borderline band but pure resampling noise.
- Root cause: for scrolls, `authorized` asks what the
  operation pick already answered. The pick criterion IS the
  goal-match question ("choose the next unfinished operation
  for `goal`") — a .97 scroll_down pick is the model
  asserting the goal wants that scroll. Re-asking under
  different wording adds a second sample of the same
  judgment, not independent information.
- Fix follows the D79 referent-discharge class: for scroll
  ops `authorized` is no longer drawn at all. The gate
  substitutes `resolvedOpP` — the resolved pick's own
  confidence (op pick, bound-verify noul, alternative pick,
  or referent pick) — gated at the same .95 bar. A scroll
  resolved at .97 dispatches; one resolved at .72 does not,
  because a .72 pick is not a .95 goal-match.
- What stays independently gated: presence, protected, deny,
  control class, editable scope, subject continuity. Region
  scrollability was already code-proven (candidate geometry
  -> located=1). `goal_evidence` in the same primary call
  already judged the sought content missing — reaching the
  gate proves it, so the "content still not visible" clause
  re-litigated a proven invariant.
- `authorized` is no longer emitted for scroll ops in
  groundQuestions (pixel and native-candidate paths), so it
  is never drawn; the now-dead wide-band redraw clause for
  scroll-authorized is removed. `openLaneCleared` takes the
  referent-pick value for scroll ops the same way.
- Non-scroll ops unchanged: clicks keep referent/native
  discharge or the live draw; type/key lanes untouched.
- Tests: 371 green.

## Addendum 83 (D121 — requirement-side verify checks entailed; marginal subject retry)

- D120-r1 evidence: the scroll authorized discharge worked —
  after-0 and after-2 scrolled bar 0->1.0 with verified
  dispatches, minted six verify attempts, five passing
  same_subject=1.00 via the D119 chain proof. Yet every rep
  still blocked: VerifiedVisualGoal.init was returning nil on
  `exact_required` draws of .08-.11 against the <=.05 inverse
  bar (and `offered_only` .06/.09 twice) — the goal names the
  literal 'SEEK-MARKER-77', so the model hedges a residual
  .08-.11 on "does the goal require byte-exact" even while
  asserting kind_supported .97-.99 that the visibility claim
  is proven. Each nil burned a mint+verify cycle until a
  same_subject .92 draw threw terminally.
- `exact_required` for a non-exact kind is entailed by
  `kind_supported >= .95`: the kind judgment affirming the
  claimed kind of proof suffices for the requested outcome IS
  the answer to "is byte-exactness additionally required".
  `hidden_required` is entailed the same way for every
  mintable kind — hiddenBackend kinds never mint, so a
  supported mintable kind affirms visible evidence suffices.
  The draws are still asked and recorded; the entailment only
  substitutes when the kind judgment is decisive. Same
  derivation class as subjectProven -> same_subject=1.
  `offered_only` stays an independent draw — "is the visible
  thing an outcome or an offer" is a perceptual judgment the
  positive questions do not contain.
- `same_subject` marginal misses no longer throw:
  subjectUnverified stays terminal for a decisive rejection
  (<=.5 — a real subject change), but a .7-.95 miss is
  unresolved evidence and takes the same bounded
  re-verification nil that every other unproven score gets.
  The .95 completion bar is unchanged; a nil is not
  completion, it is "not yet proven".
- Tests: 371 green.

## Addendum 84 (D121-r1 evidence — safari.scroll qualified 3/3)

- after-0/1/2: `done verified=True strict_success=True
  false_done=False`, scrollbar oracle 0->1 on all three, wall
  24.2/22.4/22.6s, one verify call each (down from 4-6
  mint+verify cycles). scroll-after.png shows
  SEEK-MARKER-77 visibly rendered with "end of page".
- Final verify scores: after-0 completed .99 evidence .99
  kind .98 offered .03 exact 0.00 hidden 0.00 same_subject
  .99; after-1 same_subject 1.00; after-2 same_subject 1.00.
  The entailment fired (exact/hidden=0.00); same_subject
  cleared once on a real draw (.99) and twice via chain
  proof. First honest `done` verdicts for the scroll case
  across D90-D121.
- Residual risk noted honestly: exact_required/hidden_required
  no longer draw independently when kind_supported is
  decisive — a wrong-kind pick cascading through
  kind_supported is the remaining correlated-error path, same
  class as every other discharge this series.
