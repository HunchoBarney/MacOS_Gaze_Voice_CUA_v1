# R8 source G4 attempt1

Fresh-context independent read-only reviewer b51619af. VERDICT: FAIL.
R8-1..7 and R8-9..14 MET at source gate. R8-8 NOT MET.

Defect: ConversationContext.swift93-105 permits exact local continuation from
memory.scroll when the native scope still matches, without proving that the
latest relevant conversational turn still refers to that action. Intervening
clarification at504-507 or caught semantic/execution failure at463-465 clears
only fragments and leaves the old verified scroll anchor.

Concrete trigger: successful TextEdit scroll, then ambiguous/failed "make it
nicer", then "keep going" in the same window. Local routing can incorrectly
start ongoing scrolling from the old anchor and bypass semantic reference
validation. This violates R8-8: unrelated/ambiguous context cannot inherit an
old anchor. Invalidate it or require fresh current-turn reference proof after
clarification, failed semantic interpretation or an unrelated unverified turn.

All native dispatch, uncertainty/fallback, independent movement, consumed local
admission, semantic whole-goal fallback, barge-in, defaults/readiness, canonical
resource/signing, scope and honest-limit criteria passed this source review.
Review did not award G5/G6, signed R8 artifact, live native scrolling, microphone,
50ms, broader C1, P4 acceptance or release. No reviewer is now running.

Next: write meaningful regression controls BEFORE the repair in existing owned
tests; fix this one defect, run affected serialized checks, freeze updated
source and obtain independent source PASS. Do not restart architecture review
or repeat the whole suite absent a concrete risk.
