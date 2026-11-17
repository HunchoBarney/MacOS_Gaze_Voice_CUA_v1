# C1 R1/R2 independent source review

Reviewer: read-only jarvis-judge `1bd91db8`, explicitly authorized for C1 G4.
One implementation owner; reviewer made no edits or build/desktop calls.

First verdict: **FAIL FOR SOURCE ONLY** against
`c1-r2-candidate-source/manifest.json`.

The material defect was that output rendering advancement was proved during
startup but not continuously. The revised source retains the last observed
output sample advancement time, invalidates stalled/regressed/unhealthy routes,
binds receipts to the engine generation, and requires current receipts before
automatic action admission. Native observation continues on the serial audio
owner; the audio tap does not run the observation work. The new metadata
failure control exercises stale output despite fresh microphone input.

Second verdict: **PASS FOR SOURCE ONLY** against
`c1-r2-candidate-source-r2/manifest.json`. The reviewer checked all213 frozen
file hashes against the tree with zero differences and completed R1-D:
primitive support below0.9 cannot be bypassed by scroll/key/menu/media selection.

The reviewer withdrew its first claim that system speech was lost when local
speech became active: main retains SpeechOutput, controller init registers its
system channel, subsequent speaker changes add the local channel without
removing system, and binding/interruption visit every registered producer.
The reviewer also accepted the inherited dirty baseline recorded in
`c1-baseline-source.json`, rather than comparing the C1 scope to HEAD, and the
three existing scroll consumer test changes recorded in the R1 contract.

All source criteria were MET: truthful task outcomes, separate scroll effect
proof, lossless request compaction, primitive authority, explicit listening
controls/manual lifecycle, ordered real segmentation/ASR, one-shot admission,
negation/fragments, immutable onset scope, local final stop/pause, owned-work
cancellation, one continuous scroll task, fresh checks on every increment,
truthful conversation evidence, ongoing duplex receipts, all playback producers,
and pinned packaged VAD loading without runtime download.

Full G3: `c1-r2-full-verification-third.log`,1434 Swift tests,22 explicit skips,
zero failures;27 evidence checks;234 eye tests across11 files. The frozen source
manifest records the log hash. The reviewer did not rerun the lane.

**Final artifact G4, G5 and G6 remain open.** This source verdict does not prove
signed resource inclusion, live microphone/speaker echo behavior, Fn/pill
interaction, natural spoken continuation, latency targets or phase acceptance.
The signed candidate and corresponding manifest still need artifact review.
No acceptance flags changed.
