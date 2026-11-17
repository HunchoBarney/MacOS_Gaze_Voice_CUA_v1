# R10 packaging base amendment

G2 PLAN PASS: reviewer859f3e7e approved the revised contract, explicitly
within existing C1 isolated candidate authorization. Implementation,
controls, source/artifact review and live/human gates still required.

Original daily and old c292 delivery copy are absent. Cause is unknown.
Stage failed before creating anything (c1-r10-stage.log). No restoration
or installation at the daily path is authorized or proposed.

Retained R9-2 independently rechecked in c1-r10-retained-base-check.json:
binary, every resource byte/mode/link, Info, stable requirement/signing,
source-snapshot digest and deep strict signature all match its receipt.
Original rollback SHA remains historical, not falsely reported as present.

Use the existing stage helper with one explicit `--retained-base` flag,
restricted to `final-r10` and to the exact original daily path being
completely absent (reject symlink or partial app). Ordinary staging keeps
the original exact daily guard. No arbitrary replacement path.

Pin the existing R9-2 receipt:

- `.agent/results/P12/c1-final-r9-2-stage.json`
- SHA256 `972d1ce3cfc04f0d3ef8c101c1cabfe377ee223b2aae0c93e98f35e76e6714f0`
- app `~/jarvis-local/c1-candidates/jev-c1-final-r9-2-ksh975zx/Jev Voice.app`
- executable `79e8859b32d849e2777c741cefec099123cae9e18a6d081de8bab440cabb276b`
- requirement/signing, Info, resources and source snapshot must match
  that receipt, including codesign deep strict, before any clone.

Clone this verified base into new private candidate storage, using existing
APFS copies. Replace only the same built executable/Info/canonical pinned
driver and Codex payloads. Regenerate FluidAudio notices from the same
resolved revision inside the clone (the retained base already has them;
never delete or modify the base). Keep 0.38 pin, license, signature,
entitlement, source/binary freeze and disk-space guards.

Recheck retained base byte identity/resources/Info/signing after staging;
also require original daily path to remain absent. Record rollback_app/
rollback_sha256 as the actual retained R9-2 fallback, rollback_role as
last_verified_candidate, pinned base receipt/digest, and historical_daily
path/expected SHA/status missing. Existing immutable R9 receipts unchanged.
Never call the missing original daily unchanged or restored.

P12's existing c1_manifest.py will carry and validate the retained role,
pinned base receipt path/digest, exact retained app/executable, and
historical daily path/expected SHA/missing status against the stage
receipt. At this pre-install gate the original daily must still be absent.
Reuse the staging validation for the pinned retained base rather than
duplicating the identity rules. An ordinary daily-based manifest keeps
its existing behavior. Changed or omitted retained-base fields fail.

Owned changes: existing jev-stage-candidate.py, P12/c1_manifest.py and
relevant existing P12 tests only; this note, PROGRAM/CONTRACTS decision, handoff/progress and
new R10 source/artifact receipts. No Swift/binary changes or rebuild;
release2 belongs to unchanged source2 Swift inputs. Freeze a new packaging
snapshot with the amended helper and retained-base receipt.

Failure cases to write in existing P12 tests BEFORE implementation:
non-final-r10 flag; present/partial/symlink daily; wrong pinned receipt
digest; wrong base app or executable; invalid signature; missing/changed
role, pinned receipt, historical daily identity/status. Use temporary
paths for destructive controls, never mutate the recorded R9 base or
historical receipt. Validate the actual R9 base read-only as the positive.

Proof: current missing-daily failure retained, named negative controls
before clone, real retained-base validation, signed new candidate and
existing P12 corruption/rollback controls, independent artifact review
and normal launch. Live/human C1 gates remain open.

Review history: first G2 response859f3e7e FAIL correctly called for P12
metadata enforcement/controls, now added above. It also scored the
unimplemented flag as a source defect although this request was PLAN
review; implementation has intentionally not started. Next review must
judge this concrete contract, with source/artifact checks still separate.
