# Native Provenance Stage A Contract

G1 approved Full Plan, PROGRAM D9. Stage A ONLY here; no new proof basis.
Before code: existing full native values have no extent/parent-document
attestation in Fact.json. Real signed9b/9c matched both strict0/3,
actual body both3/3. No valid proof existed; not a reread failure.

## Private Metadata

- NativeDocumentSubject: exact WindowRef plus opaque SHA256 Data digest
  of the native window's standard AXDocument identifier; no raw path/id.
  Nil for missing/unsupported/malformed data. Never send/log the digest.
  Digest is 32-byte Data, not an identifier string serialized to JSON.
- NativeFieldProvenance: exact verified native WindowRef and optional
  native document subject. Its presence means a successful complete
  native AXValue STRING read for the entire field, not visible text,
  trimmed SDK value, placeholder or generated text.
- AXSnapshot.nativeDocument and AXElement.nativeValue default nil.
  Display adds optional nativeDocument; FieldValue adds optional verified
  native owner/window scope. Existing callers/fixtures preserve behavior
  with nil; they cannot silently receive a native attestation.

Native read requires exactly one native root for the exact PID/window,
never the first of duplicate roots. Read AXDocument before and
after traversal, require stable identity and final root/owner/window
membership. If it changes, discard the display; do not merge A values
under B identity. Native field provenance requires native field PID and
AXWindow equality to that root, successful full string read, complete
untruncated traversal, nonsecure role/label and unique matching field.
Unknown ownership gives no attestation. General non-document apps stay
available when AXDocument is unsupported.

applying clears all incoming SDK/previous native metadata first. Only
complete explicitly scoped native display can set it. Reject foreign
document scope; new attestation requires known matching native/SDK
frames, role and unique field mapping, not label-only identity guessing.
No metadata from an incomplete read. Preserve existing native value
restoration behavior for old callers, without upgrading its assurance.

TaskLoop retains the first observation's native document anchor ONCE,
even if unknown. No adoption after a doc change or failed initial read.
TaskObservation carries this optional local anchor; never mutate caller
TaskBrief or rebind window. Existing model/voice/preview callers default
nil; read-only preview may describe current provenance but not invent
an original anchor.

ObservedGoalProof.Context/Node retain native subject/provenance for fresh
same-context equality. Existing general proof scores/model/completeness
gates stay unchanged. choiceState exposes factual extent and document
association plus original-anchor-known/unchanged booleans, NEVER raw
document string or opaque digest. Data is not a new permission or claim
that a field is the entire document; native parent association is not
semantic target selection. Requested document switches remain possible
through the existing general path; no global anchor-change task ban.

## Failure Cases And Guards Before Code

Native complete public field positive; unknown SDK/placeholder/partial/
unscoped/foreign PID/window/doc/secure/duplicate fields never attested;
empty full value valid; field owner unknown no fabricated origin;
native document changes during read reject; missing doc remains unknown;
context/proof rejects changed same-title document on fresh readback;
first original anchor immutable across reobserve/image/recovery and
never adopted if initially unknown; caller task unchanged; no digest/raw
path/id in remote state or trace; existing compound and full-goal gates
unchanged; nil metadata preserves old consumers.

Tests first in focused NativeObservation/ObservedGoal/TaskLoop suites at
the production capture/merge/choice/proof seams. G3 via serialized lane.
G4 independent every consumer; fresh signed pilot and matched same-driver
A/B against retained9c-before. Source manifest freezes exact app delta.
If reliable strict success, STOP: no optional Stage B.

## Build Space

9c unused unsigned Template was current-run generated output; both9c
signatures verified before removal, raw template binary matched release
binary. Signed main differs due signature, so the first equality check
correctly refused deletion; second checked the unsigned release bytes.
Only unused unsigned Template removed. Disk4.0GiB below unchanged5GiB.

User separately APPROVED exactly9b-after(wq1v092b) and9c-after(ms_48tla)
archive/reconstruct/verify/remove. Both before bundles MUST remain,
9b-before is required archive base and9c-before next matched baseline.
New helper mutually exclusive --approved-two-after mode keeps old4 mode,
same verified binary-patch/modes/original-signature mechanism, fixed2
roots, exactafter labels, common private parent, before hashes/signatures
and manifests rechecked. Source review BEFORE removal. No other app,
resource/evidence directory, cache, document or daily app deletion.
