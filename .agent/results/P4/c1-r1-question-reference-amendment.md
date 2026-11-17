# C1 R1 request questions: follow-up

Status: prospective G2 PASS from read-only reviewer1bd91db8 before production
edits or resource recipe use. No blockers; source and consumer ownership,
proposal/evidence separation, full byte binding and bounded resources reviewed.

The signed ea2f7c6a candidate failed the retained300-line packaged MCP workload:
c1-scroll-r2-final/comparison.json. Request0 blocked in1253.845708ms with
max_tokens_exceeded. Both document contents and decoy viewport stayed unchanged;
cleanup restored the original document count. This is not a speed win.

Actual unified logs for its process2620 at2026-11-16 05:59:38:

- Before sharing: state204471bytes, questions123553bytes,28questions.
- On the wire: state99383bytes, questions129321bytes,28questions.
-20 action candidates; no model answer and no action dispatch.

Whole-string state sharing saved105088 state bytes but questions still duplicate
large proposed-action descriptions. JevChooser builds those descriptions into
both step Choice criteria and each action_support instruction. The existing
canonical state-reference helper is used for goal facts, not these descriptions.
Stop the hypothesis that state-only sharing suffices.

Live docs checked2026-11-16: docs.typesafe.ai/models.md,
api/errors.md and concepts/state.md. Jev1.14 has64k per-request/32k per-question
context. Gzip affects transport size, not these context limits. An opt-in262k
context exists but is slower/less accurate and remains excluded by R1's contract.
The proposed fix uses the documented named state/criteria-reference pattern.

Owned source remains JevChooser.swift; owned existing tests JevChooserTests.swift.
Reuse the existing canonical choice-reference implementation for large action
descriptions, preserving their entire UTF-8 contents in a code-built state map.
Large action-support questions identify that same candidate/state entry instead
of embedding its complete description again. Keep small-request shape, all
candidate IDs/order, native details/bounds, facts, support questions, thresholds,
model, deadline, dispatch and independent result proofs unchanged.
Describe referenced actions as proposals, never observed outcomes or permission.
No long-context header, retry, truncation, model change or candidate reduction.

Before production edits, extend the existing capture-only test to fail on large
action descriptions duplicated into questions. Preserve byte identity for
composed/decomposed Unicode and different endings/subjects, resolve every
criterion/support reference to its original candidate, retain all questions and
check the small-request control. Capture stops before inference; it does not
invent model answers. Reuse the existing low-support/exact-state consumers.

Resource recipe amendment: debug output was retired after the previous full G3.
Add one cached-release test scope using the existing release/FluidAudio cache,
--jobs1, --disable-automatic-resolution and existing3GiB-start/1GiB-stop guard.
It accepts an explicit existing-suite filter, runs through the serialized lane,
and is used for failing-before/passing-after and affected consumers. Record
commands, exit status and raw logs. Default/full/cold5GiB scopes stay unchanged.
The existing cached package recipe may build/stage one revised final-r4 after
verification; keep all ea2/source/raw/live failure evidence and rollback.

Validate the unchanged retained300-line workload through the revised signed app,
including actual request bytes, requested-direction viewport movement, unchanged
decoy/content and cleanup. No repeated unchanged model calls to obtain a better
probability. If the revised request still exceeds context, preserve that actual
structure and reassess rather than trimming the workload. Final independent G4
and grouped G6 still apply; no phase acceptance claim from representation tests.
