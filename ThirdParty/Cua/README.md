# Cua integration provenance and recovery

The app verifies `/Applications/CuaDriver.app/Contents/MacOS/cua-driver`
against SHA-256 `b4d974a9c1c92a700cd7be7ede987aea4a1e6835e37039ce3d628b71bd5f0ca8`
(the official upstream `cua-driver-rs` **v0.38.0** release build, tag
`cua-driver-rs-v0.38.0` at commit `85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19`;
archive digest verified against GitHub's published asset digest on 2026-10-25). The authoritative
runtime constants are in
[`CuaDependency.swift`](../../Sources/Jarvis/ComputerControl/CuaDependency.swift).
Do not update the pin just to accept a different build.

Historical note — v0.32.0 (a prior pin; the current pin is v0.38.0, above)
superseded the local fork we previously ran: upstream landed the
foreground-chord modifier fix (0.30.4), launch-before-snapshot wait (0.31.0),
element-token snapshot-store resolution (0.31.0), cursor reveal for
keyboard-first actions (0.31.0), and the post-navigation page-title refresh
(0.30.2). Its `type_text` runs the AX→CGEvent ladder internally, so the
fork's `type_chars_only` arg was removed from our calls. Browser `target_id`/
`tab_id` are re-minted per `get_browser_state` read — callers must use ids
from the same snapshot, immediately.

The current canonical installer bakes 0.37.0. This is an intentional exact
0.38.0 component-release selection, not a claim that the default installer
currently selects it. The release explains that GitHub's prerelease label
protects the monorepo-wide Latest pointer; plain component SemVer is stable.
Archive SHA-256:
`5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72`.
Use the app-bundle member, not the separate bare executable.
The existing embedding/liveness/standard-permission flags and backward
tool schemas pass isolated preflight; signed Jev runtime acceptance is
recorded under `.agent/results/P3/closeout02/cua-upgrade/` in the
`harness-archive-2026-11-19` tag.

Prior pins (recovery only):
- `54e5d48128fb62323366c49b6be480ccef83cdee23bd7fc1f19431347a5df86b` — upstream
  v0.34.0, prior pin; preserve the old application and embedded vendor bytes
  before replacement. Never silently fall back to it under the new pin.
- `656ff1c1aea1ee063d7735bcd8eb4491346971d4fb3199c6d2260b40aae83c66` — upstream
  v0.32.0, prior pin.
- `eb08ff7afb89804822c4d7026df3c211feb23e5ab3926fa5ea2007aa08916379` — local
  combined watchdog + scroll-readback + menu-focus candidate (0.28.2-based),
  kept installed at `/Applications/CuaDriverLocal.app` as rollback.
- `699d330bd1cd4e2255f0c99e889f1358952de246254fac7e4417b08dd6578d2a` — earlier
  local build, preserved under `~/Library/Caches/Jarvis/rollback/`.

## Embedded driver (packaged app)

`make app` runs `fetch-embedded-binaries.sh`, which stages the pinned
executables under `build/vendor/` and verifies each against the
`vendored_binaries` pins in `source-manifest.json` — a mismatch fails the
build. The bundle then carries `Contents/Resources/cua-driver` plus the
vendored Codex runtime at `Contents/Resources/CodexRuntime/` (entrypoint
`CodexRuntime/codex`, the npm `@openai/codex` darwin-arm64 `vendor/` tree
preserved so `codex-path`/`codex-resources` resolve).

At runtime `CuaDependency` resolves the bundled driver first and falls back
to the installed app for unpackaged runs. `CuaConnection` spawns the bundled
binary as `serve --embedded` (env `CUA_DRIVER_EMBEDDED=1`,
`CUA_DRIVER_HOST_BUNDLE_ID`, `CUA_DRIVER_EMBEDDED_HOST_PID`; args
`--parent-liveness-stdio --no-permissions-gate --socket <private>
--host-bundle-id com.karanvirkang.jarvis --permission-mode standard
--grant existing-profile`) on a private socket, then speaks MCP through
`mcp --embedded --socket <private>` on stdio — the driver's documented
host contract (`Skills/cua-driver/EMBEDDING.md`), so Accessibility and
Screen Recording attribute to `com.karanvirkang.jarvis`. The daemon's
stdin is a liveness pipe: host exit closes it and the daemon exits.

The pinned binary is the signed app-bundle member
(`.../CuaDriver.app/Contents/MacOS/cua-driver`) of the release tarball; the
bare top-level `cua-driver` member is a different build and does not match
the pin.

## Preserved source

- Upstream: https://github.com/trycua/cua
- Base: perception PR #3943, `b703a8d17fb513c6288f247f710d30643abd068d`.
- Last recorded local integration revision: `662e9ddb2e2fd6ded048635713e199b3476926a6`.
  Its Git object database is unavailable; this is historical identity, not a
  claim that a reconstructed checkout will have that commit ID.
- `local-integration.patch`: the 30 changed/added files relative to that base,
  recovered by byte comparison with the pinned upstream archive.
- `source-manifest.json`: historical hashes of all 898 preserved local source/config/fixture
  files, executable-file inventory, and the patch. The working tree is sparse; absent upstream paths are not
  treated as deletions. Generated builds, dependencies and models are excluded.
- `LICENSE.md`: upstream license. Preserve upstream notices in reconstructed builds.

The patch includes the local perception artifact tooling and native control/schema
repairs. The detailed adoption/test history was in `docs/voice-ui/EVIDENCE.md`;
the `docs/` tree was removed from this repo (a93f7d1) — recover it from git
history before that commit if needed. It is recovery material,
not a newly reviewed or accepted upstream release.

## Reconstruct into a new directory

Do not run these commands inside the existing broken Cua checkout. Set the first
path to a new, empty destination; the other path is your current Jarvis checkout.
The clone downloads upstream source and needs network/storage; it is not automatic
Conductor setup.

```sh
git clone --no-checkout https://github.com/trycua/cua.git /path/to/new-cua-source
git -C /path/to/new-cua-source checkout --detach b703a8d17fb513c6288f247f710d30643abd068d
git -C /path/to/new-cua-source apply --check /path/to/Jarvis/ThirdParty/Cua/local-integration.patch
git -C /path/to/new-cua-source apply /path/to/Jarvis/ThirdParty/Cua/local-integration.patch
python3 /path/to/Jarvis/scripts/verify-cua-source.py /path/to/new-cua-source
```

This verifies source content, not binary reproducibility. Build from the restored
Driver's Rust directory using its pinned toolchain and lockfile, following its
own instructions. The recorded build command is
`cargo build --release --locked -p cua-driver -p cua-perception`.
Do not replace the installed Driver during cleanup. Rebuilding/signing may change
binary identity and macOS permission requirements; installing a new dependency
requires separate integration validation and an intentional pin update.

## Models and local state

The current source snapshot, pinned Driver and perception bundle are also shared
as private release assets. The collaborator handoff (`docs/HANDOFF.md`) was
removed with the `docs/` tree (a93f7d1) — see git history before that commit.

The source patch preserves local artifact tooling/lock metadata. The sparse source
tree under `development/Jarvis/cua-source/` is now tracked by Git and includes
later unaccepted candidate edits, so it does not match the historical manifest
byte for byte. Large downloaded model/runtime assets, export environments and
sealed perception bundles remain in `development/Jarvis/`, where present. Those
assets are not part of this Git repository.
Use the hash-verifying upstream tooling and recorded evidence to reconstruct them;
do not claim a fresh source checkout is a fully configured runtime.

The existing source still lives at `development/Jarvis/cua-source`; its `.git`
points to a missing worktree database. Nothing in this cleanup rewrites that pointer
or deletes its builds. Run the verifier above against it to compare the preserved
snapshot. The storage-and-recovery doc (`docs/LOCAL-DEVELOPMENT-STORAGE.md`)
was removed with the `docs/` tree (a93f7d1) — see git history before that commit.


## Unaccepted execution-simplification candidate

`launch-watchdog-candidate.patch` is a separate, narrowly reviewed delta **after**
the preserved `local-integration.patch` snapshot. It is not part of the installed
runtime or baseline source manifest. It makes an explicit foreground request retire
only that PID's detached background-launch watchdog, with synchronization against
queued/in-flight restoration. Existing ordinary guards remain active.

The workspace-local candidate passed 31 focused Rust tests, locked release build,
strict binary signature verification, and forward/reverse patch recovery. Its
executable SHA-256 is
`b8be58db2df46c27486e66d2861a5ccd12fd06b350fbdc583057212320c7a6de`.
Its own isolated `mcp --direct --embedded` permission probe reported Accessibility
and Screen Recording unavailable under host attribution. Live repair acceptance
is therefore outstanding; do not install it or change the production pin on the
strength of these build/tests. Plain `mcp` would proxy to the installed broker and
would not prove the candidate code.

To reconstruct for review, first reconstruct and verify the baseline above, then
run `git apply --check` followed by `git apply` with this candidate patch in the
new checkout. Reverse only this delta with `git apply -R` after checking it applies.
The baseline verifier intentionally reports these three changed files after the
candidate patch. The scoped record (`docs/EXECUTION-SIMPLIFICATION-REPLACEMENTS.md`)
was removed with the `docs/` tree (a93f7d1) — see git history before that
commit for remaining acceptance requirements. No dependency versions were changed.

## Unaccepted scroll-readback candidate

`scroll-readback-candidate.patch` is a separate two-file delta after the preserved
source snapshot; it can coexist with the three-file launch-watchdog delta. It is
not installed and does not change the production executable pin. It carries the
retained DOM scroll target's before/after offsets and unchanged bounds into Cua's
existing closed action-result contract. Only exact requested movement (clipped to
measured bounds) receives `confirmed` with readback evidence. No movement is
`suspected_noop`; missing, partial, contradictory, disconnected or changed-bounds
evidence is `unverifiable`. Numeric offsets and target IDs stay out of the public
action result. Negative/RTL offsets and unsettled smooth scrolling are not
confirmed by this candidate. Other pointer routes retain their existing behavior.

The synthetic route still delivers its existing wheel event and `scrollBy` call;
this delta includes wheel-handler movement in readback so an extra effect cannot
silently confirm the requested displacement. It does not add mutation retries or
claim that a confirmed single scroll proves an entire user goal.

Apply with `git apply --check` then `git apply` in a reconstructed local snapshot.
Focused checks, from the Rust workspace and Jarvis root respectively:

```sh
cargo test --locked -p cua-driver-core --lib browser::
node ThirdParty/Cua/scroll-readback-candidate.test.mjs development/Jarvis/cua-source/libs/cua-driver/rust/crates/cua-driver-core/src/browser/pointer.rs
```

The JavaScript check uses a DOM test double and the actual producer source. These
offline checks do not establish Chrome behavior or live Jev repeated-action
acceptance. The isolated candidate must still pass its own permission probe and
the serialized live workflows before any production integration or deletion.

The reviewed combined watchdog/scroll release build passes strict binary signature
verification and has SHA-256
`a4fcfdd7a74c317ecd4a9364a59c745c1975c5c6262f5fafad6c31dcd3381624`.
Its final isolated permission probe still reports both grants unavailable. TCC
logs identify Conductor's bundled `codex/0.154.0/codex` executable as the responsible
subject, despite Conductor itself having a visible Screen Recording grant. Do not
infer TCC responsibility merely from process ancestry or Driver's parent-PID field.


## Unaccepted menu-focus candidate

`menu-focus-candidate.patch` is a one-file delta after the preserved integration
snapshot, independent of the watchdog and scroll patches. An isolated embedded
process reproduced a stale `NSWorkspace.frontmostApplication` value even after
WindowServer and AX verified exact activation. Menu readiness now prefers the
existing live process comparison (including a definite negative), while retaining
exact AX focus and stability checks. Prior-owner capture uses the same live
comparison over visible ordinary windows, falling back to existing NSWorkspace
behavior when none can be found. That fallback remains a limitation.

The combined release executable has SHA-256
`483b693060416b8cdd8088fde1140e6868d73dee72870b661f7efd4b7ec7cdf5`.
Eleven focused Rust menu tests, strict signature validation and byte-exact
forward/reverse patch recovery pass. Isolated live checks observe a new document,
unchanged source content, and cross-app focus restoration. Full native agent
acceptance still fails on payload/replay behavior; this is not an installed or
promoted runtime. The previous combined binary and menu source are preserved in
`development/Jarvis/staging/menu-focus-baseline/`. The earlier permission-blocked
results above are historical: the user-enabled Codex executable now reports both
grants true. See scoped evidence for the complete checkpoint.
