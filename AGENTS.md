# Working in Jarvis

Read README.md and the relevant part of docs/ARCHITECTURE.md before changing a subsystem.
Use docs/DEVELOPMENT.md for commands and prerequisites. SwiftPM discovers the grouped
source/test directories automatically; retain the existing module boundaries unless
there is a concrete reason to change them.

The migration remains incomplete. docs/voice-ui/SPEC.md owns active behavior;
PLAN.md owns current gates; EVIDENCE.md records build-specific results; HISTORY.md
is reference-only. Follow EXECUTION.md only for an authorized migration task.
Do not turn unrelated maintenance into migration implementation.

For the approved execution simplification, follow
docs/EXECUTION-SIMPLIFICATION-PLAN.md for scope, sequence and completion. Use the
voice specification as a behavioral constraint; do not automatically resume P0–P5.
Prove each Cua/Jev replacement before deleting a protection. Record scoped results
as simplification evidence without closing unrelated migration gates.

Preserve credentials, preferences, app identities, dependency pins, and unrelated
work. development/ is ignored but contains unique source, evidence, models and
recovery bundles; it is not a disposable cache. See ThirdParty/Cua/README.md before
changing or rebuilding Driver. Never auto-upgrade the pinned runtime.

Ground diagnoses in relevant code, logs, or observed behavior. Label suspected
causes as hypotheses until supported. Verify uncertain API behavior against the
installed version or authoritative documentation; do not invent capabilities.

Choose verification based on affected behavior and risk. Start with relevant
existing tests; add coverage for genuine behavior gaps, not tests that merely
mirror the implementation. Use `make test` for the default regression suite when
warranted or required by the task. Preserve required checks and acceptance criteria.
Repeat or broaden checks only when relevant edits, failures, or unresolved risks
justify it. Documentation-only changes generally need content/diff review, not app tests.

Live tests are opt-in and can mutate macOS. Run them with the desktop lock described
in docs/DEVELOPMENT.md, one desktop owner at a time. Distinguish automated and
recorded-audio checks, observed app behavior, and user-reported physical tests.
Do not claim physical Fn/microphone or application acceptance from simulated tests.
Record pre-existing failures separately from regressions.

Use small, responsibility-focused changes. Preserve behavior and test intent;
review complete affected paths. Do not add frameworks or abstractions without a
current need. Legacy code still supports regression comparisons and conditional
fixtures; inspect usage before removal.

Fix the shared cause when evidence supports it; avoid app-specific workarounds for
general defects. Keep unrelated refactors and speculative improvements out of scope.
Finish when the requested outcome is supported by appropriate evidence, required
checks pass, and material review findings are resolved. Do not start another cleanup
or verification cycle without a concrete reason. Report what changed, what was
actually verified, and remaining limitations; if blocked, state the unmet requirement
without claiming completion.

For parallel worktrees, run `scripts/setup-workspace-development.py` through
Conductor setup. `development/JevVoice/cua-source` and generated outputs must be
workspace-local. Treat `development/JevVoice/reference/` as read-only shared inputs;
never write through its links or the legacy `~/Library/Caches/JevVoice` path.
Copy inputs locally before modifying them. Preserve ignored source edits as a
reviewed patch when sharing work. See docs/LOCAL-DEVELOPMENT-STORAGE.md.
