# Proposed Driver Capture Guard Amendment

Status: USER APPROVED "Approve driver safety fix", including isolated
ownership, affected-contract review and a candidate-local pin. No global
installation authorized. Expanded G2/owned-path contract PASS b0eba62d.
Source provenance correction: the 898 hashes reconstruct the HISTORICAL
local snapshot, not necessarily the 0.38 release source. Two cached exact
0.38 files differ. Prototype must NOT be packaged as 0.38.
User now permits considering a newer Cua release and requested research
instead of automatically staying on 0.38. No global installation granted.
Original G1 prohibited driver upgrades. Earlier independent
G2 follow-up b0eba62d returns FAIL for complete generic visual input under
that restriction. App-only transport/capture work remains green, not
release-qualified.

## Evidence

The hash-pinned installed 0.38 driver was queried through tools/list.
No app opened, no model call or desktop mutation ran. Receipt:
`vision-readonly-9a843ce30cc14e5d93359f4ec39cb0c2/capture.json`.
Subject is explicitly pinned-driver-only, not signed-product integration.
Its three guard regressions pass after failing first; a driver-only
session cannot start the product actor or read its API key.

Actual schemas are in that directory's `schemas.json`:

- click accepts capture_id and consumes the model-read image atomically.
- type_text, press_key and scroll accept image x/y but no capture_id.
- Exact-window target alone does not bind those coordinates to the image
  Jev actually read. A later screenshot cannot undo a wrong input.

The vendored snapshot is tracked by Jarvis, not a separate Cua git repo.
Relevant source files were individually hash-checked against the pinned manifest.
type_text.rs, press_key.rs, scroll.rs and shared inputs.rs match exactly.
No Cua source was changed.

G2 evidence: pixel typing does not check capture generation; scroll uses
the current window frame/scale rather than consuming the source capture.
Capture-bound click followed by a verified AX/focused text identity is a
safe existing path, but does not cover truly opaque typing or scrolling.
There is no approved basis for quietly using unguarded image coordinates.

## Recommended Expansion

Keep the requested full generic fallback. Add optional, backward-compatible
capture_id admission to pixel typing, key and scroll paths, using the
existing common capture registry and immutable screenshot transform.
Reject missing/stale/foreign/moved/consumed captures for Jev visual input.
Do not expose arbitrary desktop scope or widen existing permission.
Old nonvisual/AX callers keep their existing behavior.

Coordinate ownership before changing Cua. Use an isolated owned driver
patch/worktree; preserve the shared checkout's unrelated work, existing
pinned binary, receipts and daily installation. Main agent implements;
only independently authorized reviewers may help, read-only.

Review shared input/schema/generated consumers and affected platform
adapters. Write focused fail-first admission tests with input sinks,
then native Mac smoke on the exact new candidate. Unsupported/unreachable
platform evidence is reported explicitly, not claimed green.
Review the driver pin/source-manifest and app consumers through G2/G4.
Build/sign a candidate-local driver and update only its explicit pin and
receipt path. No global driver or daily app installation, PR, push or
commit without separate approval. No app-specific flags or setup.

Existing P4 reliability, latency, consent, cancellation, window and
completion bars remain unchanged. Full real-app A/B still follows.

## Alternative Only If User Chooses It

Keep current driver and explicitly constrain visual input to capture-bound
clicks plus verified AX/DOM/focused identity primitives. Image-only
typing/keys/scroll return named unavailable results. This is a narrower
feature, not completion of the original generic input goal.

## Expanded G2 Implementation Contract

User chose the full driver fix, NOT the alternative. One writer (main
agent) owns `jarvis-v1-vision-driver`; the existing shared Cua source
remains read-only. App work in `jarvis-v1-agent` pauses while driver code
is edited. No second implementation helper or third parallel write track.
Read-only reviewers are authorized.

### Baseline

The new Jarvis worktree is detached at 4b263b3. Its vendored source had
six preserved unaccepted changes described by ThirdParty/Cua/README.md.
Only in the newly created isolated copy, reverse-check/apply the menu,
scroll-readback and launch-watchdog candidate patches. This reconstructs
ALL 898 pinned manifest entries with ZERO mismatches (observed).
Original shared source, patches, artifacts and installed binaries remain.
Those six reconstruction differences are baseline, not our new fix.
No unrelated candidate is promoted through this work.

### Owned Paths

Driver paths below are relative to the isolated worktree, prefixed by
`development/JevVoice/cua-source/`:

```
libs/cua-driver/rust/crates/cua-driver-core/src/capture_registry.rs
libs/cua-driver/rust/crates/cua-driver-core/src/capture_runtime.rs
libs/cua-driver/rust/crates/cua-driver-contract/src/inputs.rs
libs/cua-driver/rust/crates/cua-driver-contract/src/lib.rs
libs/cua-driver/rust/crates/cua-driver-contract/src/desktop.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/capture_binding.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/click.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/type_text.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/press_key.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/scroll.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/mod.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/px_frame.rs
libs/cua-driver/rust/crates/platform-macos/src/tools/get_window_state.rs
libs/cua-driver/rust/crates/platform-linux/src/tools/impl_.rs
libs/cua-driver/rust/crates/platform-windows/src/tools/impl_.rs
libs/cua-driver/rust/crates/cua-driver-sdk/src/lib.rs
libs/cua-driver/contract/manifest.json
libs/cua-driver/contract/fixtures/**
libs/cua-driver/contract/README.md
libs/cua-driver/python/.cua-driver-uniffi-generated-files
libs/cua-driver/python/src/cua_driver/_native.py
libs/cua-driver/python/src/cua_driver/_native_contract.py
libs/cua-driver/typescript/.cua-driver-uniffi-generated-files
libs/cua-driver/typescript/src/native/**
```

Generated outputs only via existing generators; never hand-edit ABI
records. Baseline reconstruction changes only the six patch-listed files.
No other Cua implementation paths without a documented ownership update.
Build/test artifacts stay inside this isolated workspace's development.

Main app consumer/receipt audit and permitted candidate-only edits:

```
Sources/JevVoice/ComputerControl/CuaDependency.swift
Tests/JevVoiceAppTests/CuaDependencyTests.swift
ThirdParty/Cua/README.md
ThirdParty/Cua/vision-capture-candidate.patch
ThirdParty/Cua/vision-capture-candidate.json
.agent/results/P4/jev-clone-stage.py
.agent/results/P4/jev-realapps.py
.agent/results/P4/jev-vision-probe.py
.agent/results/P4/test_jev_clone_stage.py
.agent/results/P4/test_jev_vision_probe.py
.agent/results/P4/jev-vision-driver-*.json
.agent/results/P4/jev-vision-driver-*.log
scripts/verification-lane.sh
.agent/CONTRACTS.md
.agent/PROGRESS.md
.agent/phases/P4-taskloop-jevdecider.md
.agent/results/P4/jev-vision-*.md
```

Existing stock installedExecutable/executableSHA256 and the original
source-manifest production binary pin remain unchanged. CuaDependency
already prefers a bundled executable with its outer-sealed post-signing
JevCuaDriverSHA256. A candidate uses that existing mechanism; do not add
an arbitrary environment override or bypass verification. New receipt
binds baseline source-manifest digest, new patch/source hashes, candidate
driver pre/post-sign hashes, staged bundle and signature. Harness selects
that exact receipt-bound bundled driver, not the hardcoded global path;
old baseline keeps its old explicit hash. Preserve resource caveats.

### Single Admission And Guarded Effects

One internal, non-serializable admitted window-pixel capability is created
from capture_id, authenticated binding/session generation, pid/window,
source x/y and the capture registry's immutable transform. No JSON key,
model result, FFI record or second tool invocation may forge it.
Public callers consume a capture exactly ONCE per top-level primitive.
Normal permission/target/background mutation leases still apply.

NativeActionDimensions gains optional validated window geometry without
breaking its existing constructor. Mac window publication seals the
captured logical x/y/width/height as well as native image dimensions.
Current geometry must equal that sealed geometry at admission; movement,
resize, scale change, missing/foreign window refuse. Desktop/legacy
dimension-only registry uses retain their current behavior. Origin must
come from the actual capture's window metadata, not a later guessed frame.

Mac capability construction uses this admission and retains frozen
window/point/binding/action identity. The capability is passed as a typed
Rust argument to internal focus/click helpers, never serialized or
re-admitted in focus_by_pixel. The existing background-focus/explicit
foreground-press ladder can borrow it within the SAME top-level primitive
only, at the same point/window/binding and permitted delivery mode.
Before EACH further native effect (including the key/text after focus
and a fallback after the 120ms settle), revalidate live ownership and
sealed geometry. If changed, stop before further effects; do not claim
zero earlier effects if a focus already dispatched. A capture-bound
refusal/error must never fall through to an unguarded legacy path.
No automatic replay of failed mutations or cross-call capability reuse.
Postcondition verification still remains independent and may be unknown.

New public capture_id on type_text/press_key/scroll is optional for wire
compatibility, WINDOW PIXEL PATH ONLY. It requires nonempty string id,
finite x/y, positive matching pid/window (or equivalent exact window
target). Reject desktop scope, absent coordinates/window, zoom or mixed
AX element/snapshot addressing BEFORE any effect. Null/malformed supplied
id must not silently become the legacy branch. Old AX, focused, desktop
and no-image callers without capture_id retain behavior.

Click uses the same internal capability where possible; existing desktop
click behavior is not expanded. Keys and typing focus/dispatch are part
of their one admitted primitive. Scroll consumes once before pixel wheel
delivery and uses the frozen capture transform, never a new screenshot
scale as substitute authority.

The portable shared DTO/schema and generated SDK consumers expose the
optional window-pixel extension coherently (x/y where absent plus id).
Windows/Linux adapters explicitly reject supplied capture_id BEFORE
effects until equivalent window-lifetime/geometry binding exists.
Describe this as current adapter capability, not an inherent OS limit.
No universal-support claim: native Mac is the product target; other native
platform proof remains a named coverage hole. Legacy callers unchanged.

### Milestones And Checks

1. Freeze isolated 898-file baseline and ownership; expanded G2 review.
2. Write fail-first registry/geometry and per-tool contract/input-sink
   tests before implementation. Cover stale/foreign/session/generation,
   moved/resized/scaled/closed/expired/consumed/malformed, invalid points,
   missing/mixed/desktop addressing, and zero effects on initial refusal.
3. Implement one capability, guarded focus ladder and all three tools.
   Test background success, foreground fallback, failure, movement during
   settle (no later click/key/text), one consumption, forged internal JSON
   ignored/refused, and independent outcome verification not fabricated.
4. Shared DTO old-wire roundtrip, generated parity, unsupported-adapter
   pre-effect refusal and existing AX/no-image tests. No hand-edited FFI.
5. Locked/offline focused Rust tests, release build and binding generation
   through the main serialized verification lane. Ask before dependency
   network access if offline cache is insufficient. New candidate signing
   and pin receipt only; no installation. Run fresh independent G4.
6. Finish app M2/M3 and conduct matched signed real-app A/B under the
   desktop lock; exact independent oracles, no app flags/restarts.
   P4 reliability/latency/human gates remain unchanged and open.

Main runner scopes will use this fixed owned worktree with explicit
manifest/target paths; all builds/tests stay serialized and freeze writers.
Any failed or unavailable check remains recorded as such. No acceptance
file may turn green merely because these component tests pass.
