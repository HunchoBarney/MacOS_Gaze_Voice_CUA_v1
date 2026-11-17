# R10 signed candidate G4

Fresh read-only reviewer07bca541: terminal **PASS** for source3 packaging
and the actual signed candidate's readiness for G5/G6. No phase acceptance.

Candidate: `~/jarvis-local/c1-candidates/jev-c1-final-r10-y6wbos0n/Jev Voice.app`
Main SHA256 `2261f60b64e0c8cb26a5996c62ee3154e1c2afc86481847e2e479cb9ab30d5f0`.
Source3 SHA `c170a352a424eb26a12db0ca2c52b4860f1ac34234fa1a504c7b776c6cecc9d3`.
Stage receipt SHA `615bfd8500c5398875b699df39c9e2cf48ea56f61902a03a007264dfd8e8625c`.
Component manifest SHA `5500db78ac0d38f27dbd3cef452dfcf457e782d9e6b6f5c03b23de56f3b35878`.

Reviewer verified actual executable, strict deep codesign exit0, signed
Cua/Codex hashes, frozen native/source binding, exact retained-base guard,
complete base identity and unchanged fallback, P12 provenance enforcement,
missing original daily, no restore/install and the corruption controls.
Source2 native181tests/1optional skip/0failures; P12 actual artifact
15tests/0failures. Staging selected reviewed `--retained-base` path.
Canonical Cua0.38 is unchanged. Its re-signed whole-file hash differs from
the fallback; the receipt correctly says signed_matches_rollback=false.

P12 candidate_verified=true; default speech_models=[] and provider
openai-realtime. release_ready=false solely for pending C3 portable
package qualification, not a C1 artifact failure.

Original daily remains absent, cause unknown; do not call it unchanged
or restored. Verified R9-2 is the recorded last_verified_candidate
fallback. No app launched yet. Normal OpenAI startup, real microphone/
spoken replies/Fn, human G6, latency/accuracy and whole C1 remain open.
