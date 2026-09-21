# Working in Jarvis

Read README.md and the relevant part of docs/ARCHITECTURE.md before changing a subsystem.
Use docs/DEVELOPMENT.md for commands and prerequisites. SwiftPM discovers the grouped
source/test directories automatically; retain the existing module boundaries unless
there is a concrete reason to change them.

The migration remains incomplete. docs/voice-ui/SPEC.md owns active behavior;
PLAN.md owns current gates; EVIDENCE.md records build-specific results; HISTORY.md
is reference-only. Follow EXECUTION.md only for an authorized migration task.
Do not turn unrelated maintenance into migration implementation.

Preserve credentials, preferences, app identities, dependency pins, and unrelated
work. development/ is ignored but contains unique source, evidence, models and
recovery bundles; it is not a disposable cache. See ThirdParty/Cua/README.md before
changing or rebuilding Driver. Never auto-upgrade the pinned runtime.

Use `make test` and relevant focused checks; live tests are opt-in and can mutate
macOS. Run them with the desktop lock described in docs/DEVELOPMENT.md, one desktop
owner at a time. Do not claim physical Fn/microphone or application acceptance
from simulated tests. Record pre-existing failures separately from regressions.

Use small, responsibility-focused changes. Preserve behavior and test intent;
review complete affected paths. Do not add frameworks or abstractions without a
current need. Legacy code still supports regression comparisons and conditional
fixtures; inspect usage before removal.
