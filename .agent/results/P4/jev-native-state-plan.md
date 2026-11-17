# Native observation repair: proposal, NOT implemented

Senior G2: PASS from d3665964. No new G1 required inside this architecture.
Keep window/sheet root lineage unambiguous; negative local IDs must never
gain tool authority, including relocation/extras. Helper visibility change
is read-only and must not alter P3 binding semantics.

## Actual new evidence / stop condition

Signed current candidate STILL stops after one Continue at stage1:
native-pilot-05fbd12319614df39e225c9cf6774879/results.json.
Stage source receipt5c8d1a0086ec453e920a0d709f2c549d, app
/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-p4-release-h9a7gmdx/Jev Voice.app.
Do not install this yet or run full candidate24 until fixed.

Direct raw pinned driver observations confirmed WHY:
- Cua0.38 structured elements contains ONLY actionable/indexed nodes.
  Read-only Step1/2/3 of7, calculator expression/result exist ONLY in
  tree_markdown. DriveCandidates.axSnapshot/observationFields ignores
  those nodes. Jev never sees actual stage/result and fingerprint sees
  unchanged controls! Not merely prompt/JeV inability.
- CuaConnection.argumentsForTool defaults full_output:true to get
  structured rows. That ALSO expands hidden Apple/Recent Items menus.
  These include incidental OS filenames/app names. Current model body
  includes all rows, so those could reach TypeSafe in native runs.
  USER WAS IMMEDIATELY TOLD; no documents opened/modified, no contents
  read. ALL further model-backed desktop runs stopped until scope fix.
  Two OUR GENERATED raw dirs moved outside repo; private locations in
  jev-private-capture-location.json. Do NOT expose/copy private metadata
  into reports or send more model calls using unfiltered native state.
- Actual raw schema (nonsensitive) remains
  native-raw-ccf9f402e016497fb1c410bfebacf8cb/get-window-state-schema.json.
  tree_format accepts markdown/elements/both. full_output controls walk
  and menu expansion; "both" gives needed projections without full mode.
  Driver parent_index/depth ARE present on real indexed rows. Window
  index0/depth0; descendants parent0; MenuBar5/depth0 separate root,
  Apple6 parent5; menu descendants all outside window root.

## Proposed minimal scope-safe repair for G2 review

Keep driver pin/hash unchanged; no upstream edits or brittle Markdown
parser. This macOS app can use existing platform AX APIs.

1. DriveCaptureSource get_window_state explicitly tree_format:"both"
   (so CuaConnection default-full shim does NOT add full_output:true).
   Existing max_elements600/max_depth20 preserved. Preview same.
   Avoid global CuaConnection default change affecting other P3 readers.
2. New shared window-observation projection for production+preview:
   validate pid/window_id if present; scope structured rows to requested
   AXWindow/AXSheet root and parent_index descendants; exclude separate
   MenuBar/menu roots BEFORE model/candidate construction. Fail closed
   if scope ambiguous, no guessed sibling/focused-window substitution.
   Legacy flat mocks can be accepted only when no out-of-window roots.
3. Supplement display-only data by reading ONLY exact native AXWindow
   matching captured PID+windowID. Reuse platform identity helper:
   FocusedTextTarget.swift already has private windowNumber(_:) using
   _AXUIElementGetWindow via dlsym. Prefer expose that internal read-only
   helper (one access-level change, no behavior change, owned-path audit)
   over duplicate SPI wrappers. NEVER use frame/focused-window fallback.
   Existing WindowControls/Gaze window resolvers use approximate frames
   and are NOT adequate for this strict source.
4. Use AXUIElementCopyMultipleAttributeValues for role/subrole/title/
   description/value/children/position/size to avoid per-attribute IPC;
   read only window.children (never app/menu roots). Same AXDepth budget.
   Bound messaging timeout; dedicated/detached observation work, not
   blocking main actor. Verify original AXWindow identity still matches
   before/after, else discard. Honor cancellation. No actuation.
5. Append ONLY non-addressable display nodes, preserve actual role,
   labels/value/frame, actions=[]; nil tool token, reserved negative
   local IDs (stable DFS). DriveCandidates.actionable MUST reject
   negative local IDs so an observed row/text area never gains typing/
   click authority. No made-up driver element indices/snapshot tokens.
   Secure subrole/value masked before model. Existing privacy helper
   applies. No duplication of native actionable values already in SDK.
6. All production, preview, completion checker and full-context proof
   use SAME merged captured-window observation. Semantic verifyState
   fresh read must repeat BOTH underlying reads; never trust stale cache.
7. Remove another CONFIRMED hidden cutoff:
   DriveLoop.fingerprint still elements.prefix(160). Tail state changes
   are ignored, so >160 valid controls can trip false stale despite
   progress. Use platform Hasher.combine on ALL typed fields/elements
   (also removes concatenation boundary collisions); process-local
   stale signal only, not a stable persisted identity.

## Before code

Senior plan G2 before structural/source changes; user already authorized
captured-window integration repair, observed evidence, no new mutation
authority/driver pin. If senior requires fresh G1, ask only then.

Write red production tests BEFORE source:
- Real native schema fixture WITHOUT any personal menu content:
  controls+separate MenuBar roots, readonly display supplied via native
  capture seam; Stage2 values reach model AND fingerprint, no OS menu
  data/candidates, foreign window mismatches reject.
- Native non-addressable data cannot create action even editable role.
- Native collector exact window only, no frame/focus fallback; live
  isolated fixture check sees Step2 and no unrelated menu text.
- Fingerprint tail beyond160 and label/value-boundary collision.
- Existing goal-only fresh read/context/private-value checks remain.
- Local explicit read-only status with word Password may now be
  accidentally blocked by shared model-safe fact collector (suspected
  regression, NOT reproduced yet); avoid weakening model privacy.

After fix: focused9+new red regressions then full lane, fresh scoped
review, rebuild signed candidate. One setup7 pilot first, THEN frozen
primary24 once stable, plus mutable runner --goal-only separate checks.
Do not reset browsers/docs or redo Fn. Keep P4-5/6 false until proof.
