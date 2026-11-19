# Working in Jarvis

[PROGRAM](.agent/PROGRAM.md) defines done; [SHIP-PLAN](.agent/SHIP-PLAN.md)
sets delivery order. [PLANS](.agent/PLANS.md) is the repository authority
for delegation, workspace ownership, verification and phase gates. Read
the current issue/handoff and relevant [progress entries](.agent/PROGRESS.md)
when resuming; append a handoff before stopping phase work.

- Delegate bounded questions within approved scope. Use crew threads for
  outcomes, shared readers for the exact tree and isolated writers for
  disjoint changes. Sequence overlap. One integrator holds the Mac build
  token; one operator runs an authorized physical session. A pause applies
  to the whole crew. Delegation grants no new data, spending or live access.
- Use the smallest proof that answers the claim. A focused green run
  is not phase acceptance; a signature or dispatched action is not a
  physical result. Preserve final words, exactly-once authority and
  independently observed effects. Speed goals are targets, not measurements.
- Read [REUSE](.agent/REUSE.md) before new phase work: existing code and
  platform APIs first, then maintained free open source, then minimum glue
  or a documented gap. Record capability, version and license at G2.
- Keep direct grounded actions, Jev as primary chooser, Cua/native execution
  and the approved Terra recovery route. No replacement-model tournament.
  [COMPETITIVE](.agent/COMPETITIVE.md) defines matched comparisons.
- Phase ExecPlans declare owned paths; only independent verdicts can pass
  default-FAIL criteria with evidence. Changing a frozen [contract](.agent/CONTRACTS.md)
  requires a Decision Log entry and re-review of every consumer.

## Commands (references, not permission to install, sign or launch)

- `make local` — **the daily driver**: build → stage → sign → install to
  `~/jarvis-local/Jev Voice.app` → relaunch → wait for the tracker API.
  One command from clean checkout to running app; `make run` aliases it.
- Use the assigned `scripts/verification-lane.sh <scope>` for product
  checks; report what that scope actually ran.
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
- Preserve inherited work; never stash/reset/clean it. Leave changes
  unstaged unless asked. Commit, push, publish or merge only with explicit
  authorization for that action; stage approved files by name, never `git add -A`.
