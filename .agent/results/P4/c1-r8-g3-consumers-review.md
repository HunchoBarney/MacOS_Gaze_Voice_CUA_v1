# G3 discovered-consumer G2

Independent read-only reviewer8a7d5f03, resumed only for G2. Terminal PASS.
CON-1 through CON-4 MET; no defect found. This is not source/artifact G4.

Evidence: proposal c1-r8-g3-consumers.md17-24 retains cursor/session labels
through an explicit key and no-input viewport refusal for gaze consumers.
DriveSessionCursorTests37-43/66-72 and GazeLaneTests231-235 /
GazeRefusalStateTests358-365 exposed the obsolete targetless expectations.

TrackerHost45-50/681-718 has two actor entry points that can both suspend
before claiming the pause. Exact counts failed in full G3 and isolated
c1-r8-tracker-recheck. Reviewed active/pending convergence, latest-state/error
handling and a private identity invalidated on retirement. Overlapping edges
return; they must not block behind in-flight network IO. A newer edge survives
failure; there is no unconditional retry loop.

Reviewed five added files only, no EyeTracking/protocol/provider/model/public
API change. The gated retired-response/replacement test was added before
production changes. All tracker tests, including that new test, passed in
c1-r8-all-fixed.log. The four old scroll consumers passed too.
