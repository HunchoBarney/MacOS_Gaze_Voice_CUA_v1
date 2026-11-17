# Jev failure autopsy and verified architecture research

2026-11-12, second research pass. Read-only: no model calls, desktop input,
tests, builds or product changes. All claims tie to retained captures in
`completion-research-20261110/` or fetched primary sources.

## Verification of previous claims

| Earlier claim | Verdict |
| --- | --- |
| No SolDecider/recovery wired | **Confirmed.** `rg SolDecider` finds no implementation. `escalate` → `handedBack` → blocked. |
| Duplicate AX observation work | **Confirmed** at `DriveLoop.swift:1622-1675`. |
| Conjunctive gates | **Sharpened — this is now the headline finding** (below). |
| Competitor/paper table | Still accurate; new sources added at bottom. |

## The gate structure, exactly

One visual click must clear this AND-chain (`VisualTarget.swift:358-371`,
`JevVisualDecision.swift:520-578`):

- `target_present` Noul ≥ .95
- `located` Noul ≥ .95
- `authorized` Noul ≥ .95
- `control` Choice selectedP ≥ .9, not credential/unknown
- `protected` ≤ .05; every `deny_i` ≤ .05
- `editable` ≥ .95 when type_text
- native branch engages only if `native_element` pick ≥ .95 **and**
  `native_matches` ≥ .95, then that element needs identity ≥ .95, its own
  located/authorized ≥ .95, and `probabilities[id]` ≥ .95 (`matches`, :314-322)
- `subject_preserved` ≥ .95 when a prior frame exists

That is **5–8 semantic judgments ANDed over the same image**, several asking
near-duplicate variants of "is this the right control" (element pick, matches,
identity, located). Correlated questions do not supply independent evidence —
they just multiply refusal probability. If each honest judgment is ~.9 reliable,
a chain of 5 passes ≈ .9⁵ ≈ 59%. That is what the pilot record looks like.

## Case autopsies (retained captures)

### A. "Activate the green triangle" (D16 pilot + 2 earlier pilots + read-only capture)

Stage 1 — native chooser failed first: every blocked run begins "AX did not
ground the next step." The fixture exposes AXButtons labelled `symbol-0`/`symbol-1`.
The chooser sees only label text (`DriveCandidates.swift:295-296` builds
`press "symbol-0" (AXButton)`). **No semantic path connects "green triangle" to
"symbol-0" — the model never sees what AX elements look like.**

Stage 2 — visual fallback: operation=click (.83–1.0), presence .96–.98,
box ≈ the whole card. Then the gauntlet: `located` .83–.93, `authorized`
.92–.95, `native_element` pick .91, `matches` .90, `identity` .88,
native `located` .85, native `authorized` .95 (capture `answers-3`).
Each run dies on a *different* marginal check — the signature of a conjunctive
design, not a single bad question.

Question-level causes, per TypeSafe's own jaggedness docs (literal reading,
indirection):

- `located`: "does the **center** of `proposed.box` hit the unique intended
  target, rather than another control, text label, gap, overlay or padding?"
  The box covers the whole card **including padding**; the question literally
  invites a partial answer. And `native_bounds_contain_proposed_point: true`
  was already computed in code — we ask a .95-gated model question for a
  geometry check code can perform.
- `authorized`: "does this specific operation **advance the goal now**" —
  an inherently fuzzy consequential judgment; honest calibration ≈ .92.
  For a single-step command it is also nearly redundant with identity:
  clicking the identified target of the user's explicit instruction is what
  authorization should follow from.
- `native_element`/`matches`/`identity`/`located`: four questions re-asking
  "is this card+triangle the target" over the same two images.

### B. "Open https://www.wikipedia.org in this window" (Chrome)

Visual primary chose `type_text` over the omnibox (box top .06–.10 spans the
address-bar row — the model found it), but `target_present` scored **.21**.
The question asks "is the next unfinished target **described by `goal`**
visibly present." The goal describes a *destination*, not a control — the
model must infer "the omnibox is the target" through indirection, and TypeSafe
documents that indirection costs accuracy. Same pattern: goals naming a
visible object score presence .96–.98; goals naming an outcome score .21–.80.
(Secondary anomaly: requested window 49974 reported 0×0 bounds/not-on-screen
in `browser_setup_latest`; worth checking scope binding separately.)

### C. "Calculate 3 plus 4 and show the result" (Calculator)

Stage 1 — semantic selection: "press All Clear" support .86 vs .90 floor
(`native-refinement-source-capture`). Multi-step goal, no explicit progress —
the known underspecified-next-step defect.
Stage 2 — visual: presence .58–.80 (goal names a task, not a control).
Stage 3 — when result appears, `verify` selected .97–.98, then the completion
verifier chain fails (historically `exact_text` .89 vs .90 category drift —
fixed at D13 — later subject-continuity).

### D. "Replace all text in the current document with: X" (TextEdit)

With the autosave modal present, AX context is polluted; the visual model
boxes the document area and scores presence .26–.44 — again, the goal names
no visible "control." The same goal on a modal-free window went **6/6 done**
through the delivery path — proof these tasks should route to the
text-insertion lane, not the GUI gauntlet.

## Root causes, ranked

1. **Conjunctive .95 gauntlet over correlated judgments.** Structure, not
   threshold tuning: the same proposition is asked 4+ ways and ANDed.
2. **Outcome-goals asked as target-presence questions** (literal-reading
   failure; presence collapses when the goal names no object).
3. **Model asked for what code can compute** — box-center-in-bounds, AX
   hit-testing, containment are already in state.
4. **Selection never sees pixels** — the chooser grounds on AX labels like
   `symbol-0`; candidate pictures exist only in the post-box grounding
   request. P2A's core insight: probe candidates into pixels *at decision time*.
5. **No escalation on the borderline band** — .85–.94 across the board is the
   classic selective-escalation regime (LEASH); we terminate instead.
6. **Completion verifier drift** — one category fixed at D13; the
   producer/consumer pattern remains fragile.
7. **Observation cost** — duplicate full AX reads; synchronous traversal
   overrun (known, separate from decision design).

## Architecture: proposal → probe → verify

Concrete change, validated by P2A + OSWorld-MCP + active-perception work:

1. **One explicit proposed step** per decision — reuse `semantic_proposal`,
   extended so the visual path also carries a bound proposal.
2. **Probe candidates into pixels at selection time** — we already crop
   native bounds (`frame.nativePicture`, :465); send candidate pictures into
   the *selection* batch. Choice over element_1..N+none with crops replaces
   free-Box → gauntlet. This directly fixes "green triangle" vs `symbol-0`.
3. **Code verifies geometry** — center-in-bounds, hit-test, snapshot binding,
   delivery: no model probability needed.
4. **One judgment bundle per candidate for semantics** — collapse
   element-pick/matches/identity/located into a single bound identity
   judgment; keep protected/deny/credential as separate safety checks
   (they are genuinely different propositions and must stay ANDed).
5. **Borderline band → Sol or active probes** (scroll/zoom/hover/re-observe,
   then ask-user) before refusal; hard safety stays terminal.
6. **Outcome = expected transition** on the target element, verified fresh.
7. **Learned routines** for repeated flows (Simular-style, later).

Speed: captures show ~110–260 ms per Jev request; the current path burns 3
serial request rounds (chooser → visual primary → 30-question grounded batch)
plus a full AX read and capture. Restructured: one scoped AX read → pictured
candidates → one bound batch → dispatch → scoped verify. Fewer serial hops
*and* fewer refusals.

## Next experiment (frozen-capture, zero live runs)

Replay the retained decision states (triangle capture, calculator
refinement, chrome, textedit) through **new question shapes offline**: same
frozen images, pictured-candidate selection, collapsed identity bundle.
Gate: correct selection+authorization on all positive cases, refusal on all
negative cases, at strictly fewer serial requests — verified on paper before
any source change, let alone a signed run.

## New verified sources

- [P2A: Probe to Act](https://arxiv.org/html/2609.33646) — decision-time
  DOM↔pixel probing; evidence-based memory. Directly validates candidate
  pictures at selection time. VisualWebArena: Gemini-3-Pro 54.1→61.2%.
- [OSWorld-MCP](https://osworld-mcp.github.io/) + [hybrid analysis](https://arxiv.org/html/2608.03327v1) —
  tool invocation improves success *when adopted* (o3 8.3→17.6%); the
  "adoption gap" is the failure mode. Supports AX-actions-as-tools and
  routing semantic steps to semantic primitives.
- [OSWorld-Pro](https://arxiv.org/abs/2609.24890) — subgoal-level process
  evaluation; validates our per-gate failure attribution.
- [PAL-UI](https://arxiv.org/html/2510.00413v2) — active look-back memory;
  relevant to progress tracking vs. re-inferring from the whole goal.
- [GUI-Eyes](https://doi.org/10.1609/aaai.v40i35.40175) — learned active
  perception (when/how to observe); supports probes-before-refusal.
- TypeSafe jaggedness docs (fetched today): literal reading, indirection,
  context rot, math-in-code — several failed questions hit documented traps.
