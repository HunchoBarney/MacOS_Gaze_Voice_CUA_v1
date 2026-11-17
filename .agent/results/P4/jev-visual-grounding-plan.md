# Evidence-Backed Visual Grounding

Status: proposed implementation within the approved generic visual fallback.
This is not acceptance and does not authorize changing a probability floor.

## Evidence

The signed pilot safely refuses a correctly located triangle. The actual
read-only request shows a native `AXButton` labelled `symbol-0`, numeric
normalized bounds and a screenshot, but no image identifying that native node.
Grounding returns location .86, authorization .85 and ordinary control .76.

Two bounded image-overlay/detail experiments do not fix positive grounding.
Do not ship them as fixes. See `jev-visual-grounding-handoff.md`.

A separate documented image-criteria experiment makes 12 requests using
real captured native controls, not synthetic model answers. The pictured green
control matches the requested identity at .98 and is authorized at .98 in both
trials. Red identity is .99 and authorization .97. Missing colors/shapes return
none at .98-1.00. A contradictory prohibition suppresses authorization.

The same requests split control classification between ordinary and toggle:
green ordinary .46/toggle .37 in one trial; red toggle .57/ordinary .35.
The current criteria define these classes only by their raw enum words.
These results do not permit adding probabilities, lowering a floor, bypassing
classification, assuming an ordinary button, or introducing another proof path.

Current model docs checked November 11, 2026 still identify `jev-1.14.0` as
the newest release, with preview pointing to the same version. No model upgrade
or alias switch is proposed.

## Minimal Change

1. In the existing grounding request, attach a faithful image of each eligible
   native candidate from the same captured frame. Preserve the original full
   image and every current capture/snapshot/transport/subject check.
2. Derive the native picture using the existing frame transform and native
   rectangle. No color/shape recognizer, app recipe, model-generated label or
   invented accessibility description. Keep image refs with their real node.
   Pad small native images to the API minimum without adding neighboring
   controls. Do not draw a marker over the control.
3. Keep the existing independent located/authorized/control/protected/deny,
   native-match and native-selection judgments. Give native selection its
   candidate pictures, which the current TypeSafe API explicitly supports.
   Native pictures are evidence, never authority or permission.
4. Make the authorization question operation-specific in code. The present
   question's missing-literal clause can apply to non-typing operations.
   Only a type-text question should discuss a missing caller literal.
   Click/key/scroll questions retain the full goal/history/deny constraints.
5. Define the existing control categories explicitly. A toggle is a visibly
   stateful switch/checkbox/radio control, not every button that changes the
   screen. Explicit protected consequences take precedence over cosmetic
   widget type. Unknown remains unknown. No enum, risk class or policy
   meaning changes.
6. Make primary target presence a visibility/identity predicate. Location,
   permission and outcome continue to be separate required checks.

## Boundaries

- No threshold, permission, model, public schema, driver or completion change.
- No alternate native proof, risk-class summation or manufactured ordinary class.
- No additional per-action model request; extra pictures share the current
  grounding request and remain under the existing client resource guards.
- No removal of the capture-bound pixel fallback when native identity is weak.
- No production trace hook or logging of arbitrary user images.
- Existing text/AX/DOM paths and exact native replacement proofs stay unchanged.

The changed production files are `JevVisualDecision.swift` and `VisualTarget.swift`.
Tests use the actual production helper/decider seams. The packaging and evidence
scripts may admit only the precisely reviewed source delta. Frozen cross-phase
interfaces are not changed. If implementation would require changing authority
or an acceptance bar, stop for a new G1 decision instead.

## Guards Before Code

- Reject invalid or foreign native image rectangles, mismatched snapshot/token
  and a source whose capture data is not the bound frame.
- Exercise normal and padded frame transforms, clipped/off-image rectangles,
  minimum image dimensions and untouched original image bytes.
- Verify each emitted candidate reference resolves to its own captured region,
  not a sibling's picture or a fabricated label.
- Verify click authorization contains no typing/missing-literal premise;
  type-text retains literal and editable-field protections.
- Retain refusals for absent targets, wrong point/control, protected inputs,
  forbidden actions, stale captures and changed subject.
- Keep all floors and native-preference gates unchanged.

## Proof

Run focused checks through the serialized lane, then independent source and
consumer review. Build one isolated signed candidate with unchanged driver and
runtimes. Run one owned visual command; inspect its actual counter and complete
trace. If it passes, run a small matched comparison, including absent/wrong
targets and policy cases. Never retry a failed command until it looks green.

Report failures and time regressions. A passing component check is not a
passing desktop task. If the full visual command still refuses, do not claim
this resolves it or weaken the gates. P4 remains open until its actual bench
and everyday-app requirements pass.
