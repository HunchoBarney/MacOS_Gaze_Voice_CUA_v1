# Execution simplification replacement record

2026-09-21 checkpoint; governed by [the approved plan](EXECUTION-SIMPLIFICATION-PLAN.md).
This is investigation and isolated candidate work, not acceptance or a migration gate closure.

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
| Browser search/navigation | Exact quoted query passes query, tab, destination and navigation readback. Two unquoted variants failed extraction (extra separator/control words); these failures remain open. |
| Repeated scrolling | Early permissive candidate produced positions 500/1000, but review found missing uncertainty protection. Revised conservative candidate failed after one scroll (position 500) despite model completion. Repetition replacement is not accepted. |
| Changed target | Native retired token refused with exact content preserved. Browser changed-tab/frame coverage remains outstanding. |
| Cancellation/uncertain dispatch | Offline late-cancel discard and zero timeout replay pass. Live cancellation and timeout with state inspection remain outstanding. |

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

Steps 5–8 remain incomplete. No existing protection has been removed, no net
simplification is established, and the isolated candidate is not delivery. Required
remaining evidence includes reliable native preservation, unquoted query handling,
live cancellation/uncertainty, relevant target changes, follow-ups/corrections,
unsent drafts/concurrency, production integration, justified deletion and final
packaged behavior/recovery. Build-specific logs and results are recorded in
`voice-ui/EVIDENCE.md`; unrelated migration gates remain open.


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
Requested user-controlled Conductor Accessibility/Screen Recording grants to unblock
the isolated repaired Driver proof; no settings were changed by automation. If a
restart is required, resume from committed checkpoints `b119086` and `2b0caf1`,
this record, and the build-specific evidence. Authorization for serialized desktop
checks remains valid; permission readiness must be reprobed before mutation.
