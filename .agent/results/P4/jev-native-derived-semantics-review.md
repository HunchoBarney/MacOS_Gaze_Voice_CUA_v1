# Derived Semantics Review

Reviewer: independent read-only jarvis-judge d1a8446d.

Final PLAN verdict: PASS.
Plan: jev-native-derived-semantics-plan.md,
SHA256 f73ab81935747a86ddef41c40c58d937be5afea67b6477b3ee43b087c232a121.

This is a proposal requiring renewed explicit user G1. It is not
implementation permission, native qualification, reliability evidence
or P4 acceptance.

The first proposal FAILed because replacing the fresh literal Noul with
a typed Choice was outside the approved D10 contract, and explanatory
definitions could not bypass existing kind/subject gates. That proposal
is discarded. The repaired plan retains the primitive shapes, numeric
gates, native identity/context/bytes and legacy literal path. Six old
verifier questions remain verbatim; the subject clarification is confined
to valid fresh native-derived evidence.

Reviewer checked raw frozen requests and scores, synthetic account/
document refusals, fail-closed literal/mixed exclusions, and explicit
distinction between model experiments and signed qualification. The
reviewer specifically notes kind_supported exactly .95 has no margin,
and unknown-document .13 is a refusal, not strong negative certainty.

Diagnostic SOURCE verdict initially FAILed at the readonly readiness
helper: it removed LRM but not RLM while its neighboring display oracle
handled both. Reproduced by the real readiness-normalization keeper:
five tests, four skipped, two RLM assertion failures before repair.
The helper now removes both marks only for diagnostic display readiness.
The original strings and all production proof bytes remain unchanged.

Final DIAGNOSTIC SOURCE verdict: PASS.
Reviewer cites JevNativeChoiceDiagnosticTests.swift:354-378 and the
before/after logs under development/JevVoice/recovery-20261110:
native-readiness-rlm-before.log and native-readiness-rlm-after.log.
After: five tests, four skipped, zero failures.

An additional owned-native fixture run is retained at
completion-research-20261110/native-readiness-proof-regression.
Its receipt is passed=true, resources_clean=true, input_actuations=0,
qualification=false. It uses real native observation, stubbed AI and
an owned AppKit content-view raster; it is not a driver screenshot or
signed-app/front-door qualification.

No production Source hash changed during this diagnosis: all 105 match
the signed D10 candidate receipt. No installation or acceptance change.
