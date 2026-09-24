# Execution simplification replacement record

2026-09-23 checkpoint; governed by [the approved plan](EXECUTION-SIMPLIFICATION-PLAN.md).
This is investigation and isolated candidate work, not acceptance or a migration gate closure.

## Fresh verification — 2026-09-24

This addendum supersedes the package and suite status below. It does not close
Steps 4, 6, 7, or 8.

- **Setup path:** the document fixture now uses `FileManager.default.temporaryDirectory`,
  and `launch_app` follows the installed schema without the unsupported `session`
  property. Setup resolves one exact window, requires Cua to confirm that window
  in front, then waits a bounded interval for an editable AX body before asking
  Jev to select it. Two focused `CuaSetupTests` pass in the full suite. The opt-in
  live setup attempt using the corrected temp path and launch schema found its
  TextEdit window but no editable body; no text was sent. A read-only follow-up
  showed three exact `Jarvis-Check-*.txt` windows with an empty AX tree and
  `ax_window_unresolved`. The direct exact-window focus probe returned
  `process_activated=false` and `exact_window_effect.verified=false`.
- **External desktop condition:** the console session was locked (`loginwindow`,
  `CGSSessionScreenIsLocked=Yes`). Cua still reported Accessibility and Screen
  Recording granted, so this is not evidence of a missing CuaDriver grant. The
  locked desktop prevented a meaningful setup/package UI acceptance check. The
  CUA app lookup timed out, and `System Events` denied assistive access to the
  separate `osascript` automation process. No permission setting was changed.
  Details and exact logs are in
  `.context/execution-simplification/desktop-lock-check-2026-09-24.txt`.
- **Keyboard candidate:** the live trial stopped before any key dispatch because
  Cua exposed no editable controls for the disposable fixture while the session
  was locked. Its diagnostic log is
  `.context/execution-simplification/native-keyboard-candidate-diagnostics-2026-09-24.log`.
- **Verification:** the Makefile `make test` target passes through a
  workspace-local `swift` shim that adds the scratch path
  `.context/execution-simplification/swift-scratch-native-new-document`. All six
  tooling tests pass; Swift reports 317 tests, 31 opt-in skips, and zero
  failures. The exact run is logged at
  `.context/execution-simplification/make-test-workspace-scratch-2026-09-24.log`.
  A direct unwrapped `make test` still encounters the preserved prior-workspace
  `.build` cache before Swift compilation; that cache was left unchanged.
- **Production repetition gate:** `CuaVoiceRuntime` does not override
  `CuaTaskAgent.allowConfirmedRepetition`, whose initializer default is `false`;
  only test harnesses opt in. The production loop filters completed effect
  identities from later choices, so the same effect cannot be selected again
  within one task even when a result contains confirmation evidence. Retain this
  protection until the pinned runtime passes live outcome and repeated-action
  proofs; the uninstalled scroll patch's two-position sample does not authorize
  production enablement.
- **Static maintenance inventory:** comparing baseline `d756cf3` with scoped
  implementation commit `5bec4a6`, the tracked production Swift scope
  (`Sources/JevVoice/ComputerControl` and `Sources/JevVoiceCore/Models`) grows
  from 17 files / 1,883 physical lines to 19 files / 3,083 lines (+1,200, about
  64%; physical counts include comments and blank lines). The implementation
  diff adds 2,589 net Swift test lines, 139 fixture lines, 117 workspace-tooling
  lines, and three uninstalled Cua patch candidates totaling 684 patch lines,
  plus a 54-line JavaScript candidate test. `Package.swift`, `Package.resolved`,
  and `Makefile` are unchanged; production retains the existing Swift-to-pinned-
  Cua boundary. This inventory excludes prose and generated/ignored development
  assets and does not measure behavioral complexity or prove simplification.
  Since no production protection has been retired, current evidence shows added
  implementation and proof coverage rather than a net maintenance reduction.
- **Final package:** `make dist` produced the r2 arm64 app and ZIP under
  `development/JevVoice/verification/execution-simplification/scoped-delivery-2026-09-24-final-r2/`.
  Bundle ID is `com.chriswozniczek.jevvoice`; executable SHA-256 is
  `476ce17968443f35566f66641308b54a40bcaaf58136bdc9c5e99806f5d7559b`; ZIP
  SHA-256 is `07858bd753c5d43eadec8c7b2a058d36a4927fc498a5c890f11400579059ea2b`.
  Strict signature verification, ZIP integrity, extraction, and byte-for-byte
  executable comparison pass. The final r2 app was not launched because the
  console session was locked. Packaged setup state and task acceptance remain
  open; `DELIVERY.md` records the artifact.
- **Focused source delivery:** commit `5bec4a6` contains the scoped source,
  regression tests, and implementation/evidence documents. It was not pushed.
  Ignored `.context/` logs and `development/` source, recovery, and package
  outputs remain local.
- **Preserved side effect:** an earlier, pre-fix package setup invocation created
  a zero-byte `Jarvis-Check-7F3ECAB1-8B43-4469-9D76-1E6193EDC0E4.txt` through the
  legacy `~/Library/Caches/JevVoice` link into the other checkout's development
  folder. That external file was not removed or modified. Current setup fixtures
  use the system temporary directory.

No production protection was removed. Pinned-runtime repeated scrolling,
remaining native/browser action families, cancellation/timeout inspection,
matched complexity measurements, and packaged task acceptance are still open.

## Fresh verification — 2026-09-23

This status supersedes the earlier scroll and candidate-permission statements in
the checkpoint below. On the pinned Driver, a locked live run now observes one
500 px scroll and then returns an incomplete refusal before another mutation or
success claim. The same repeated-scroll request passes on the hash-bound,
uninstalled combined candidate with two independent fixture positions, `[500,
1000]`. The candidate's direct permission probe still reports false for
Accessibility and Screen Recording, but that did not prevent this DOM-only
loopback browser test; no native-action readiness is inferred.

A fresh pinned-runtime TextEdit run creates a new document, inserts the exact
requested text, and preserves the original seed after the diagnostic nine-second
settle. It does not prove immediate launch behavior or packaged acceptance. The
full Swift suite passes 314 tests with 29 opt-in skips in a workspace-local
scratch directory; the six tooling tests pass. The default `make test` attempt
still fails before compilation because the preserved `.build` cache refers to
the prior checkout path. No production path or safeguard has been removed.

Latest checkpoint: the installed pinned Driver's 58 tools have been described and
assigned a host, observation, candidate, or exclusion path. Candidate actions use
owner-bound IDs and bounded pages; 600-action offline coverage reaches every
target. The normal runtime uses one bounded observe–choose–act–verify loop, while
new action families remain isolated. Current real Jev/Cua proofs: exact native
insertion with preserved seed text; quoted browser search and navigation; exact
direct navigation; host-approved upload of one disposable 32-byte file with
matching SHA-256; one hover with `mouseenter` and no click; and one accepted
JavaScript confirmation dialog. The native Return candidate still produces no
newline and is refused after one dispatch.

The current installed pinned Driver repeated-scroll trial produced one 500 px
scroll. The runtime then dispatched a page click and returned a `Completed`
result; independent fixture readback rejected the two-effect expectation. This
was false completion, not a conservative refusal. A host guard now stops after
reobserving an unconfirmed scroll and prevents both another action and a success
claim; focused tests pass, but the live workflow was not rerun. An earlier
two-scroll sample remains historical only.
The uninstalled scroll-readback binary reports Accessibility=false and
Screen Recording=false for its embedded host; the installed runtime pin was not
changed. Unquoted `Type`/`Write` payloads with possible control text now refuse
before dispatch; exact quoted text and explicit `dictate`/`say` literal prefixes
remain supported.

Fresh scroll-focused checks on 2026-09-23 confirm the isolated combined candidate
(`483b693060416b8cdd8088fde1140e6868d73dee72870b661f7efd4b7ec7cdf5`) still
reports Accessibility=false and Screen Recording=false for the current embedded
host (`.context/execution-simplification/scroll-candidate-permissions-2026-09-23.json`).
No live action was sent through it. The 11 producer scenarios, 164 Rust browser
tests, and 28 `CuaTaskAgentTests` pass; those checks validate the contract and
unconfirmed-outcome guard only. A fresh two-effect live readback through this
current host remains blocked on its user-controlled macOS grants. The earlier
permission-enabled candidate sample remains separately recorded and does not
replace that fresh proof.

An earlier 2026-09-23 package was signed, archived, extracted, and opened. Its
Voice pane reported Accessibility missing and Microphone selected. No permission
control was clicked. The app changed to a listening state, so no further UI action
or packaged task was attempted. After a schema review, setup was changed to use a
typed `check_permissions(prompt:false)` call without a `session` field; the new
package has a verified signature/archive but was not opened. A production
`CuaVoiceRuntime` live fixture passed once: one 32-character insertion into the
addressed native field, prior 47-character seed preserved, five Jev requests, one
`type_text`, 10.071 seconds total. A separate earlier production-runtime trial
proved two unrelated background tasks in separate disposable apps and preserved
the prior foreground PID; same-app windows and visible cursor identity remain
unproven. No protection or production path has been retired; no net simplification
is established. See [scoped evidence](voice-ui/EVIDENCE.md) for commands, logs,
artifact identities, and limitations.

## Baseline and recovery — step 1

Jarvis baseline: `d756cf37931d12a85d2e35aef45d9ff3dd7664b8`.
The 14 pre-existing modified/untracked files were preserved in
`.context/execution-simplification/baseline-workspace-changes.tar.gz`, with tracked
diff and path inventory alongside it. This includes the setup work and previously
untracked simplification plan. Recover by extracting into a new directory and
comparing specific files, not overwriting subsequent edits. Git preserves committed
source. No credentials were copied.

Configured Conductor setup succeeded. The manifest verifier passed all 898 files
in workspace-local `development/JevVoice/cua-source`; this was the pre-repair source baseline. A bounded local candidate repair is recorded below.
Shared reference links remain inputs only. The installed Driver matches SHA-256
`699d330bd1cd4e2255f0c99e889f1358952de246254fac7e4417b08dd6578d2a`.
The preserved app resolves to the main checkout's development bundle, is ad-hoc
signed and has ID `com.chriswozniczek.jevvoice`. It was not replaced or launched.
Baseline `make test`: 248 Swift tests, 18 skipped, zero failures; tooling passed.

## Integration decision — steps 2–3, provisional until live proof

Select the existing Swift/private-stdio boundary and one native adaptation of the
upstream observe/choose/act/verify recipe. Retain Jev and the installed Driver pin.
This selects a process boundary, not permission to retain all current mechanisms.
Stage replacements inside it without another production planner or silent fallback.

The pinned Python `run.py` creates isolated Chromium, builds fixture-specific
candidates and verifies via the fixture `/state` endpoint. `choose_action.py`
excludes tool names/arguments and never executes. External integration still needs
native action construction, authority checks, task/approval/provider IPC,
cancellation propagation, interpreter/SDK bundling and helper lifecycle management.
Swift retains existing tested task cancellation, approvals, Keychain and provider
routing without those new dependencies. The baseline ComputerControl + core Models
inventory is 1,883 lines; the staged adapter adds code until replacements are proven
and old code removed. No net simplification is claimed yet.

PR [#3961](https://github.com/trycua/cua/pull/3961) refreshed through GitHub on
2026-09-21: open, not draft, not merged; head
`5960dd1487ad4de1d2cde0eae27d06fac5bc2ca2`, base
`201732fffd81a40818be7ce2e04269aec962bc42`. Its `factorized.py` still takes fully
constructed actions. Selection, goal-achieved and reobserve judgments do not add
native execution or application postconditions. Its confidence thresholds and
fail-open result are not Jarvis acceptance. Do not add its extra backend clients
or use a model completion gate instead of observable success. No PR code was copied.

Transferable upstream contracts: immutable candidate ID to original action,
bounded choices with abstention/reobservation, persistent named session,
snapshot/capture-bound targeting, no uncertain mutation retry, independent outcome
checks. Native adaptation needs Jarvis and live tests; upstream fixture tests are
not native proof. Current TypeSafe API and Choice documentation were read via HTTP;
the existing Swift HTTP endpoint/typed choice interface agrees with them.

## Replacement map — step 2

### Installed Driver action coverage — 2026-09-22

The installed executable at `/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local`
was queried read-only with `list-tools` and `describe` for all 58 names. Its actual
schemas and descriptions are summarized in the ignored run artifact
`.context/execution-simplification/installed-tool-contract-summaries-2026-09-22.txt`.
The inventory below records the host routing decision and evidence boundary; it
does not treat a schema or an accepted tool call as an application effect.
Installed hash remains
`699d330bd1cd4e2255f0c99e889f1358952de246254fac7e4417b08dd6578d2a`.

| Path | Installed tools and grounded contract |
| --- | --- |
| Existing production Jev mutations | `click`, `invoke_menu`, `scroll`, `type_text`, `browser_click`, `browser_type`, and `browser_pointer` with an observed scroll-capable ref. Native actions carry exact window/element token arguments; Cua retires snapshot tokens when a fresh snapshot supersedes them. Browser calls carry opaque target/tab/ref values from the current session and snapshot. Browser typing requires the current editable ref and exact supplied text; it appends unless replacement was explicitly bound. Browser click uses the explicitly requested `dom_event` route, whose dispatch does not itself prove activation. These existing routes remain under host postconditions and repetition protection. |
| Isolated candidate-only mutations | `right_click` and `double_click` on exact native AX elements whose advertised actions support them; `set_value` only for one user-quoted value that uniquely matches a currently observed enabled popup option; `press_key` only for quoted Return/Enter on a readable native text area, with an independent exact one-newline readback; `browser_navigate` only for an exact quoted HTTP(S) URL; `browser_dialog` only for the exact current dialog id plus explicit accept/dismiss text, with approval for acceptance and exact quoted prompt contents; `browser_set_input_files` only for one exact user-supplied canonical regular file, one uniquely observed upload ref, host approval, and a pre-dispatch identity recheck; `set_window_frame` only for an exact user-specified geometry, host approval, and independent window-bounds readback within 2 px; `browser_pointer` hover/right-click/double-click only for enabled refs with `pointer`, and drag only between uniquely named pointer refs in the same frame. The browser pointer candidate uses the installed `dom_event` route; its dispatch is not treated as completion proof. All these additions remain unavailable on the default production surface. |
| App/browser host routing | `launch_app` and `bring_to_front` are selected only by the host from app scope and explicit foreground intent; activation is verified against the exact window. `browser_prepare` is host-owned: only a browser that reports `browser_requires_setup` can route to a new driver-owned isolated Chrome profile, after the existing Jarvis approval prompt. Existing-profile attachment is not automatically enabled. `start_session`/`end_session` wrap each work item, with task labels and teardown in the host. |
| Observation and verification | `get_accessibility_tree`, `get_browser_state`, `get_desktop_state`, `get_window_state`, `list_apps`, `list_windows`, `get_screen_size`, `get_cursor_position`, `parse_visual_regions`, `zoom`, and `verify_state` provide observation or conservative tri-state verification, never mutation choices. `get_session`, `list_sessions`, `get_agent_cursor_state`, `get_recording_state`, and `get_config` are content-free lifecycle/diagnostic reads. `health_report` and `check_for_update` are diagnostics; neither updates the runtime. `check_permissions` is host-only and must use `prompt:false` for read-only evidence because the default may raise TCC prompts. |
| Host controls not exposed as Jev actions | `set_agent_cursor_enabled`, `set_agent_cursor_motion`, and `set_agent_cursor_theme` affect session cursor presentation and stay under host session ownership; the current runtime starts/ends sessions but does not configure a separate cursor mode. `start_recording`/`stop_recording` can capture private content and recording ownership is not per caller, so recording stays out of task choices. `set_config`, `install_extension`, and `install_ffmpeg` alter persistent configuration or installed software and stay outside the executor. |
| Excluded or withheld | `browser_download` requires MCP-host destructive-tool approval that this stdio bridge cannot express. `clipboard_read`/`clipboard_write` expose or replace global private clipboard state and remain unavailable as Jev-selected actions. `move_cursor` changes the real desktop pointer and may interfere with user focus. `hotkey` returns an unverifiable effect; other keys currently lack an exact independent postcondition. Native `drag` is coordinate-based without a capture identity, so its coordinates cannot be safely refreshed and are not offered. `kill_app` force-terminates and `replay_trajectory` unconditionally replays mutations; both are excluded by the voice contract. `page`, `escalate_session`, and `get_session_state` are legacy compatibility tools, not canonical choices. |

Candidate mutations are gated by `CuaActionSurface.candidate`; `CuaTaskAgent`
defaults to `.production`, and the packaged runtime does not select the candidate
surface. Candidate IDs are immutable within a `CuaActionChoiceBook` and bound to
task UUID/revision outside Jev's answer. The book groups and paginates dense
snapshots while keeping each Choice at or below 255 options; automated coverage
exercises 600 observed actions without hiding a target. The task loop is bounded
at 32 observed actions and refuses when the limit is reached. These controls do
not close the action-family proof gate: most candidate-only mutations still need
live effect/refusal evidence, and completion is assessed from state rather than
dispatch status.

**D** below is preserved Cua based on `b703a8d17fb513c6288f247f710d30643abd068d`
plus `ThirdParty/Cua/local-integration.patch` and its manifest, with the installed
hash above. Source availability is verified. Newly proposed runtime behavior still
needs tool advertisement and live validation through Jarvis. **J** is the baseline
Swift Jev integration, preserving `jev-latest`; this service alias is not an
immutable model revision. This investigation established no stronger model pin.

| Responsibility / current owner and coverage | Proposed owner / availability | Contract | Required deletion proof | Remaining host gap |
| --- | --- | --- | --- | --- |
| Broad content comparison: `CuaTaskAgent.contentIdentity`; task/generation tests | D `verify_state` (`verification.rs`, `expectation.rs`); isolated adapter staged | Exact PID/window, 1–8 predicates, stable tri-state result; internal observation-only reads preserve tokens; late cancellation discarded | User edits refused; unrelated changes tolerated; installed token preservation proven | Role/substring-label selectors are not opaque identity. Arbitrary content/recipient guards remain |
| Browser comparisons: `CuaBrowserTarget`; browser tests | D target/tab/ref validation; already used, replacement not proven | Exact window binding; target/tab and snapshot refs; only explicit non-browser refusal permits native routing | Stale refs and tab/frame changes rejected; correct query/tab/destination observed | User-intended destination and content ownership remain separate from valid refs |
| Description rematching: task refreshed catalog; catalog/browser tests | D retained token/ref plus immutable J candidate lookup; integration needed | Original action arguments dispatched once; stale handles refuse without description resolution | Duplicate labels, changed indices, stale snapshots, original text args | Native refresh invalidates tokens; prove non-invalidating preflight before deleting refresh/rematch |
| Predicted window creation: `awaitingNewWindow`, initial IDs, `windowEffect`; native/foreground tests | D discovery plus J request-specific selection; no complete upstream replacement found | Newly created document must belong to this request | Exact new TextEdit content; original untouched; simultaneous windows do not redirect | Verification addresses known windows, not who created them; retain ownership protection |
| Outcome handling: `CuaConnection.callResult`, task history; connection tests | D structured refusal/execution/verification output; integration needed | Preserve refusal/partial/unknown; dispatch acceptance is not success; cancellation may leave effects | Timeout with state inspection and zero replay; contradictory evidence blocks completion | Goal interpretation and uncertainty reporting remain host responsibilities |
| Polling/readback: window waits, literal readback | D `verify_state`; adapter staged | Bounded exact-window predicate; stable satisfied, unsatisfied or unknown; no unknown/timeout retry | Exact native text; unsupported/ambiguous results remain unknown | Browser DOM and unknown new-window discovery are not covered |
| Completed descriptions: task `completed` set | Confirmed-effect/repetition-authority candidate in single J loop; disabled in production | UUID labels history only; uncertain prior effect stays suppressed; repeated confirmed effect needs additional user intent | Two intentional scrolls yield two effects; late result cannot replay | MCP IDs do not deduplicate intent; description suppression cannot simply be removed |
| Jev plumbing: selection/risk/generation/progress; approval/generation tests | Single Swift J recipe informed by pinned jev-use; integration needed | Typed ID resolves original candidate; malformed decisions stop; progress uses observed state | Live native/browser goals, unsent drafts, corrections and cancellation | PR #3961 still requires host action construction, authorization and verification |
| Whole-app leases: `CuaWorkQueue`; queue/correction tests | D input serialization plus host coordination; narrower ownership unproven | Input serialization is not multi-step isolation; release after cancellation unwind | Concurrent addressed windows preserve focus/text; global menus/clipboard serialized | Retain app leases until resource-level replacement proof |
| Visual validation: `CuaVisualObservation`; visual/perception tests | D capture provenance plus existing public adapter; already used | Exact capture/PID/window, bounded coordinates; no unbound retry; discard after dispatch | Changed capture refusal without coordinate retry | Host semantic interpretation remains; OCR is not completion |
| Task/voice lifecycle: `CuaVoiceRuntime`; controller/speech tests | Existing Jarvis boundary, retained | Revision, dependency, approval and cancellation tied to task | Existing suites plus live follow-ups/corrections and package behavior | Required voice/UI ownership; not another desktop planner |

## Candidate and outstanding proofs — steps 4–8

`CuaStateVerification` adapts D's deterministic `verify_state`. It has no production
caller yet. It preserves unknown/unsatisfied outcomes, rejects contradictory success
and discards late cancellation. Four offline tests cover those contracts; this is
not installed-runtime proof.

`CuaReplacementContractLiveTests` stages a disposable TextEdit probe: verify seeded nonempty
state, dispatch using the original token after verification, refresh the snapshot,
require `stale_element_token` refusal, independently inspect exact final text.
This is Driver-only evidence, not a real Jev workflow or packaged acceptance.

The user authorized serialized live checks. All checks used the shared desktop
lock and disposable local content; Jev credentials were read noninteractively from
Keychain without export. The installed pinned runtime was used unless stated.

| Proof | Result and limitation |
| --- | --- |
| Native token/verification contract | Pass with nonempty seed: verify preserves original token, snapshot refresh retires it, stale write refuses and final text remains exact. Blank-value verification returned unknown because Driver omits empty AX values; retain host readback. |
| Native new document, existing content preserved | One baseline pass after a test-only nine-second setup settle. Immediate activation failed because the background launch watchdog restores prior focus. An interrupted candidate trial failed preservation with an extra `O`. After the user confirmed concurrent desktop use had stopped, an exclusive candidate trial passed exact new text and original preservation (22.698s total/9.243s agent). Immediate-launch repair still lacks live proof. |
| Browser form | Real Jev form pass; supporting coverage only. |
| Browser search/navigation | One fresh trial passes quoted query, target/tab identity, destination, and navigation. Separate fresh direct-navigation trial passes exact URL and destination. Unquoted browser extraction remains unverified. |
| Repeated scrolling | Current installed-pin trial dispatches one 500 px scroll, then falsely returns `Completed` after a page click; the fixture rejects `[500, 1000]`. The review-fix host guard now prevents any later action or completion claim after an unconfirmed scroll, but does not provide the missing readback. The separate readback patch is preserved but uninstalled. No deletion evidence. |
| Changed target | Native retired token refuses with exact content preserved. Browser ref-index movement now uniquely rebinds the same semantic text control for readback; browser tab/frame change live coverage remains open. |
| Cancellation/uncertain dispatch | Offline late-cancel discard and zero timeout replay pass. Candidate Return live trial dispatches once and refuses when exact newline readback is absent. Live runtime cancellation and timeout state inspection remain outstanding. |

Candidate selection is test-only (`JARVIS_CUA_SIMPLIFIED=1`); normal production still
uses the existing loop. The candidate records per-dispatch UUID history labels. It only reopens a
completed action with Driver-confirmed nonempty evidence and a separate additional-
effect judgment in the existing risk call. Unknown/unverifiable effects remain
suppressed; UUIDs are not replay protection. The latest matching uncertain result
cannot be overridden by an earlier confirmation. `CuaConnection` now preserves structured partial/indeterminate/unknown
outcomes instead of treating them as ordinary refusals or success. A partial-text
regression test failed before the repair and passes afterward. Text extraction
now offers exact punctuation-boundary alternatives; it does not yet solve the
observed unquoted-query failure. Voice capture/UI remain unchanged.

### Bounded Driver repair and remaining desktop prerequisite

Source and controlled activation results identify a detached eight-second
`launch_app` watchdog conflicting with explicit foreground requests in the same
runtime. A local candidate retires only the validated PID's detached launch
watchdogs, synchronizing queued/in-flight restoration. Ordinary guards and other
PIDs remain protected. The three-file patch and recovery hashes are preserved in
`ThirdParty/Cua/launch-watchdog-candidate.patch`, with recovery hashes in
`.context/execution-simplification/driver-focus-repair.json`. All 31 focused
Rust tests, locked release build, and candidate signature verification passed.
Candidate Driver SHA-256:
`b8be58db2df46c27486e66d2861a5ccd12fd06b350fbdc583057212320c7a6de`.
No installed runtime, app identity, dependency pin, or shared reference changed.

Plain `mcp` proxies to the installed broker, so proof must use the hash-bound
candidate with `mcp --direct --embedded` and isolated runtime/telemetry homes.
Direct mode lacks the cursor overlay and cannot establish packaged acceptance.
Its own permission probe reported Accessibility=false and Screen Recording=false
under host attribution; no mutations were attempted through this candidate.
Permissions must pass before mutation. See the runtime notes alongside
the patch. A test-only settle is diagnostic, not an accepted product workaround.

The user confirmed concurrent desktop use during the failed native trial, then
authorized exclusive desktop use. The guarded recheck passed. That resolves the
desktop-ownership prerequisite for serialized checks, without erasing the earlier
failure or establishing the exact origin of the extra character. The isolated
Driver's missing host permissions remain an external prerequisite.

Steps 4, 6, 7, and 8 remain incomplete. One live production-runtime exact-text
trial passes, but packaged task acceptance and normal voice input remain untested.
No existing protection has been removed and no net simplification is established.
Remaining evidence includes supported scroll readback, native key/value/menu and
drag families where supported, browser tab changes, live cancellation/uncertainty,
follow-ups/corrections, unsent drafts, matched baseline/candidate measures, and
package task behavior. Build-specific results are in `voice-ui/EVIDENCE.md`;
unrelated migration gates remain open.


### Reviewed checkpoint

Transport outcome repair committed as `b119086`; six focused transport tests
(one live skip) pass. Latest full regression: 258 tests, 21 opt-in skips, zero
failures; tooling passes. Final candidate replay tests cover explicit refusal of
additional repetition and confirmed→unverifiable suppression (nine task tests,
zero failures). No production path or safeguard retired. Candidate additions and
the local Driver delta increase code; they are investigation, not simplification.

Next bounded work: establish a supported scroll postcondition and correct completion
handling before enabling repeated actions; resolve unquoted payload selection;
prove the isolated watchdog repair once its actual host permissions are available.
Then rerun required workflows through the single production path before deletion
or final package acceptance. Current archive/signature checks are checkpoint
recovery only. No launched final-app acceptance has occurred.


### Pinned browser verification gap

Source review: `browser/tools.rs` semantic refs publish identity/actions/visibility,
not scroll offsets. `browser/semantic.rs` uses internal DOMSnapshot scroll extents
only to advertise scrollability. `browser/pointer.rs` compares `scrollLeft`/
`scrollTop` for synthetic movement but returns a Boolean; the response publishes
requested deltas, not observed positions. Public action projection reports this as
unverifiable. `verify_state` has no browser-ref or scroll predicate. The fixture's
`/state` endpoint is independent test evidence, never a production substitute.
A narrow runtime contract enhancement is required before Driver can own this
verification and the host suppression can be retired. No speculative implementation
or pin update was made for this additional gap.

The candidate process ancestry was Python → Codex → Conductor runtime → Conductor.
The initial request for Conductor grants incorrectly inferred TCC responsibility
from ancestry. On 2026-09-22, the user supplied a screenshot showing Conductor's
Screen Recording grant enabled. A fresh candidate probe still returned false for
both permissions. Capturing macOS TCC attribution during that exact probe identified
the responsible subject as Conductor's bundled CLI executable:
`~/Library/Application Support/com.conductor.app/agent-binaries/codex/0.154.0/codex`.
Accessibility was denied and Screen Recording had no grant for that subject. The
Driver's `responsible_ppid` field is only its parent PID, not an OS-verified host
identity. Requested user-controlled grants for the actual subject; no settings
were changed by automation. Authorization for serialized desktop checks remains
valid; permission readiness must be reprobed before candidate mutation.

### Resumed proof work — 2026-09-22

Resumed from `5e8a696` with a clean tracked working tree. The actual TCC attribution
above supersedes the earlier Conductor-grant diagnosis.

- **Cancellation boundary:** `1bb3a15` checks cancellation immediately before
  foreground activation, covering a late window-selection result. The new agent
  test failed with one activation callback and passes with zero. The transport
  already has its own cancellation check; this is an agent-boundary proof, not
  evidence of an observed production focus theft or live cancellation acceptance.
- **Payload selection:** a model-only probe reproduced the unquoted-query error.
  A sequential source-span experiment passed one browser query/tab/destination
  trial, but subsequent model trials truncated/refused legitimate content. The
  experiment is reverted and preserved only as
  `.context/execution-simplification/payload-span-experiment.patch`. The opt-in
  five-case `JevPayloadLiveTests` retains the regression corpus. This gate remains
  open; no phrase-specific parsing or extra model call entered production.
- **Scroll outcome:** `ThirdParty/Cua/scroll-readback-candidate.patch` preserves a
  two-file local runtime delta, separate from the existing watchdog repair.
  Retained DOM target offsets and unchanged bounds feed Cua's existing action
  result: exact clamped movement is confirmed, no movement is suspected no-op,
  and missing/contradictory/partial readback remains unverifiable. The public
  result carries readback evidence without exposing raw offsets or identities.
  Review repairs prevent unmeasured reveal-scrolling during visualization and
  reject an origin moved out of the original document/container by a page handler.
  Both findings have failed-before/passed-after tests. No supported tool schema,
  dependency version, installed runtime, or production pin changed.
- **Proof limits:** 164 Rust browser tests and 11 offline JavaScript producer
  scenarios pass. These use mock CDP/a DOM test double and do not prove Chrome,
  live Jev repetition, or goal completion. Negative/RTL offsets and unsettled
  smooth scrolling remain unconfirmed. The existing wheel-event plus scrollBy
  delivery behavior is retained, with its combined movement now measured.
- **Checkpoint verification:** `make test` passes 260 tests, 22 opt-in skips,
  zero failures; tooling passes. `make app`, strict signature verification and
  ZIP extraction/hash recovery pass. The app was neither installed nor launched.
  The focus-only Driver remains preserved at
  `development/JevVoice/staging/focus-only-candidate/cua-driver` with its original
  `b8be58db…` hash, separately from the newly built combined candidate.

Next: resolve exact payload selection and the demonstrated changed-label replay
gap before another native acceptance trial. The new
`ThirdParty/Cua/menu-focus-candidate.patch` applies after the preserved baseline
and coexists with the watchdog/scroll patches. It prefers live WindowServer
process evidence for menu readiness, retains exact AX window/stability checks,
and captures an observable foreground owner for restoration. A foreground app
without an ordinary visible window retains the previous NSWorkspace fallback;
universal restoration is not established. Candidate SHA-256 is
`483b693060416b8cdd8088fde1140e6868d73dee72870b661f7efd4b7ec7cdf5`.
One observed watchdog run preserves both background focus and explicitly requested
foreground beyond eight seconds, but an earlier run lost background focus after
that interval without recording the gained PID. Do not erase that failed sample
or claim full watchdog acceptance. Production integration, deletion, matched
performance evidence and packaged-app acceptance remain open.


### Continued verification — 2026-09-23

This dated addendum supersedes earlier checkpoint statements that production
integration was still isolated or that normal runtime used a separate executor.
Normal `CuaVoiceRuntime` requests now run through one `CuaTaskAgent` observe–
choose–act–verify loop using the production action surface. The experimental
action families remain candidate-only. The Step 5 integration checklist is
complete against source and automated tests; one live production-runtime native
literal trial additionally passed with exact readback and preserved seed text.
The runtime trial does not establish packaged acceptance or live follow-up,
correction, cancellation, or provider workflows.

Step 4 remains open: the installed pin still has no sufficient repeated-scroll
postcondition, and its live workflow failed after one scroll. The prior runtime
then dispatched a page click and falsely returned `Completed`; the host now
reobserves and refuses further actions after an unconfirmed scroll. Offline
coverage passes, but the live workflow was not rerun. Browser changed-tab
behavior, native keyboard/value/menu/drag families, and live cancellation/timeout
behavior remain incompletely exercised. Step 6 remains open with no protection retired.
Step 7 has the production literal and concurrent background-app samples, but
matched baseline/candidate measurements and the broader workflow set remain open.
Step 8 has a signed, extracted, recoverable review-fixes package. The fresh
read-only review is complete and its three Important findings have failing-first
fixes with the full test suite passing; the reviewed fixes were not re-reviewed.
The focused source/test/evidence commit is complete locally, with no push. The
package UI/task acceptance remains open. The earlier package UI reported
Accessibility missing; the latest package has not been opened. No permission
prompt was issued, and no desktop action was taken after the UI entered a
listening state. Full
commands, logs, artifact hashes, and rollback instructions are in
`voice-ui/EVIDENCE.md`.
