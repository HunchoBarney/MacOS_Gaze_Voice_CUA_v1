# Start here: implementing the approved voice UI

The user approved this feature plan on 2026-09-18. The current delivery is documentation only; app implementation has not begun. This brief governs a subsequent implementation request and is not a claim that permission prompts or physical tests have already been completed.

## Read only what the task needs

1. Read [SPEC.md](SPEC.md) for required product behavior and boundaries.
2. Read [PLAN.md](PLAN.md) for the current milestone, relevant code, validation, and progress.
3. Inspect the files needed for that milestone and any applicable repository instructions. Load specialized skills only when they materially help the current work.

The spec owns behavior; the plan owns sequence and evidence; this file owns working instructions. Keep status and decisions in the plan rather than creating another tracker. Later explicit user instructions take precedence over this plan and skill preferences, subject to higher-priority system/developer constraints. Surface an actual conflict precisely rather than silently changing scope.

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
