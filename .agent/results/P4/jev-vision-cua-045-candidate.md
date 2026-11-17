# Cua 0.45.4 Candidate Baseline

Status: candidate-only selection following the user's request to investigate
updating Cua. No installation, production pin update, commit, push or PR is
authorized. The approved capture-input contract remains unchanged.

## Why Change The Baseline

The installed driver is the official 0.38.0 app member, digest
`b4d974a9c1c92a700cd7be7ede987aea4a1e6835e37039ce3d628b71bd5f0ca8`.
The preserved 898-file source manifest describes a historical local
integration, not that release. Its workspace version is 0.28.2 and two
cached exact-0.38 source files differ. Matching those historical hashes
does not prove correspondence with the installed binary.

The historical prototype's 49 core and 38 macOS component checks pass.
Those results remain prototype evidence, not 0.45 qualification.
Preserve its code, binaries, receipts and logs; do not package it as 0.38.

## Release Evidence

Retrieved 2026-11-09 from official GitHub and the published installers:

- Component tag: `cua-driver-rs-v0.45.4`.
- Source commit: `d96e1bc359b2cc638c7a406aad01a7276b1b416f`.
- Published: 2026-11-09T15:19:15Z, not a draft or nightly.
- The release explicitly says plain Driver SemVer is stable; GitHub's
  prerelease label protects the monorepo-wide Latest pointer.
- Both published default installers currently bake 0.44.0. An explicit
  0.45.4 selection is deliberate, not a claim that the default selects it.
- The arm64 archive exists and its published SHA-256 is
  `d42034bc69ad1abb10da6be9168f3911f744e5442837c0c6cf9faf21424f91d5`.
- No installer has been executed.

Raw evidence is in `cua-upgrade-20261109-dgaJvR/`: release/tag JSON,
published installers and exact-tag tool/contract source.
The clean, sparse source clone's HEAD matches the commit above:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/cua-upstream-0.45.4`.

## What The Upgrade Does And Does Not Solve

Recent upstream changes address exact keyboard-layout text, macOS text-input
thread affinity, foreground-control readiness and per-action opened-window
identity. Version 0.45.4 also fixes element-token middle clicks targeting
another window. These are relevant improvements, not measured Jev outcomes.

The exact 0.45.4 macOS typing, key and scroll handlers still have no
`capture_id`; their shared typed inputs also lack it. The common capture
adapter still admits clicks only and compares live image dimensions without
sealing window origin. Updating alone therefore does not meet the approved
visual-input contract.

PNG is mandatory for production capture-bound actions: 0.45.4 explicitly
mints no capture ID for JPEG. JPEG support in the model client remains
compatible, but must never permit an unbound coordinate fallback.

The documented daemon-backed embedding path, standard permission mode,
host responsibility chain and existing-profile boundary remain available.
Static presence is not runtime compatibility proof.

## Ownership And Invariants

One writer owns the new isolated source clone. The old prototype and shared
vendored source stay preserved. Do not import the historical integration
patch or its six unaccepted differences.

The relative paths owned by `jev-vision-driver-amendment.md` now apply
under the exact 0.45.4 source root, with these explicit additions and
clarifications (prefix each with `libs/cua-driver/`):

- `scripts/stage-uniffi-library.mjs` and `scripts/build-node-runtime.mjs`
  for honoring the existing isolated Cargo target directory during SDK
  staging, and preserving the pinned generator dependency lock for the
  existing N-API build. No new runtime implementation or dependencies.
- `typescript/test/native-loader.test.mjs`,
  `typescript/test/native-daemon-fixture.mjs` and
  `python/tests/test_uniffi_loader.py` for the existing generated-FFI
  round-trip owner to exercise capture IDs on typing, keys and scrolling.
  These use an owned socket fixture, never native desktop input.
- `typescript/test/electron-main-fixture.mjs` for checking actual socket
  type, ownership and permissions rather than assuming a TMPDIR prefix
  proves privacy. Long workspace paths require relative fixture socket
  addresses; the SDK's existing short native-socket fallback is preserved.
- `rust/crates/platform-linux/src/tools/{type_text,press_key,scroll}.rs`
  and the corresponding `platform-windows/src/tools/` modules. In 0.45.4
  these are real implementations; `impl_.rs` registration alone is not
  the pre-effect boundary.
- `rust/crates/platform-macos/src/tools/{pixel_route,get_window_state,get_desktop_state}.rs`.
  Review pixel-route decisions and their caller callbacks, not just the
  click handler. Own capture publication callers so window origin and
  dimensions come from the actual PNG capture, never a later guessed frame.
  Preserve existing desktop captures and their legacy click behavior.
- `rust/crates/platform-macos/src/input/keyboard.rs` for guarded variants of
  the existing native dispatch functions only. Preserve whole-payload
  physical-text preflight and Unicode batching; never replace them with
  separate per-character public calls. Review `tools/px_frame.rs` as the
  authoritative existing coordinate converter, without changing legacy
  coordinate behavior.
- `rust/crates/platform-macos/src/input/mouse.rs` for the corresponding
  internal before-dispatch callbacks. Existing click-count loops and wheel
  ticks contain multiple effects and waits inside one helper; checking only
  at its caller cannot reject a retired capture before the next pair/tick.
  Preserve event construction, click-state, routing, modifiers and cleanup.
  No new wire interface or alternate captured-input implementation.
- `rust/crates/platform-macos/src/ax/reveal_scroll.rs` for the same internal
  callback at each AXScrollToVisible attempt. Captured pixel scroll can use
  this existing generic backend; its retries must retain the capture and
  exact-window ancestry check rather than escaping through a nested helper.
- `rust/crates/cua-driver-contract/src/{lib,inputs,desktop,compatibility}.rs`
  and `src/bin/cua-contract-gen.rs`; `contract/manifest.json` and affected
  fixtures; `rust/crates/cua-driver-sdk/src/lib.rs` and its input constructors.
- `scripts/generate-uniffi-bindings.mjs`, the existing contract generator,
  contract/SDK `uniffi.toml` and bindgen sources only if generation requires
  changes. Regenerate the Python/TypeScript files and generated-file
  inventories identified by the existing generator; do not hand-edit ABI
  outputs. Review generated schemas against Rust and legacy wire fixtures.

Exact 0.45.4 has `capture_id` only on the shared captured-click variant.
Add optional `x/y/capture_id` to `TypeTextInput` and `PressKeyInput`, and
optional `capture_id` to `ScrollInput` (whose `x/y` already exist).
Omitted fields preserve old serialized requests. Update Rust record
constructors and regenerate every UniFFI consumer together, including
native ABI checks; do not claim old precompiled FFI binaries gain fields.
No unowned source changes or compiler/dependency version upgrades.

The native typing integration must extend the existing `KeyboardRoute` /
`type_text_blocking` ladder, not copy the historical prototype's separate
captured typing implementation. Exact 0.45.4 first acquires `key_scope` for
background typing and tracks `explicit_target` / `key_window_confirmed`.
Preserve those safeguards, AX/read-back behavior and native text preflight.
The physical backend validates the whole string before posting the first
event; calling it independently for each character would lose that guarantee.
Add internal before-dispatch callbacks where needed, not caller-controlled
JSON admission flags or a second capture admission.

Preserve newer upstream focus, text-layout, cancellation, permission,
mutation-lease and input-delivery behavior. Port invariants, not whole old
handler bodies. Keep one internal non-serializable admitted capability for
one top-level primitive, including its focus ladder and subsequent input.
Revalidate ownership, session/runtime generation and sealed native geometry
before later effects; never re-admit or replay a refused capture.
Preserve structured partial-effect evidence on late refusal. If focus,
activation, an AX rung or earlier wheel/text input may already have run,
do not report a later capture refusal as zero prior effects. Never blindly
replay the full mutation after a partial or uncertain dispatch.

The original amendment owns the complete negative matrix and legacy
compatibility requirements. Unsupported adapters refuse supplied capture
IDs before effects. No per-app flags or restarts, fixed Jev step ceiling,
slower per-action model or weakened consent/completion policy.

## Consumer And Qualification Gates

1. Review this baseline change against the existing G2 contract before
   changing the new source.
2. Preserve/export the historical prototype; introduce the failing guard
   and typed-contract checks on exact 0.45.4 before implementing them.
3. Use the serialized lane for locked whole-crate core, contract, macOS and
   SDK checks, contract generation/parity and release builds. No silent
   filtered-test or old-target green substituted for the new baseline.
4. Inspect the official archive, app-member signature and embedding/schema
   compatibility without replacing the installed driver. Record checks
   that cannot be performed, including non-mac native coverage.
5. Account for `Sources/JevVoice/Driver/CuaDaemonHost.swift`,
   `CuaConnection.swift`, connection pools,
   `Sources/JevVoice/Drive/VisualTarget.swift` (the actual capture-ID,
   single-PNG and image-to-driver-point gate), capture/actuation consumers,
   `ComputerControl/CuaDependency.swift`, candidate staging/signing helpers,
   `.agent/results/P4/jev-realapps.py` and their tests.
6. Keep the installed-driver constants and production manifest unchanged.
   The candidate's sealed bundled executable digest and source/patch
   receipt identify the new build; no env-based verification bypass.
7. Complete demand-driven Jev image decisions, capture-bound actuation and
   fresh independent visual outcome checks. Sign the candidate, perform
   native smoke and fresh G4 review, then the authorized controlled real-app
   A/B through the packaged app under the desktop lock.

Do not enable the new default-off fast path or shorten observation waits
merely to claim speed. Any performance change needs a real matched A/B
and unchanged targeting, cancellation and outcome proof.
No passing unit count closes P4 or authorizes installation.
