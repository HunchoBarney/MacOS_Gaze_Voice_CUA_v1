# R9 G4 source review

Fresh-context authorized read-only reviewer8fc04431: terminal PASS.
Subject: `c1-r9-source-1/manifest.json`,
SHA256 `5f67ee6e4760bbcaaf3787884de133b41b9139b882ee34dc8b47402b70a6eb84`.
Review compared the eight listed deltas against frozen R8 source4, not
the inherited working-tree diff. No source was changed during review.

R9-1/2/3/4 and the source portion of R9-5 MET. Device input/output buses,
identity checks, preserved speaker, explicit input selection and original
plain-input path were inspected. Mandatory duplex preflight binds the
signed-stage receipt and source hashes before input, observes real
frames/render/three routes/device identity, and records cleanup.
G5/G6 remain future obligations, not accepted by this source review.

The first review returned FAIL on R9-2, asserting that the output-render
receipt could expire despite advancing output. The reviewer withdrew
that finding on re-reading MicrophoneInput.swift:121-135: an advancing
sample sets `advancedAt = now` BEFORE expiry is evaluated. Concrete trace:
sample100@10 false,200@10.1 true,300@11 true. The reviewer reported no
remaining source counterexample with fresh input and advancing render.
No freshness condition was weakened to obtain PASS.

Retained runtime risk: a default-output identity change during setup
causes a preparation failure, as required by the no-substitution contract.
Real idle rendering, actual duplex preparation and normal GUI startup
still require G5. The reviewer did not rerun tests or touch the desktop.
Its zero-staged-files ownership command is not treated as proof of the
working-tree delta; the frozen manifest comparison supplies that scope.

G3: `c1-r9-focused-confirm.log`,66/66 affected checks,exit0,lane green.
Production release: `c1-r9-release.log`,192.68seconds,exit0,lane green.
Neither establishes microphone, ASR, human conversation or speed targets.
