# Start here: execute the approved Cua/Jev voice migration

Updated 2026-09-19 for the approved Cua capability/perception and voice-coordination revision. This update records the plan; it does not claim implementation. When asked to implement, work through all phases to packaged delivery. Do not reopen planning or rebuild completed UI.

## Read and resume

Read PLAN.md's active scope/progress and SPEC.md S1–S9. Inspect applicable repository instructions and only the code/docs needed for the current phase. Historical sections are reference-only and contain superseded constraints. The spec owns behavior, the plan owns sequence/evidence, and this file owns execution instructions. Later explicit user instructions apply subject to system/developer constraints.

Start at the first unfinished gate in P0–P5, using the current progress table. Previously implemented speech/UI/provider work is preserved, not automatically rebuilt. Check actual source and evidence before assuming work is absent or complete. Preserve tracked/untracked changes, credentials, preferences, and working functionality. A HEAD-only checkout does not include the user's current baseline. Do not reset/clean the checkout or automatically commit unrelated work.

## Authority and completion

Upon an implementation request, make necessary local code changes, build/package/launch, run tests, and perform reversible integration checks with disposable content. Continue through debugging, review, simplification, and final package validation without milestone approval requests. Checkpoints report progress; they are not permission gates. Do not stop at an initial implementation or a passing unit suite.

Choose a simpler supported approach when inspection or measurement supports it. Record material architecture/version changes and their evidence in PLAN.md. Required behavior, preservation requirements and acceptance gates cannot be silently weakened. Use the actual selected Cua/TypeSafe/Apple contracts. The approved plan permits building and repairing unmerged Cua code; draft status alone is not a blocker. Audit ancestry and overlapping PRs, pin the smallest coherent set and verify its combined build. Do not narrow supported capabilities to make tests pass. Reuse existing voice coordination mechanisms without importing unnecessary complete frameworks.

Ask only for essential unresolved product decisions, unavailable credentials/hardware, user-controlled OS grants/physical input, or actions outside the authorized scope. Do not ask the user to run checks the agent can perform. Do not send real messages, buy, delete personal content, change OS security settings, or export secrets as integration tests. Use local disposable fixtures for these boundaries.

## Phase loop

1. Establish the phase's entry conditions and inspect relevant contracts/code.
2. Implement the smallest complete behavior. Reuse existing coverage and add focused tests for uncovered behavior and regressions.
3. Run appropriate automated checks and real application checks; observe the intended external result where possible.
4. Review the complete phase diff for correctness, cancellation/target ownership, regressions and unnecessary code. Simplify where it reduces risk.
5. Repair findings and rerun affected checks. Broaden/repeat tests only for changes, failures or unresolved concerns.
6. Record evidence, decisions, unresolved blockers and the next phase. Proceed automatically when the gate passes.

Do not advance dependent work on an unproven foundation. Continue independent work while waiting for optional feedback or a physical check; keep that check pending. A timeout or lack of feedback is not approval or evidence. Review is a distinct pass against requirements, not merely a reread of the implementation's own tests. A separate reviewer can help where available and authorized, but is not a mandatory per-phase ceremony.

## Evidence and recovery

For adopted upstream code, record exact revisions, dependency order, local repairs and attribution. For each gate record source/build identity, exact commands/checks, results, sanitized artifact paths, observed app state, timing boundaries/sample counts, and remaining limitations. Label evidence as automated simulation, observed OS behavior, or user-reported physical input. Never label fixtures as a physical speech test. Retain failed outcomes in timing/accuracy reports; do not select only fast successful runs.

The baseline, a tool success response, screenshots, or an AI review alone do not prove the new app works. Validate composed workflows and alternative phrasings, including those not used to tune the implementation. Preserve test intent; explain corrections to faulty tests using the spec. Do not relax assertions or remove failures just to obtain green results.

On interruption or context compaction, resume from PLAN.md's current phase and evidence; do not redo completed phases without a reason. On an external blocker, describe its exact impact and completed independent work. On uncertain runtime mutations, inspect state and never automatically replay them. After a review fix, rerun the checks affected by that fix before delivering.

## Final gate and handoff

Review the complete migration against the preserved working baseline, including untracked files and packaging changes. Remove obsolete production execution/speech paths and document preserved behavior. Run the final relevant regression suite, validate the actual installed package (not merely the development binary), and verify rollback instructions. If acceptance is blocked, state that the app is not fully accepted.

Finish with the app location, Fn/task/dictation/correction usage, verification results by evidence type, measured timings/sample counts, limitations, and rollback location/instructions. Do not claim universal app support or tested hardware/OS versions that were not exercised.

## Research basis and scope of claims

Official Astra guidance favors focused context, clear decision boundaries, and explicit persistence through a complete outcome. This execution contract applies those principles; it is not an official mandatory template. The research below supports evaluation choices, not a guarantee of autonomous success or of Cua capability.

- [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra): avoid bloated/conflicting recipes; define authorization and stopping boundaries.
- [Astra model guide](https://developers.openai.com/api/docs/guides/latest-model): pursue the requested outcome and use proportionate verification.
- [Long-horizon Codex work](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex): durable spec, milestones and evidence; broader workflow, not Astra-specific performance evidence.
- [SpecBench](https://arxiv.org/html/2605.21384v2): visible feature tests can miss failures when features are composed; motivates combined application workflows.
- [DeepSWE](https://arxiv.org/html/2607.07946v1): functional verifiers should accept different implementations that satisfy requested behavior.

Research reviewed on 2026-09-19; official Astra prompting guidance rechecked for this revision. No mandatory full-repository reread, fixed file architecture, per-step commit, or repeated full-suite ritual is required. Historical instructions retained elsewhere do not override this contract.
