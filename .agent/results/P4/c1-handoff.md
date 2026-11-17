# C1 candidate handoff

For the current R5/R6 state and disk-space block, read
[current handoff](c1-current-handoff.md).

Historical c292 handoff. R1/R2 repairs and continuous conversation have since
been implemented. See [current checkpoint](c1-r2-connected-checkpoint.md) for
the latest candidate and still-open live/physical gates. The measurements below
belong to the original c292 artifact, not a later candidate.

Status: implementation, integrated machine checks, separate signed
candidate and independent source/candidate G4 are complete. **C1
acceptance remains open.** No acceptance flags, daily installation,
commit, push or merge was performed.

## Artifact and rollback

Use `/Users/karanvirkang/jarvis-local/c1-review-c292e120/Jev Voice.app`.
Executable SHA256:
`c292e12024dc04bfc6a924b0d7f6ceb41a2c1c23ed38ffcba8f404750f9264eb`.

This is an APFS clone of the tested temporary app. All paths, file
bytes, modes and symlinks match, and strict deep signing passes.
[Delivery receipt](../P12/c1-delivery-receipt.json),
[payload manifest](../P12/c1-delivery-payload.json),
[original signing receipt](../P12/c1-final-stage.json),
[component/runtime/model manifest](../P12/component-manifest.json).

Daily app/rollback remains `~/jarvis-local/Jev Voice.app`, executable
`f6abbe98113d7f9362ab98bc48a32e1fa94df6ddb3b376ab27dc56939fa4adf1`.
The candidate's app path is separate. Do not run `make local`, `make run`
or an install command without the user's approval.

## Implemented and reviewed

- Exact-text, hidden-state, subject identity, permission and consequence
  remain independent. Native literal presence cannot bypass required
  evidence; identical pixels do not prove unchanged document identity.
- Native/pixel scroll authorization separately covers direction, region
  and scope. Weak or plural references cannot grant identity.
- Fresh/invalid and unmarked safe dwell profiles default off. Explicit
  opt-in persists; learned writes cannot create consent; delay is at
  least one second. Legacy explicitly selectable `all` is retained.
- Permission status reads run off the UI thread, with one read in flight,
  stale-result rejection, revoke/grant recovery and cancellation that
  does not interrupt unrelated input.
- Both native action callers reuse a freshly verified captured
  app/window identity instead of redundant app resolution. Fallback,
  fresh field checks, cancellation and exactly-once insertion remain.
- Speech finalization remains authoritative whole-hold Ultra; partials
  never become final. No model/SDK promotion, vocabulary/cleanup model,
  lost-word shortcut or artificial Jev usage cap was added.

The inherited tree is the baseline, not HEAD:
[baseline](c1-baseline-source.json), [contract and G2 records](c1-implementation-contract.md),
[scope manifest](c1-scope.json), [scoped patch](c1-scoped-diff.patch),
[import provenance](c1-harness-imports.json).
Of 208 fingerprinted files, 19 changed and 189 stayed identical.
Original bytes support exact diffs for 15 changes; four original byte
copies were not retained. Their before/after hashes, frozen current
source and failing-before evidence remain. The packet discloses this
instead of fabricating a complete diff against HEAD.

## Results

See the [generated visual report](c1-report.html) and its
[full precision data and evidence hashes](c1-report.json).

| Matched operation | Before median | After median | Observed change |
|---|---:|---:|---:|
| Scripted literal typing, 3 trials | 2386.8579999543726ms | 1536.3931667525321ms | -35.6311449285252% |
| Focus running Calculator, 3 trials | 4711.153000127524ms | 1610.013333382085ms | -65.82549254209098% |
| Authoritative speech replay, 35 recordings | 138.70425010100007ms | 172.30233340524137ms | +24.222821780714177% |
| Owned-window MCP scroll | blocked | blocked | no success/latency claim |

Typing preserved exact content, one dispatch and the decoy. Speech kept
the same 35 transcript hashes and 6 word edits/164 reference words, with
zero wrong critical actions or missing available cases. The later
window-inventory experiment regressed and was reverted; its results
remain visible. Speech preparation cache state was unmatched, so its
large observed difference is not attributed to C1.

These are fresh-process scripted desktop clocks and recorded-audio
finalization clocks. They are not warm physical Fn or microphone-to-field
latency. Three trials do not establish p95 or broad reliability.

## Gates

G2 passed (`1ccd62bc`; permission amendment `8b04b662`), recorded in the
contract. Required serialized G3 passed: 1399 Swift tests with 25 skips,
27 evidence checks, EyeTracking typecheck and 234 Vitest tests. P11 was
nonempty. P12 offline passed 26 Swift checks and six artifact/failure
controls. The separate C1 authority/dwell populations passed.

[Independent G4](c1-g4-review.md): initial FAIL for stale report links;
corrected packet received terminal **PASS**, reviewer `dbbf6534`.

G5 is partial/blocked; G6 is pending. G7's documentation handoff is here;
the user has forbidden a milestone commit.

## Remaining work and exact dependencies

1. Perform the [brief physical Fn/pill check](c1-physical-check.md) against
   the frozen candidate. A human must provide the physical key and live
   microphone input. It does not by itself establish p50/p95, a full
   accuracy qualification or phase acceptance. The normal LaunchServices
   launch initially waited in KeychainAPIKeyStore.read/SecItemCopyMatching
   with a macOS Allow/Deny prompt. It has since reached the normal
   controller, and the existing event writer reports the c292 executable,
   writable storage and no error. No approval was automated.
   [Current preparation](c1-physical-current.json) points to the private
   evidence directory and owned TextEdit fixture.
2. The 300-line owned TextEdit MCP goal failed on both builds with Jev
   HTTP400 `max_tokens_exceeded`. The oracle verified no scroll, no
   false success, unchanged body/decoy, and restored documents. Earlier
   setup errors remain retained. Normal-controller direct scroll has
   not been measured. Repairing this needs a bounded request-shaping
   investigation and a reviewed contract amendment if additional
   decider/SDK paths or evidence representation change. Do not shrink
   the workload and claim this failing case passed.
3. Dictation, feedback and verified-action speed goals remain unmet or
   unproven. The ASR replay regression remains open. Faster ordinary
   speech needs real speech-end/release-to-insertion/readback evidence;
   a decoder promotion needs the required held-out accuracy/resource
   proof. No defensible claim of Wispr parity is available.
4. Wispr was absent from the checked application locations. A comparable
   authorized installation/account is required for the planned pilot.
5. Portable speech assets, full transitive-license qualification, combined
   normal-GUI resources and the rest of C3 release checks remain open.
   This locally signed development candidate is not a distributable
   release.

Jev remains primary and unlimited under the user's setup. Its documented
per-request/per-question context limits are separate from usage limits.
The documented long-context option is slower/less accurate; it was not
enabled to hide the failing case. Terra and other C2/C3 capabilities
remain outside this C1 implementation.
