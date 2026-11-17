# R8 source G4 attempt2

Independent reviewer b51619af, read-only re-review after initial FAIL.
VERDICT: PASS. R8-1 through R8-14 MET at source gate. No defects found.
Frozen source: c1-r8-source-4/manifest.json; only ConversationContext.swift
and VoiceSemanticTests.swift changed from source3.

Initial stale-reference defect reproduced before production repair:
c1-r8-reference-before.json/log,2tests/40failed assertions, legitimate
continuation positive control passed.
After: c1-r8-reference-after.json/log,169tests/2skips/0failures, including
real paced recorded capture and connected conversation/voice/task consumers.

Reviewer confirms:
- Reject/clarify/current-epoch catch discard full old request/reference
  (ConversationContext463-469,486-491,509-512).
- Unrelated nil-scope answer clears reference before input (552-556).
- New request and false verification clear old scroll (171-181).
- Latest effect without verified scroll witness clears old scroll (567-575).
- Legitimate stop/pause retains fragment-only cleanup, incoming audio and
  incomplete-fragment behavior remain intact (289-306,437-449,610-614).
- Native capability/binding, uncertain-no-fallback, independent movement,
  consumed/currentness path, whole-goal semantics, default/pause, VAD/signing,
  ownership and honest-limit criteria remain satisfied.

No signed artifact, G5/G6, microphone, 50ms, broad NLU, phase/C1 or release
acceptance is awarded. Raw semantic factory still10/11positives18/18safe
negatives; no reroll/threshold changes. Broader product obligations remain open.
