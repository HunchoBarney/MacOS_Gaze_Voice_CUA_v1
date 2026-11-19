# Release

## Private build (owner and testers)

```sh
make release
```

This produces `build/Jev Voice.app`, `build/Jev-Voice-<version>-<commit>.zip`
and its `.sha256`, keeping the newest three zips. The app is signed with the
self-signed "Jev Voice Local Dev" identity, minted on first use, so macOS
permission grants survive rebuilds. `make install` copies the app to
`~/jarvis-local/` and verifies the signature.

Verify a signature on a copy outside `~/Documents`; the synced folder adds
`com.apple.provenance`, which makes `codesign --verify --deep --strict`
fail spuriously.

`SIGN_IDENTITY=- make release` signs ad-hoc. CI uses it to check packaging;
an ad-hoc app loses permission grants on every rebuild, so don't use it
day to day.

## Public distribution is on hold

`make release PUBLIC=1` (what `.github/workflows/release.yml` runs on a
`v*` tag) exits 1 on purpose.

The hold began because the tracker bundled ONNX gaze and RetinaFace weights
with no redistribution grant. Since #513 the tracker bundles only the
MediaPipe Face Landmarker (Apache-2.0, `EyeTracking/scripts/required-models.sha256`);
the old ONNX weights are fetched only with `fetch-models.sh --legacy` and the
Vite build drops any `.onnx` from the bundle. What still blocks a public
download is signing: the app is self-signed, so Gatekeeper blocks a
downloaded copy.

Lifting the hold needs Developer ID signing and notarization, and a check
that no legacy weights reach the bundle.
When that lands, remove the `PUBLIC=1` branch in the Makefile and this
section.
