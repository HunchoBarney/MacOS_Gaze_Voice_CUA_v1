# Prospective C1 staging-only resource amendment

Status: independent G2 PASS1bd91db8 before implementation, no blocking findings.
Compilation and tests retain their existing budgets.

Standard production release PASSED on frozen R5 app/test source:
c1-r1-fragments-release.json, unsigned main719ca80ae46f36518f231f711248d6b84215d942d35574b7ca1adb399b3cbd33.
All321 affected checks passed before that production build. No new compilation
is needed for staging. The attempted c1-package-stage stopped before any child
at the3GiB start guard; c1-r1-fragments-stage.json records exit75.

Owned output retirement and lossless native archives are complete. All app
source, canonical SDK artifacts, models, both dependency caches, rollback and
evidence remain. Current free space is about2.93GiB, roughly80MiB below3GiB.
The immutable duplicate Git pack now uses APFS sharing with exact SHA, modes
and extended attributes preserved, without immediate space gain. Stop further
speculative reclamation.

Measured actual package in c1-r5-stage-footprint.json:

-51 resource Mach-O files:1,106,771,312B combined.
-Largest file/transient signing copy:240,152,160B.
-New main:31,465,800B.
-Including16MiB additional metadata/VAD/notice allowance:1,395,166,488B.

The stage clones the existing package with APFS, copies pinned canonical
driver/Codex/main, signs each Mach-O sequentially, then seals the package.
It does not compile, download dependencies, run models or activate the app.
The estimate includes rewriting every resource Mach-O plus one largest
temporary signing copy, instead of assuming all signed bytes remain shared.
It is a file-growth estimate, not an observed total peak; swap/other processes
can still consume space.

Proposed change: ONLY c1-package-stage may start at2.75GiB. Keep1GiB emergency
termination, process-group containment,0.25s polling and deadline unchanged.
This leaves over480MB beyond the estimated file growth plus1GiB reserve at
admission. Any actual emergency threshold crossing stops staging; no partial
artifact may be qualified or installed. Existing ready apps remain available.
If this budget proves insufficient, retain failed evidence and report a disk
dependency instead of lowering it again.

Owned edits: guard argument parsing accepts fractional initial GiB; only the
c1-package-stage branch supplies2.75. All build/test branches and their
existing numeric budgets remain unchanged. App/test source, binary, signer,
models, policy and execution remain unchanged. Re-freeze helper identities
alongside the unchanged compiled inputs before staging. G4 must review both
the source delta and exact signed artifact. Package controls must explicitly
use JEV_C1_RECEIPT for the new artifact; their old default points to archivedR3.

Failure controls: invalid/negative budgets rejected; insufficient free space
starts no child; original3GiB compile values retain identical admission logic.
No test may treat a source-only or partial stage as a delivered candidate.
