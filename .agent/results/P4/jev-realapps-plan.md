# Real App Qualification Plan

User-approved: Chrome, Safari, Spotify, Notes and other native apps.
New labelled Notes note may sync and is kept. Spotify play/pause only on
this Mac; no remote device switch, playlist/account edits or existing
document changes. Public pages in new owned browser windows/profile.

Subject: signed candidate6ec, unchanged source and pinned Cua0.38.
Front door: packaged MCP -> actual native apps. Not Fn/ASR qualification.
Normal standing grant and existing OS permissions required.

## Hypotheses

1. Captured-window targeting, actual values and next-step selection work
   in real native/browser layouts, including repeated navigation/editing.
2. Reported done/already agrees with independently read real app state,
   without success strings or expected-answer hints sent to the actor.
3. Native latency is measured with the production daemon settings, not
   the older synthetic runner's missing window-change timeout override.

Initial budget: up to12 representative cases,3 repeats when stable;
30s caller deadline per task,4s T3 latency bar separately reported.
40-minute first pass,100 local setup/probe commands before reassessment.
Additional diagnostic runs are labelled and never replace failed rows.

## Cases And Independent Checks

- Chrome/Safari: navigate to public site, Google query, back/forward.
  Read browser's committed URL/title, not just typed input or returned Done.
- Spotify: search public artist; play then pause existing track only if
  current Connect device is verified local. No queue/playlist edits.
- Notes: new detached Jev Test note; type synthetic content and edit it.
  Read document body from the real app, not transcript/clipboard echo.
- TextEdit/Calculator: controlled new document / fresh numeric calculation.
  Read actual document/result. Do not open existing user documents.

Preconditions are deterministic setup, not scored actor actions. Verify
the oracle rejects initial/wrong state. Record actual effect, strict result,
false_done, deadline/cancellation, wall time and cleanup independently.
No unconditional sleeps as readiness, no private raw UI logs, no whole
desktop screenshots. Only owned window captures after privacy checks.

## Ownership And Runtime

Owned changes: `.agent/results/P4/jev-realapps*`, new result records,
`scripts/verification-lane.sh`, phase progress/evidence. No product source
changes until an observed defect is reproduced. No vendor/resource swap,
permission edit, provider/model/threshold change, install, commit or push.

Existing GUI socket hint is stale/missing. Use an owned standard embedded
driver as the previous native lane, explicitly not GUI-autospawn evidence.
Driver embedding's normal `--no-permissions-gate` belongs to the documented
standard/existing-profile host contract; it does not bypass OS TCC or the
Jev standing-grant policy. No dangerous bypass flags or fabricated grants.
Match production defaults: window-change timeout100ms,poll25ms
(`Sources/JevVoice/Driver/CuaDaemonHost.swift:42-67`).
Old synthetic daemon omitted those env keys. Do not relabel old timings or
claim a speed improvement without a same-harness paired configuration run.

All tests via serialized verification lane and desktop lock. Reuse
`bench/lib/mcp_stdio.py` and classifier; actual SDK schemas discovered
locally, not guessed. No personal titles/body stored or sent during setup.
Own processes only; keep new Notes note and do not close user windows.

## Native Text Mutation Repair

Real TextEdit evidence a3f23b91027544e3a91997b9e8948ce5: replacement
request inserted the literal before the old body. Jev safely reported stuck.
The SDK documents type_text as insertion, set_value as whole AXValue write.
The current candidate set has insertion but no replacement or select-all.
Failure modes to test before source changes: replacement must use the
caller's exact literal and original field token; asked replacement values
must use value rather than text; insertion must remain insertion; secure
fields must not gain a new replacement option. SDK unsupported writes
must remain refusals, not fall back to insertion. No new tool schema,
permission changes, model swap or lowered completion threshold.
Explicit empty replacements must remain valid literal input. A known-empty
editable value can prove clearing; unknown/nil, secure and blank decorative
nodes cannot. Add those negative checks before changing goal facts.
