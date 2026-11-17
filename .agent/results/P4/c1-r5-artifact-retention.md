# C1 R5 storage preparation

Resource-only G2 PASS by read-only reviewer1bd91db8 before storage changes.
No blocking findings. The fragment implementation and all321
affected checks pass. Standard production build/staging still need the existing
3GiB-start/1GiB-stop gates. Current free space is about1.7GiB.

Prepare native ZIP archives for only old final-r2 (eac804…) and final-r3
(ea2f7c…) temporary candidates, using macOS ditto with resource metadata and
parent bundle retained. Keep daily f6, baseline29b4, saved c292 and current
651 R4 as ready app bundles. Do not change their bytes, settings, signatures or
entitlements, or any SDK/model/dependency cache. No install/distribution.

Archive under an owned0700 ~/jarvis-local/c1-archives directory. Record original
receipt/hash, full file/mode/link manifest, original strict signature and binary
identity. Stream-check every regular ZIP member against original SHA256/size,
every link against its exact target, and stored modes/types. Reject missing,
duplicate or unexpected payload members. Native Apple metadata members are
retained. Only after complete verification may the corresponding old temporary
bundle be removed. Retain its parent/logs/receipt, add a separate archive pointer
and exact ditto restoration command; never rewrite historical evidence.

Archive compression is a filesystem retention operation, not a build. Bound it
with the existing space guard at1.5GiB initial/1GiB emergency, one archive at a
time. If interrupted or too large, preserve the original, remove only the new
partial ZIP and record failure. Compile/test/stage gates remain3/1 unchanged.
Verify the original again after compression before removal. Verify daily/current
identities and signatures remain unchanged. Logical app contents remain
recoverable byte-for-byte; report archived storage explicitly, not ready status.

Also retire only completed generated root module/index/symbol/test outputs as
needed, preserving output maps/SDK artifacts. Wait for delayed free-space
accounting before running a compiler. No system snapshots, unrelated user data,
dependency/model caches or other worktrees may be removed.

Execution: first preflight found five missing sealed zero-byte resources in
baseline29b4 and old eacR2 temporary bundles. Daily, saved c292, ea2R3 and651R4
passed strict verification. c1-r5-existing-signatures.json and verbose logs
retain the failure. Each missing path's SHA256 exactly matches the value in
the original signed CodeResources envelope and the verified daily resource.
Those ten zero-byte files were restored with their source modes. Both original
signatures now verify; main binaries and resource envelopes were unchanged,
with no re-signing. Proof/recovery receipts are c1-r5-missing-resource-proof.json
and c1-r5-sealed-resource-recovery.json. Removal cause is not established.

Keep newly staged candidates under owned0700 ~/jarvis-local/c1-candidates,
outside synced Documents and system temporary storage, with a unique private
subdirectory per stage. Existing artifacts/receipts are not relocated by this
recipe change. No signing or runtime policy change.

Old R2 is now stored in its verified native ZIP:5601 entries,705900878bytes,
SHA2564cde70abd888175c59505e23eab17b09b3948f7747d0d453a7be0f2c534a68ef.
Every payload byte/mode/link was checked and the original signature verified
before removing that temporary app. Separate archive pointer and restoration
command remain next to its historical receipt. It is recoverable, not a ready
bundle. Daily/baseline/c292/current651 identities and strict signatures remained
unchanged. R3 remains ready at this checkpoint.
