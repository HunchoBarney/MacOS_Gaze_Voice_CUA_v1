# Capture-Bound Native Accessibility Targets

G1 USER APPROVED 2026-11-09. Asked native-token exemption vs extending
the driver; user said "we should extend the shit and do everything we can
do to make it super good, super fast". Chosen: extend Cua, do NOT drop CID.
G2 design PASS0360df2a under the full implementer contract in
jev-vision-captured-ax-g2-review.md. No native edits under this amendment yet.

## Why

Read-only G2 judge0360df2a returned FAIL: native click rejects CID+
element_token; M3 requires original CID AND native identity preference.
Current pixel branch is supported by original approved driver amendment,
not a complete native-identity solution. Judge also confirmed same-label
revive keeps Swift origin unchanged; app-side session epoch fix is being
tested. See newest resume. No release or full security verdict.

## Required Contract

- Add typed captured-element input shape, preserving old native/coordinate
  callers. Native AX input carries BOTH original capture_id and native
  element token. Never silently strip either or downgrade to bare pixels.
- Common runtime validates capture private session/runtime generation,
  exact window, expiry, single-use lease AND token's original snapshot
  association. Do not assume public label or equal geometry proves same AX
  snapshot. Carry explicit association on capture publication if needed.
- Preserve nested focus shared admission without double consume, last
  native boundary checks, partial effect reporting and no replay.
- Mac uses native AX action where supported; pure pixel fallback unchanged.
  Shared contract/generated consumers reviewed; other adapters implement
  equivalence or structured explicit unsupported, never false parity.
- App selects native identity only with same combined snapshot membership
  and independent image/semantic target check. Keep all existing presence,
  location, authorization, protection, deny and original-subject checks.
- No public raw coordinates, app-specific setup, new grant, threshold
  reduction, slower per-action model or default step ceiling.
- Runtime capability checks must distinguish new captured-element support
  from v1 coordinate-only CID support, not just trust version/flag.

## Scope And Gates

One writer (main agent). Freeze app while editing isolated driver. Same
exact0.45.4 upstream baseline d96e1bc359b2cc638c7a406aad01a7276b1b416f plus
already-approved patch. Existing v1 artifact receipt preserves binary/
SDK digests. No destructive cleanup, install, pin, commit, publish or push.
Before native code: independent G2 design/consumer review; before fixes,
failure controls at strongest boundary. Whole relevant crates/bindings,
explicit platform gaps, pinned1.97.1 toolchain and disk guard. Verify
source/archive provenance and final candidate-local digest again.
No native code changed yet; exact owned paths and fail-before cases are
enumerated in the G2 report: common capture registry/runtime, contract
inputs/tests, Mac tools/adapter, conditional token/snapshot helpers,
Linux/Windows4 input tools for explicit unsupported, generated SDK/schema
fixtures and affected crate tests. App capability/target consumers follow
the native stage, not a second simultaneous write track.

## Performance

enliven loaded/read including traps. Product path is Swift/Rust, not the
tracker Chromium renderer; do not fabricate CDP counters or alter Eyes.
Keep its real-build matched A/B method: harness before optimization, same
controlled goals/native verifier, >=3 repeats, median/spread and request/
capture/native dispatch counts. Preserve v1 baseline artifact and source
digest. Use real signed app/native boundary, host traces for attribution,
not API-only or mocked latency. JSON-driven HTML must include regressions.
Before/after outcomes and speed remain UNMEASURED. Source review first,
desktop lock/approved owned windows for live bench. Existing P4 bars stand.

## Native Research So Far

Root isolated source:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/cua-upstream-0.45.4`

platform-macos/tools/capture_binding.rs has MacCaptureBindings,
AdmittedWindowPixel and guarded_input/before_ax_input already checks exact
AX window. Common CapturePublication has session generation, target/PNG/
dimensions but NO AX snapshot association field. get_window_state~689
publishes when snapshot_id exists but does NOT pass sid into publish_window.
Do NOT mistake session_generation for snapshot_id. ClickPosition currently
Coordinates/Element/CapturedCoordinates; captured-element variant absent.
Read actual files before choosing design.
