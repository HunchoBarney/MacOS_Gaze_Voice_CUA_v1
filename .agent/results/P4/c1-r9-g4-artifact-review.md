# R9 G4 artifact review

Fresh authorized read-only reviewer d8a2ee5b returned terminal PASS for
final-r9, before G5. Signed binary:
`dc79dbf4b805456e139e016b59fa427a15b265e12d53ded7a1d450a4614f1f25`.
Source snapshot SHA:
`5f67ee6e4760bbcaaf3787884de133b41b9139b882ee34dc8b47402b70a6eb84`.

The reviewer confirmed actual signed binary hash, source manifest binding,
strict deep signature, unchanged designated requirement/signing identity,
resource and component manifests, generated Info driver stamp, Cua0.38
canonical pin, VAD declarations/licenses/notices, and unchanged rollback
binary `f6abbe98113d7f9362ab98bc48a32e1fa94df6ddb3b376ab27dc56939fa4adf1`.
Signed driver bytes differ after signing; this is not a new driver pin.

Package manifest verification recorded candidate_verified=true and
release_ready=false, with external speech-model bundling and transitive
license review retained as C3 blockers. G5/G6 were explicitly not covered
by this review. Subsequent real duplex attempt failed on the slow
per-buffer format query; see c1-r9-duplex-attempt-1.json. Retain this
source/artifact PASS together with that runtime failure.
