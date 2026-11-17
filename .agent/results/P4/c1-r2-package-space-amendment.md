# C1 cached release and clone staging space budget

Status: prospective G2 PASS from read-only reviewer1bd91db8 before recipe
implementation or use. No blocking findings. Existing guard and clonefile
implementation were reviewed; all source/artifact/live gates remain separate.
This does not change product source, authority, deadlines or release acceptance.

The full G3 and independent source review pass on
c1-r2-candidate-source-r2/manifest.json. Full G3 was started with the5GiB
reserve. Its1434 Swift tests,27 evidence checks and234 eye tests passed.

This8GiB Mac now has approximately4.8GiB free, with5GiB swap allocated.
Only generated debug output and old release debug symbols were reclaimed after
verification. Models, source, evidence, daily rollback, baseline app and retained
c292 are preserved. There are no running Jev app instances. Do not delete
dependency repositories, checkout files, model caches or unrelated user data.

Reuse is concrete:

- The production release cache still exists (approximately199MiB after
  removing old symbols), including the incumbent FluidAudio build/modules.
  Package.resolved still pins FluidAudio0.17.5; no resolution or SDK change.
- Staging uses the existing clonefile implementation. It FAILS on an APFS
  clone error; it cannot silently copy the1.5GiB rollback app.
- The explicit replacement file sizes are30,531,528bytes for the previous
  release executable,80,571,696bytes for canonical Cua and241,555,024bytes for
  Codex. The new executable may differ; size must be measured after compilation.
  The new pinned VAD resource adds1,066,972bytes plus small license/receipt files.
  Signing may allocate more; these sizes are not a claimed peak measurement.

Proposed narrow recipe in scripts/verification-lane.sh:

1. c1-package-release: require the existing release executable and cached
   FluidAudio compiled module/build directory. Run the existing guarded Swift
   release build with --jobs1 and --disable-automatic-resolution.
2. c1-package-stage: use the existing strict jev-stage-candidate.py, frozen
   source/rollback/SDK/driver validation, stable signature and final-r3 label.
   No implementation changes to that stager.
3. These two scopes start only with at least3GiB free. Keep the same1GiB
   emergency stop,250ms monitoring, process-group termination and one-hour
   deadline in jev-build-guard.py. Keep its default5GiB and existing full/cold
   scopes unchanged. Serialization and desktop gates remain unchanged.
4. Record starting/ending free bytes, exit status and exact command for the
   release and staging attempts. Do not claim an allocation peak from endpoint
   measurements. Attempt this bounded recipe once; a guard stop leaves the
   candidate unaccepted and requires another evidenced resolution.
5. Freeze the updated harness bytes without changing the proven production
   inputs. Recheck those inputs before staging; verify the final artifact,
   resource inventories, signature and unchanged rollback before handoff.

This expressly amends the previous5GiB starting reserve for these two cached
operations. It is not an assertion that the earlier guard passed, and does not
alter the accepted proof requirements or permit daily-app replacement.
