# Shipping-plan documentation update

Date: 2026-11-15. User authorization: update existing plans/docs, include
the whole review and faster interaction goals, and require free open-source
reuse before custom implementation. This is a documentation self-check,
not an independent G2/G4 verdict or a product qualification.

## Delivered

- `.agent/SHIP-PLAN.md`: C1 fast ordinary use, C2 complete task routes,
  C3 integrated release; next implementation scope, gates, evidence,
  bounded model experiment, real-app restrictions and rollback.
- `.agent/REUSE.md`: standing FOSS-first rule, licensed component inventory,
  current upstream research versions/HEADs and adopt/adapt/gap decisions.
- PROGRAM/PLANS/CONTRACTS/AGENTS/template: shipping cadence, explicit
  implementation-readiness handoffs, stricter unproven speed goals,
  reuse checks, source/physical evidence boundaries and review queue.
- P3/P4 plans: current C1 scope with old acceptance preserved.
- P5–P13: nine complete draft ExecPlans and nine schema-valid acceptance
  files containing 57 criteria, all false with null evidence.
- README: corrected stale claims about dependencies, local speech,
  automatic Fn screenshots, partial dispatch and perception setup.
- Original report: a follow-up link distinguishes the historical audit
  baseline from the new planning artifacts.

## Verification performed

The existing `scripts/check-acceptance.py` validator accepted all 17
phase files. All eight pre-existing acceptance files retain exactly
their pre-update SHA-256; P3 remains 0/8 and P4 remains 4/6.
All new criteria are false/null. No completion flag was awarded.

All nine new plans have the 13 required sections, one owned-path block
readable by the existing `check-owned-paths.py` parser, and a one-to-one
mapping of their acceptance IDs. Each owns its own plan, acceptance and
future results. New verification modes and live artifacts are explicitly
implementation deliverables, not tools/results presumed to exist.
The staged-path checker was not used to imply ownership of unstaged or
inherited files.

Local Markdown links in the current entry docs/new plans resolve; fences
are balanced and checked documents have no trailing whitespace.
`git diff --check` passed for the tracked entry documents/template.
The cumulative git diff includes inherited edits and is not presented as
this task's delta.

The implementation fingerprint before and after the planning edits is:

```text
291 unignored files returned by git ls-files under Sources, Tests,
EyeTracking, scripts, ThirdParty, Makefile, Package.swift, Package.resolved
SHA256: 558e8489bfbd71b6a16aa210db99b55296b1694cd447c124b0a565aba26c7145
```

The digest sorts unique paths and hashes each path plus its content
SHA-256. This verifies that enumerated implementation set; ignored
generated/runtime files are not represented by that claim.

Research used read-only primary documentation and public repository
metadata. No dependency was installed/upgraded, paid inference called,
app built/tested/signed/installed, desktop changed, helper agent spawned,
commit made or external message sent.

## Current limits and continuation

50ms dictation, 100ms native and 500ms visual medians are unproven
engineering goals with declared clocks and p95 goals in PROGRAM. No
latency improvement is claimed by these documentation changes.
The old release bars remain binding; misses against the new goals must
be visible and addressed or explicitly decided before shipping.

The source implementation and independent G1/G2 review of the new scope
remain pending. The next bounded implementation milestone is C1:
bind the current candidate, resolve D120/D121 evidence semantics and dwell
default, trace the actual speech/native/driver path, improve incremental
finalization/direct input using existing facilities, then verify one
coherent candidate. Preserve the daily app until its replacement is
prepared, proven and approved.
