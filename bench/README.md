# jev bench

Unattended bench for Jev Voice: drives the real `DriveLoop` through the
app's `--mcp-stdio` MCP surface (`drive_until`), verifies end-state
independently (zero-false-Done discipline), and reports Wilson-CI success
rates + wall-clock latency. Python 3 stdlib only — no third-party deps.

## Layout

```
bench/
  tasks/*.json     task corpus (CONTRACTS.md §7 shape)
  reset/*.sh       per-task environment resets named by `setup`
  lib/             mcp_stdio · verifiers · wilson · results · stub_server
  run.py           corpus runner (reset -> inject -> classify -> verify -> row)
  report.py        results jsonl -> baseline.json + baseline-report.md
  env-snapshot.sh  machine/app/policy snapshot -> results/env-*.json
  run-suite.sh     caffeinate + snapshot + suite + report (unattended)
  selftest.py      unit suite — `python3 bench/selftest.py`
  results/         gitignored output
```

## Run it

```sh
bench/run-suite.sh                      # local-safe corpus (default)
BENCH_SET=test-user bench/run-suite.sh  # mutating corpus — test user only
BENCH_SET=all bench/run-suite.sh        # both sets (inside jevbench)
BENCH_STUB=1 bench/run-suite.sh         # stub backend, no app needed

python3 bench/run.py --task calc.open --runs 1 --verbose
python3 bench/run.py --tag browser --set local-safe
python3 bench/run.py --dry-run          # reset+verify only, no injection
python3 bench/report.py bench/results/results-<UTCdate>.jsonl
```

## What a real run needs

- The app installed and running so the Cua daemon socket exists
  (`~/Library/Application Support/JevVoice/cua.socket`) — `make local`.
- `TYPESAFE_API_KEY`: taken from the environment, else fetched from the
  Keychain item `com.chriswozniczek.jevvoice` / `typesafeAPIKey`. The
  value is never logged or written. Unavailable → every run's row is
  `blocked:keychain` (a result, not a crash).
- Mutating calls need `policy.json` `standingGrant: true` (Jev Voice
  settings); without it `drive_until` returns the missing-grant
  `Blocked:` text — recorded as data.
- `ax_state`/`app_frontmost`/`dom_state` verifiers drive `osascript` —
  the host process needs Accessibility + Automation grants. A denied
  Automation call is an `error` verdict, never a silent pass.

## Results

- `bench/results/results-<UTCdate>.jsonl` — one row per run (schema
  `v:1`): `ts, task, run, wall_ms, status, is_error, verdict, verified,
  false_done, result_text, evidence, spans`.
- `status` is the classifier vocabulary (`done|already|blocked|
  refused_permanent|stuck|needs_input|ambiguous|maxsteps|cancelled|
  error`) or a harness status (`dry_run|setup_error|blocked:keychain`).
- `baseline.json` / `baseline-report.md` — Wilson-CI, p50/p95 vs budget
  and release bars, verbatim non-pass reasons.
- `results/` and `.env` are gitignored.

## Test user

Creating the `jevbench` user is the one human step:

```sh
sudo scripts/bench/create-test-user.sh   # prints the post-create checklist
```

Then inside the jevbench session: install the app, grant TCC
permissions, sign into Mail + Chrome, run `BENCH_SET=all
bench/run-suite.sh`. `requires:"human"` tasks (the gaze pair) are
recorded for coverage and never injected.
