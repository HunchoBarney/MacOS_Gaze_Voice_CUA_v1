# Ground the Target the Driver Actually Uses

Status: proposal for senior contract review before code.
No new authority, threshold or acceptance change is authorized here.

## Observed Failure

The reviewed picture-backed candidate still refuses the owned visual task.
Its signed pilot leaves both counters at zero and reports blocked in
2504.079667 ms. Presence is .98, control ordinary .97, location .85 and
authorization .92. No action or false completion occurs.

The subsequent read-only production preview makes four model requests,
zero actuations and cleans its resources. Its real grounding request has
exactly one pictured native button containing the proposed point:

- Native selection: `element_1`, probability .97.
- Independent precise native match: .95.
- Control ordinary: .98; protected .01; every deny .01.
- Pixel-center location: .84; pixel-center authorization .90.

The current source requires the last two pixel-center judgments even
when the eventual request uses only `capture_id` and `element_token`.
The driver does not use an x/y coordinate on that native route.
This is an actuator/reference mismatch, not evidence that .84 is sufficient.

Evidence: `grounding-visual-pilot/summary.json` and
`grounding-visual-readonly/{request-3.json,answers-3.json,capture-receipt.json}`
inside the existing completion-research workspace.

## Proposed Minimal Fix

Keep the original pixel judgment group and a complete speculative group
for each eligible, faithfully pictured native candidate in the existing
grounding request. Do not truncate candidates or add a hidden cutoff.
Unsupported or uncertain native identities retain the existing path.

1. Pixel questions remain unchanged and refer to the box center.
2. Additional speculative native questions refer to the named captured
   node and its picture, not a numeric point. Location asks whether that
   exact native object is the intended visible control, not merely a
   containing parent or neighboring item. Authorization, classification,
   risk, every deny and editability all refer to that same object and
   the actual proposed operation/key/literal.
3. Use the same question factory with an explicit target reference.
   Do not duplicate or weaken the policy definitions.
4. Choose the authority branch before reading its policy answers:
   native only when the pictured candidate is the exact selected node
   at selection >= .95 AND independent native match >= .95, with the
   existing capability/snapshot/token/rectangle/image/transport binding.
5. Once that exact native identity is selected, consume only its complete
   native judgment group. Any missing, uncertain or adverse native
   policy answer blocks; do NOT retry via pixel input to evade it.
6. If exact native identity is unavailable or uncertain, retain the old
   pixel route, requiring its entire original judgment group. Do not
   combine a native location with pixel authorization or vice versa.
7. All numeric floors stay unchanged: presence/location/authorization
   .95, control .90, protected/deny .05 and editable .95. Native identity
   still needs both existing .95 checks. No synthesized probability.
8. Native requests must contain the captured token and CID, never x/y.
   Pixel requests keep their exact original capture-bound transform.
   Stale/foreign tokens, epochs, task subjects and captures still refuse.

No new model, RPC, driver, grant, public schema, completion rule or
round limit. Original full image stays present; native pictures remain
evidence only. Native data is not permission. Completion still needs
a fresh independently supported outcome.

Prefer using the existing optional `VisualTarget.nativeElement` to
identify the actual authority reference. If a new frozen field or a
weaker authority rule is necessary, stop for a separate G1 decision.

## Failures to Guard Before Code

- Pixel location .84 cannot authorize a pixel request.
- Strong native identity plus weak native location/authorization refuses.
- Weak/missing native identity cannot borrow native policy answers.
- Missing native answers, token/capture/snapshot/epoch swaps and absent
  pictures refuse native authority.
- Native deny/protected/credential/unknown failures cannot escape through
  a more optimistic pixel answer.
- All policy answers used belong to the same chosen native reference.
- Typing still requires the exact caller literal and confirmed editable,
  non-secure field; key/scroll retain operation-specific eligibility.
- Native request has token plus CID and no coordinates; pixel fallback
  remains available only under its original checks.
- All speculative groups share one grounding RPC, no voting/retry loop.
- Multiple pictured native candidates retain all options and their own
  policy answers; no sibling's answers can authorize the chosen token.

## Proof

Write tests through the real decider/target seams before implementation,
then run focused serialized checks and independent consumer review.
Stage only the reviewed source change on the same driver/runtime payload.
Run one owned signed-app command with counter readback. If it passes,
run a small clean same-driver source comparison and the affected policy
negatives, preserving every failure. No reliability or speed claim from
one run. P4 remains open until the complete required evidence passes.
