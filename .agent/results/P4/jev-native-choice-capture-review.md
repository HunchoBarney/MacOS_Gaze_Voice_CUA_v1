# Read-Only Routing Diagnostic Review

Scope: the new `JevNativeChoiceDiagnosticTests.swift`, the diagnostic Python
orchestrator, and its two verification-lane entries. No product-source changes.

The independent reviewer `adbe8c30` returns SOURCEPASS after two SOURCEFAIL
reviews. Output paths are normalized and restricted to owned directories inside
the native workspace. Symlink components and existing outputs are rejected.
Directories are verified as private; JSON output uses exclusive no-follow
creation with mode 0600. Model latency is recorded.

The original synthetic TextEdit document is borrowed, not created by this
diagnostic. It and the restored sibling must remain open. Only newly owned
driver, client and temporary runtime resources are released.

The compile/parser check is green. The opt-in Swift case is skipped without
explicit input and credentials. That is compile evidence, not native model
evidence or a P4 qualification pass.

The live diagnostic uses a recorded SDK snapshot with fresh native CF scope
checks and the ordinary read-only preview/inference seams. It is source-level
diagnostic evidence, not installed-app or actuation proof. The production
synthetic-trace privacy gate remains unchanged.
