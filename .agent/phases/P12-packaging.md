# P12 — packaging ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: main, serialized integration · Depends on: P0–P11 for acceptance
> Early manifest/staging work begins in C1 · Branch: `ship/v1-p12`
> Acceptance: `.agent/acceptance/P12.json` · Contracts: runtime provenance, keys, setup

## Purpose

Deliver a coherent signed private-tester application that works without
a source checkout, Homebrew, development toolchain or developer caches,
with predictable permissions, diagnostics and a recoverable install.

## Context

Read SHIP-PLAN C1/C3, REUSE, Makefile and ThirdParty/Cua/README.md.
`make local` replaces/relaunches the daily app; it is not a harmless
candidate-build command. Development tracker staging can use --if-present.
The source pin for Cua 0.38 and staged 0.45.4 candidate are distinct.
Codesign verification can hit provenance detritus in synced Documents;
use a prepared copy outside it. The previous Keychain startup blocker
requires current normal-app evidence, not an assumption of resolution.

## Reuse decision

Use existing stage/sign/bundle scripts and native codesign/ditto tooling.
Bundle the compatible pinned node, Electron/ONNX tracker, Cua/SDK,
DevTools MCP and necessary speech/tracker models. Reuse FluidAudio and
existing model loaders. REUSE documents SDK licenses; this phase verifies
exact shipped binaries, weight licenses, notices and transitive packages.
Do not add an installer framework, updater or hosted key proxy.

## Owned paths

```text
Makefile
Package.swift
Package.resolved
scripts/sign-app.sh
scripts/bundle-tracker.sh
scripts/package-candidate.sh
scripts/verify-clean-install.sh
scripts/verification-lane.sh
ThirdParty/Cua/README.md
ThirdParty/Cua/source-manifest.json
ThirdParty/Cua/fetch-embedded-binaries.sh
ThirdParty/Cua/THIRD_PARTY_NOTICES.md
ThirdParty/OPEN_SOURCE_NOTICES.md
Sources/JevVoice/ComputerControl/CuaDependency.swift
Sources/JevVoice/Driver/CuaDaemonHost.swift
Sources/JevVoice/Gaze/TrackerHost.swift
Sources/JevVoice/Settings/APIKeyStore.swift
Sources/JevVoice/Settings/Config.swift
Sources/JevVoice/Support/SpendCounter.swift
Sources/JevVoiceCore/Models/JevClient.swift
Sources/JevVoiceCore/Models/OpenAIResponsesClient.swift
Sources/JevVoice/Voice/RealtimeVoiceClient.swift
Tests/JevVoiceAppTests/CuaDependencyPinTests.swift
Tests/JevVoiceAppTests/DriverDaemonHostTests.swift
Tests/JevVoiceAppTests/TrackerHostTests.swift
Tests/JevVoiceAppTests/LedgerSpendTests.swift
Tests/JevVoiceAppTests/PackagingTests.swift
README.md
TESTER-GUIDE.md
.agent/phases/P12-packaging.md
.agent/acceptance/P12.json
.agent/results/P12/**
.agent/PROGRAM.md
.agent/PROGRESS.md
```

SpendCounter is the existing approximate feed-based usage display, not a
proven billing ledger or hard cap. Reuse it for display; review transport
admission and actual usage accounting with P3/P4/P5 before adding budget
enforcement. Do not infer a dollar cap from UI event counts. Eyes payload
changes remain the eyes owner's work.

## Non-goals

No public notarization/auto-update/new platform, silent driver pin
replacement, embedded repository secrets, dependency selected as @latest
at runtime, or daily-app overwrite before candidate evidence and approval.

## Milestones

### M0 — early manifest and strict dependency preflight

**Change:** identify exact app source, driver/SDK generation, runtime,
resources, model hashes, signing identity and licenses. Reconcile sibling
candidate receipts. Add a `p12` offline verification-lane mode and
read-only manifest assertions. Missing runtime/model is a failed release
preflight, even when development staging may skip it.

**Check:** `scripts/verification-lane.sh p12` → nonempty provenance/
dependency/host/spend suites; wrong binary, mismatched SDK, missing model,
escaped resource path and missing notice are detected.

**Evidence:** `.agent/results/P12/component-manifest.json`,
`reuse-and-license-review.md` and `contract-review.md`.

### M1 — portable sealed candidate and controls

**Change:** extend the existing build/stage/sign scripts with strict
release resource bundling and a reusable isolated candidate path.
Preserve SDK/model runtime contracts and stable permission attribution.
Keep private-tester keys sourced through the existing Keychain/build
policy, controls for separately billed services, redacted diagnostics and
rotation checklist. Jev has no artificial request-count or spend cap.
Only owning helpers are stopped/cleaned; previous daily artifact stays.

**Check:** add/run the serialized `p12-stage` mode to stage outside synced
Documents, then verify its actual bundle with
`codesign --verify --deep --strict "$JEV_CANDIDATE_APP"`.
Expected: coherent signed artifact plus manifest; no daily install.
Inject an intentionally missing resource in an isolated fixture and prove
the preflight rejects it; do not alter the real rollback artifact.

**Evidence:** `.agent/results/P12/stage-receipt.json`, source/runtime
digests, signature output and failure controls. No secret values in output.

### M2 — clean-user install, startup and demo

**Change:** prepare a concrete install/rollback proposal. After its
authorization, test the sealed candidate on a clean Jev user/profile and
declared configured test accounts. Add `p12-install-proof` to the existing
lane, using the owned verify-clean-install script; normal GUI startup
must spawn helpers and reach real readiness without a shell bootstrap.

**Check:** `python3 scripts/with-desktop-lock.py scripts/verification-lane.sh p12-install-proof`
after the scoped install/live grant. Relocation/path-with-spaces, first
permission grants, subsequent launch, offline local readiness, missing
key/network and revoked permission must be handled accurately.
No Homebrew/source symlink/developer cache is required. Demo flow 10/10;
measure first-use three moments <=3min with P10 and actual cold/warm
timings. Keep physical Fn/gaze evidence separately identified.

**Evidence:** `.agent/results/P12/qualification.json`, clean-user
environment/preconditions, GUI/autospawn/Keychain/TCC results, demo rows,
diagnostic redaction, rollback proof and final tester guide.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P12-1 | M0 | coherent manifest, licenses and resources |
| P12-2 | M1 | strict reproducible stage/signature |
| P12-3 | M2 | normal GUI/no-developer-dependencies startup |
| P12-4 | M1/M2 | key/spend/diagnostic controls |
| P12-5 | M2 | first-use and 10/10 demo |
| P12-6 | M1/M2 | isolated candidate, approved install and rollback |
| P12-7 | M2 | independent review, guide and handoff |

## Gates

G1/G2 and scoped G4 passed for the early C1 inventory, offline checks and
separate development candidate. C3 portable packaging needs its own
contract. Early M0 does not require all features to be complete;
whole-phase acceptance does. All build/sign/test modes use the serialized
lane, and all live changes use the desktop lock. p12-stage and
p12-install-proof are planned deliverables, not existing success claims.
No install grant or sudo/password flow is implied by writing this plan.

## Progress

- [x] Draft/default-fail criteria prepared.
- [x] M0 C1 manifest, offline controls and dependency preflight implementation.
- [ ] Release preflight passes with portable models and completed license qualification.
- [ ] M1 sealed candidate.
- [ ] M2 clean-user/demo/rollback qualification.

## Surprises & Discoveries

Development install success does not prove a portable bundle. Upstream
monorepo latest release can identify a different component. A code change
that fixes source readiness can also change Keychain/TCC behavior; verify
the exact signed artifact through GUI launch.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Inspect packaging in C1; seal and qualify in C3 | Surface dependency/setup problems early without overwriting the daily app |

## Outcomes & Retrospective

C1 produced a coherent separately signed c292 development candidate,
matching source and runtime manifests, and passed offline failure
controls plus scoped G4. The normal launch reached controller
initialization after initially waiting on macOS Keychain; physical input
has not been proved. No daily installation or
release demo was performed. Seven phase criteria remain false.

## Handoff

C1 M0 inventory/offline checks and separate signed staging are complete;
source/candidate G4 passed. The stable c292 copy is at
`~/jarvis-local/c1-review-c292e120/Jev Voice.app`; strict signing and
byte/mode/symlink equality to the tested artifact were verified.
The daily f6 app remains unchanged. Portable model assets, full transitive
license qualification, clean-user packaging and whole-phase acceptance
remain C3 work. See [C1 handoff](../results/P4/c1-handoff.md) and
[delivery receipt](../results/P12/c1-delivery-receipt.json).
Next: C3 portable model/license work, clean-user readiness and the
authorized final install/rollback qualification. Reuse C1's inventory and
offline controls rather than restarting them. Keep source/resources
and evidence identities separate from mutable report/verdict bytes.
Preserve the old verified app and settings. Rollback restores that exact
artifact and stops only candidate-owned helpers; permission changes are
reported rather than hidden.
