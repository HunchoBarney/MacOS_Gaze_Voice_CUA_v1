# Qualification Runtime Lease Review

Reviewer: independent jarvis-judge `74f6da34`.
Verdict: SOURCEPASS for the harness-only runtime lease fix.
P4 acceptance remains open.

The read-only executable-identity diagnostic reproduces the cause: two fresh
copies of the same signed driver take 20,145.843292 ms and 18,149.174583 ms on
first execution. Repeated execution of each same inode takes 28.71075 to
36.630083 ms. No model requests or ordinary app inputs occur in that diagnostic.

The qualification command now owns one temporary execution lease per selected
canonical candidate. Driver validation and every session use that exact copy.
Canonical and temporary manifests, strict signatures, and active lease ownership
remain checked. Sessions close their children before the outer lease releases
its own temporary directory. Cold validation, total setup, full command wall
time, and each run's actual path/inode are retained in the output.

Fail-first evidence is in `recovery-20261110/runtime-lease-tests-before.log`.
The first source review finds missing alias/run evidence, post-use signature
checking, and stronger lease ownership. The added checks fail before their
fixes in `runtime-lease-review-regressions-before.log`.
All 60 final harness checks pass in `runtime-lease-tests-final.log`.

The scope is `jev-realapps.py`, `jev-vision-qualification.py`, and
`test_jev_vision_probe.py`. No production source, signing identity, trust setting,
permission, model question, proof threshold, or 10-second readiness limit changes.
This deliberately measures a pre-executed runtime. It does not fix or qualify
production cold startup, GUI autospawn, physical Fn input, or P4 reliability.

## Native Oracle Follow-Up

The next live attempt reaches the driver, then refuses before Jev because the
SDK tree is truncated. Independent native readback proves the exact original
window and document URL and one full field matching the known 35-byte literal.
The SDK tree completeness flag is not the full-field oracle.

The reviewer separately returns PLANPASS and SOURCEPASS for removing only that
SDK truncation condition from owned-document readback. SDK scope/degradation and
all complete native window, path, budget, uniqueness and exact-value conditions
remain required. Accepted partial SDK reads are explicitly labelled
`sdk_partial_native_complete` only after native verification succeeds.
The fail-first 62-check suite has one expected error, then all 62 pass.

The following affected-path signed-app pilot issues one command without a
completion hint, reports done in 2,314.351458 ms, independently verifies the exact
replacement, and cleans up its runtime. This is one diagnostic pilot using a
30-second caller deadline, not phase qualification or a reliability improvement.
The matched comparison is a separate evidence source.
