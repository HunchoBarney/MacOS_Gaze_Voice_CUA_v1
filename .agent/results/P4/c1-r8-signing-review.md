# Canonical VAD signing consumer G2

Independent read-only reviewer8a7d5f03 (jarvis-judge), completed before edit.
VERDICT: PASS. VAD-1, VAD-2, VAD-3 MET. No defect found.

- Same pin and destination: sign-app.sh13-17, proposal9-15, public bundler91-97,
  P12 aliases74-87; be41b15f...c1c8062 unchanged. Validator fails missing,
  corrupt and unlisted resources before model load.
- Signing/authority unchanged: sign-app.sh22-117 retain identity, nested signing,
  driver stamping, codesigning and strict verification; proposal changes only
  VAD preparation.
- Public canonical bundler removes sign-app's P12 evidence-helper dependency
  and matches Makefile49.

Applied exactly after full Swift G3 run completed. R8 source/artifact G4 and
real-app/physical proof remain pending. This is no release acceptance.
