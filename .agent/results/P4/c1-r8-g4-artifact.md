# R8 signed artifact G4

Independent read-only reviewer b51619af. VERDICT: PASS, no defects.
Candidate:
`/Users/karanvirkang/jarvis-local/c1-candidates/jev-c1-final-r8-emv9taxw/Jev Voice.app`

Main SHA256:
`60a17df6d1380953cde91700e1ba88fafceb63937a564f88b37af8e39b85c7a3`

Bound to c1-r8-source-4/manifest.json and
.agent/results/P12/c1-final-r8-stage.json; component manifest
c1-r8-component-manifest.json. Reviewer independently checked main/driver/VAD
hashes and `codesign --verify --deep --strict --verbose=2`: valid on disk,
satisfies designated requirement, stable Jev Voice Local Dev identity.
Driver0.38.0 preserved; VAD manifest pin
be41b15f2b6c5c73c4824b99963b54bc6d5f58c3af04468132ddfe131c1c8062.
Required runtime/resources/notices, source4/build binding and package controls
pass. Normal signing uses canonical public VAD bundler. Rollback separate and
unchanged, installed=false.

External ASR assets remain portability blockers. Raw semantic factory remains
10/11positive and18/18safe negatives, no broader language claim. This awards
only candidate artifact gate: G5 real TextEdit, G6 human microphone/continuous
conversation,50ms, broader C1/phase/release acceptance remain pending.
