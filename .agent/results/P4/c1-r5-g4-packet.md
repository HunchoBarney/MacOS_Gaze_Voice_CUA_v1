# R5 source and signed-artifact G4

Review boundary: the lossless fragment-reference repair and this exact local
candidate. Not full C1/P3/P4 acceptance. G5 scroll, physical conversation,
accuracy comparison and latency goals remain open.

Candidate:
`/Users/karanvirkang/jarvis-local/c1-candidates/jev-c1-final-r5-z6nt6jh4/Jev Voice.app`

Signed main:
`7e813283b9d3c596d8049858d52873e80dbd7d9e983a74a80b6570b8f2ebf721`

Unsigned production main:
`719ca80ae46f36518f231f711248d6b84215d942d35574b7ca1adb399b3cbd33`

Frozen compiled inputs: c1-r2-candidate-source-r5/manifest.json,
SHA1413591ea058bad5f00a917849ad47365d3000ef68d5f6ee6938b695158d8b28.
Final staging inputs: c1-r2-candidate-source-r5-staging/manifest.json,
SHA60ec2b456e7c1097ba0e48f1bdd1fe139fdf7924edd581fb7d173e9a4da08681.
The app/test/build inputs are identical; final snapshot additionally binds
the reviewed staging budget/helper changes.

Owned source changes from R4:

- Sources/JevVoice/Drive/JevObservationPayload.swift: literal-only fragment
  joins inside the request reference table, exact UTF-8 matching, immutable
  local state, reserved-key collision refusal, actual encoded-size gate.
- Tests/JevVoiceAppTests/JevChooserTests.swift: byte restoration, decorated/
  adjacent/Unicode spans, candidate/subject/order and actual captured native
  request controls. Failure cases were recorded before production edits.
- scripts/verification-lane.sh: release test replan switch/r5 label and
  separately reviewed stage-only resource budget.
- .agent/results/P4/jev-stage-candidate.py: r5 label and private durable stage
  location, no signer/runtime/rollback change.
- .agent/results/P4/jev-build-guard.py: fractional initial budget parsing,
  finite/nonnegative validation. Only staging uses2.75GiB admission; compiler
  and test budgets retain their existing values.1GiB emergency unchanged.

Relevant evidence:

- c1-r1-fragment-reference-amendment.md: algorithm/authority G2.
- c1-r1-fragments-failing-before.log: unchanged production failed new controls.
- c1-r1-fragments-passing-after-replanned.log/json:321checks,0failures.
- c1-r1-fragments-r5.diff: original four-path change before stage-budget delta.
- c1-r1-fragments-release.log/json: standard production build PASS,
  log8179386cf967082beac3457cb982a0ac3df5b4b7503c65432a6355d1c291fd4e.
- c1-r5-staging-budget-amendment.md and c1-r5-stage-footprint.json:
  prospective resource G2 PASS1bd91db8. No further lowering on failure.
- c1-r5-fractional-guard-before/after.json: old decimal parse failure; current
  valid decimal/integer, insufficient-space, negative, NaN/infinity/invalid
  controls. An initial wrapper assumed3GiB would remain unavailable; it
  stopped before staging when free space recovered. Final controls use the
  measured admission condition.
- c1-r1-fragments-stage.json: original3GiB preflight refused, no child.
- c1-r1-fragments-stage-replanned.log/json: stage PASS. Started with
  4192907264B, ended3031990272B. This is not a measured total peak bound.
- ../P12/c1-final-r5-stage.json:
  SHAb5c4b2ce00531e7174705390e1b01c78662e048d5d86e65cb6bbca0715120f55.
- ../P12/c1-final-r5-component-manifest.json:
  SHAedcfe0cc9a4a5a035bd90fb2a9686cd00afa5c0d9638acf197c35b95f8497f85.
- c1-r1-fragments-package-controls-current.log:8current-candidate controls
  PASS with explicit JEV_C1_RECEIPT; hash
  b48e0f5bd4febb58781540550f9ca94159060d53c040fd0c36aeaa847810d7b7.
  Earlier default-receipt invocation reached0tests because defaultR3 is
  archived; c1-r1-fragments-package-controls.log retains that setup failure.
- c1-r1-fragments-package-verification.json: candidate_verified true,
  release_ready false, external speech models/C3 qualification still pending.

Retention details are in c1-r5-artifact-retention.md and corresponding receipts.
Old R2/R3 are native ZIP archives with full byte/mode/link checks, not ready
apps. Dailyf6, baseline29b4, savedc292 and oldR4 651 remain ready. Two older
temporary bundles were missing five zero-byte sealed resources each; exact
original signed-envelope hashes/modes were recovered from the valid daily
source, without re-signing or changing binaries/envelopes. Failed evidence
and exact recovery are retained. Cause unknown.

Completed generated test/object/cache/symbol outputs were retired after
verification. Output maps, canonical SDK/model artifacts and source remain.
The generated release copy of libtext_processing_rs.a was removed only after
matching the retained canonical xcframework SHA; SwiftPM's copy-tool recipe
regenerates it. An immutable duplicate Git pack uses native APFS sharing;
both cache paths, bytes, modes and extended attributes are preserved.

No model, candidate omission, text truncation, threshold, action permission,
executor or retry changes. The earlier HTTP200 prototype's0.87support was
below0.90 and did not authorize input. G4 must not turn that into G5 success.
No daily replacement, installation, commit, push or distribution.
