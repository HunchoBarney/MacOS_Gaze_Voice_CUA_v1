# C1 lossless repeated spans

Status: prospective G2 PASS by read-only reviewer1bd91db8 before production
edits. No blocking findings. Source ownership, byte/reference/authority
invariants, failing-before controls and unchanged resource gates reviewed.

The actual R4 signed workload remains blocked. A debugger attempt timed out
before capture; it changed no trust settings and sent no model request. Its
owned process/debugserver are stopped. The existing release diagnostic then
captured the current production DriveLoop.preview/JevChooser request against
the same300-line content in a separately named owned TextEdit window. It
cannot act; captured input and observations are real. This is diagnostic
evidence, not a substitute for signed-app G5.

Private capture:
../jarvis-v1-vision-driver/development/JevVoice/c1-scroll-request-r4-second/
(relative to repository parent). request-0.json SHA
8c833213f680a31db70c26045ff44957d44d197b7bdbb1b1b183bf7fc6033aff.
28questions; encoded state100536bytes/questions60041bytes, consistent with
signed actor9170 state100201/questions60090 apart from document identity.
The document's11399 UTF-8 bytes appear8times: twice in observed_content,
twice in screen_values, once as an atom and once in each of3decorated action
descriptions. Whole-string interning cannot share these decorated spans.
All documents are restored after capture. First capture's cleanup mismatch
was corrected by exact path after checking its body; original failure remains.

A read-only request-shape prototype preserved all state/28questions, model and
threshold definitions. It represented7 duplicate spans as exact ordered joins
of literal strings and existing text references. Byte-exact restoration passes.
State18893bytes; questions71045bytes including the explicit join-format guide.
One real Jev response is HTTP200 with21851 input tokens,743 output tokens.
Raw response is retained. Selected scroll:down probability0.96; applicable0.97;
action support0.87 is BELOW existing0.9, so this is a transport/context proof
only, not an accepted action. No action or performance qualification claimed.

Own JevObservationPayload.swift and existing JevChooserTests.swift. Extend
request-only sharing with __jev_join arrays, explained in affected questions.
Reuse Foundation Data.range for exact UTF-8 matches. Build the same repeated
string table; process entries shortest first, and retain only literal table
entries as matching atoms. Compound entries reference those literal atoms,
never themselves or other compounds. Encode unique strings containing atoms
as ordered literal/reference parts too. Do not alter original local state.
Keep full fact IDs/order/relationships, proposal/authority boundaries, every
question/candidate, current model, deadlines, thresholds and no-retry policy.

Reserve __jev_join and fail sharing closed on collisions, just as for current
metadata. Only return a representation when total encoded request shrinks.
Small requests and requests without joins retain their existing representation
guide. No substring normalization, truncation, summary, candidate filtering,
new dependency, model switch, long-context header or probability fabrication.

Before production edits extend existing capture-only controls: decorated and
adjacent spans; composed/decomposed Unicode and different endings; exact
round-trip with subjects/order intact; no-match/collision cases; explicit
reference explanations; literal-only atom references with no cycles. Test
the actual recorded native state by expanding its generated references first,
preserving source values and stripping only generated table metadata.

Use the approved serialized cached-release3GiB/1GiB scopes, one compiler job,
with no dependency downloads. Capture failing-before, passing-after and affected
consumer results. Retain all existing apps/evidence; stage one final-r5 with
the existing recipe, no signing-policy change. Fresh G4, unchanged retained
signed-app G5, then grouped physical G6 remain required. If current support
checks reject, preserve that result and investigate its meaning rather than
lowering the floor or repeating the same request for a more favorable answer.
