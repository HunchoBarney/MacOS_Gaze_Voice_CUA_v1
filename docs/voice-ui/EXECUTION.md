# Start here: continuous voice control in the existing UI

The original voice UI is delivered. On 2026-09-18 the user requested an updated plan for demo-like continuous execution, reversible corrections, and tests suited to installed apps. That extension is planned, not implemented. Read the current SPEC.md and the active milestones in PLAN.md. Consult prior delivery evidence only when it is relevant to verification or recovery. This documentation update does not authorize starting implementation in a planning-only turn.

## Read only what the task needs

1. Read [PLAN.md](PLAN.md)'s incremental scope and active progress; start at the first unfinished milestone.
2. Read [SPEC.md](SPEC.md)'s C1–C5 for the new behavior. Consult R1–R6 only for preservation constraints relevant to the code being changed; they are not a backlog to rebuild.
3. Inspect the files needed for that milestone and any applicable repository instructions. Load specialized skills only when they materially help the current work.

The spec owns behavior; the plan owns sequence and evidence; this file owns working instructions. Keep status and decisions in the plan rather than creating another tracker. Later explicit user instructions take precedence over this plan and skill preferences, subject to higher-priority system/developer constraints. Surface an actual conflict precisely rather than silently changing scope.

The updated behavior replaces release-only execution: complete supported commands may execute during a held Fn session. Capture and serial action execution overlap; separate Fn sessions do not. Explicit correction can undo a just-launched app using observed pre-action state. Finalization, error recovery, and transcript review must never replay completed actions. Keep the existing pill, microphone path, Jev integration, preferences, and ordinary-command automatic execution.

Implement only the missing behavior. Reuse the current Fn input, speech engine, microphone picker, permissions, pill/settings, Jev client, command planner, executor, and packaging. Modify a working component only for a demonstrated integration need or regression; record the reason when material. Reuse existing tests instead of duplicating their coverage. Historical evidence is optional reference for a specific failure or rollback, never a list of work to repeat.

## Work through to a demonstrated result

Once implementation is requested, carry the work through implementation, running the app, verification, repair, code review, simplification, and packaged validation. A first implementation or passing build is not completion. Present checkpoint results while continuing independent work; do not turn every milestone into an approval stop.

Make routine reversible implementation choices yourself. You may change decomposition, internal APIs, and tunable timings when repository evidence or measurements justify a better approach. Record the reason and preserve the spec's behavioral guarantees. Do not change models, add product modes, weaken confirmation, raise the OS minimum, or discard existing work to make tests pass.

Ask focused questions only when a material product decision is unresolved, an essential credential/device is unavailable, or an action genuinely needs the user's participation or authorization. Do not ask the user where discoverable code is or ask them to run tests the agent can run. If a skill causes a pause, identify the specific instruction and explain why it applies; do not infer extra approvals from generic workflow language.

During live checks, use disposable documents and reversible commands. Keep API keys, private clipboard contents, personal documents, and recordings out of evidence logs. Use real model calls only for the relevant integration smoke checks, not in the normal unit suite. Do not change OS security settings automatically or represent synthetic keyboard/audio tests as physical validation.

## Verify proportionately and adapt to evidence

- Use focused behavioral tests for session races, input/audio interruption, cancellation, target preservation, persistence, and cleanup. Do not write tests that merely restate styling constants or private implementation details.
- Use fakes for controlled timing/failure tests and the real packaged app for OS integration. Passing one does not establish the other.
- Repair failures caused by the change before moving on. Distinguish pre-existing failures and missing test hardware explicitly.
- Run the final regression suite once the feature and review fixes are ready. Broaden or repeat checks only when new changes, failures, or unresolved concerns warrant it.
- Review the diff for unnecessary dependencies, duplicated state, blocking UI work, and speculative architecture. Prefer a small coherent implementation over a generalized framework.
- Checkpoint updates should state what works, what evidence establishes it, what remains uncertain, and the next useful user test. User feedback can steer the work without erasing completed progress.

Stop when the specified deliverable works and the acceptance evidence is recorded, or clearly report the specific external blocker preventing remaining verification. Never silently lower the completion bar. The final handoff includes the app location, brief usage instructions, validation results, measured timings, limitations, and rollback location.

## Astra-specific basis

This brief applies official guidance to this repository; it is not a claim of a special required Astra plan format.

- [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra): keep guidance focused, avoid conflicting recipes, and define completion and decision boundaries so the agent persists through the intended work.
- [GPT-6 Astra model guidance](https://developers.openai.com/api/docs/guides/latest-model): calibrate autonomy, clarification, and verification to the task; do not trigger unnecessary repeated testing.
- [Run long horizon tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex): maintain a clear spec, testable milestones, and durable evidence/decisions. That article describes a broader coding workflow rather than an Astra-specific guarantee.

These sources were read during the 2026-09-18 audit. Their recommendations inform the document structure; the approved product requirements and real test results determine acceptance.
