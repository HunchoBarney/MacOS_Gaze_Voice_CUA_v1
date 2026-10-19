# Working in Jarvis

This repo runs the `.agent/` harness. **`.agent/PROGRAM.md` is the source
of truth for "done"** — goals, locked decisions, phase DAG, release bars.
**`.agent/PLANS.md`** defines how every phase plans, gates, and hands off.
**`.agent/PROGRESS.md`** is the append-only session log — read it before
resuming anything, write it before stopping phase work (a Stop hook
enforces the write).

Phase work lives in `.agent/phases/P<n>-*.md` (self-contained ExecPlans
with explicit owned paths) and is judged against
`.agent/acceptance/P<n>.json` — default-FAIL criteria only a
fresh-context judge may flip, with evidence. Frozen cross-phase
interfaces live in `.agent/CONTRACTS.md`; changing one needs a Decision
Log entry plus re-review of every consumer.

Verify before you claim. Every claim ties to evidence the user can check
— a test run, a file:line, command output — proportional to the size of
the claim. Assume you're wrong until the evidence says otherwise. You may
search the web and papers for current truth; installed versions beat
remembered ones.

## Gates and worktrees (summary — PLANS.md owns the rules)

- Gate loop per phase: G1 user plan approval → G2 implementer/judge
  contract → G3 serialized build+tests → G4 fresh-context `jarvis-judge`
  PASS → G5 live bench + budgets → G6 human try (UX phases) → G7 handoff
  + milestone commit.
- ≤2 write tracks, in worktrees: `jarvis-v1-agent` owns
  `Sources/** Tests/** development/**`; `jarvis-v1-eyes` owns
  `EyeTracking/**`. Never two writers in one tree. User merges
  `ship/v1-<phase>` branches.
- All builds/tests go through the single serialized lane:
  `scripts/verification-lane.sh` (swift test → EyeTracking typecheck →
  vitest). Writers don't compile a half-frozen tree.
- Owned-paths enforcement: `python3 scripts/check-owned-paths.py P<n>`.

## Commands

- `make local` — **the daily driver**: build → stage → sign → install to
  `~/jarvis-local/Jev Voice.app` → relaunch → wait for the tracker API.
  One command from clean checkout to running app; `make run` aliases it.
- `make test` / `swift test --filter <Suite>` for focused checks
- `make app` stages + signs `build/Jev Voice.app` in place — in this
  synced checkout the final seal can hit the provenance detritus tripwire
  below; `make local` is the reliable path.
- The tracker checkout is symlinked into
  `~/Library/Application Support/JevVoice/EyeTracking` by `make local` —
  `TrackerHost` resolves it there, no env var needed. Tracker boot output
  lands in `~/Library/Application Support/JevVoice/tracker.log`.
- Tracker prerequisites: `node` plus `pnpm` via corepack (see the
  `tracker-deps` target). EyeTracking tests run from the `EyeTracking/`
  root (`npm test` / `npx vitest run` — `package.json` and
  `vite.config.ts` live there; running vitest from `EyeTracking/web`
  misconfigures collection).

## Tripwires — each exists because it caused real damage

- `development/` is local-only: `cua-source/` and the text layer
  (`*.json`/`*.md`/`*.txt`/`*.log`) are tracked; everything else is
  regenerable output and stays ignored.
- The Cua Driver is pinned and hash-verified against
  `ThirdParty/Cua/source-manifest.json`. Upgrading is welcome — verify the
  new version's contracts against `ThirdParty/Cua/README.md` and rerun the
  checks; a silent swap breaks the app.
- Credentials live in Keychain; secrets never enter repo files. Bundle id:
  `com.chriswozniczek.jevvoice`.
- Live/desktop tests sit behind `JARVIS_*` flags and mutate macOS — run
  them through `scripts/with-desktop-lock.py`, one owner at a time.
  Simulated tests never prove physical Fn/microphone or packaged-app
  behavior.
- `codesign --verify --deep --strict` fails spuriously in this synced
  Documents checkout — verify on a copy outside it.
- Other agents share this folder: never stash/reset/clean; commit or push
  only when asked. Stage milestone commits by file name — never
  `git add -A`.
- Parallel work: `git worktree add`, then
  `python3 scripts/setup-workspace-development.py` inside the worktree.
