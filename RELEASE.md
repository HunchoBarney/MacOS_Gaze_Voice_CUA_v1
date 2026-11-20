# Release

## Private build (owner and testers)

```sh
make release
```

This produces `build/Jarvis.app`, `build/Jarvis-<version>-<commit>.zip`
and its `.sha256`, keeping the newest three zips. The app is signed with the
self-signed "Jarvis Local Dev" identity, minted on first use, so macOS
permission grants survive rebuilds. `make install` copies the app to
`~/jarvis-local/` and verifies the signature.

Verify a signature on a copy outside `~/Documents`; the synced folder adds
`com.apple.provenance`, which makes `codesign --verify --deep --strict`
fail spuriously.

`SIGN_IDENTITY=- make release` signs ad-hoc. CI uses it to check packaging;
an ad-hoc app loses permission grants on every rebuild, so don't use it
day to day.

## Turning on the Live voice lane

gpt-live-1.1 ships behind `voice.live`, off by default. It becomes the
default only after the owner physical checks in [TESTING.md](TESTING.md)
pass on a signed build; the same change deletes the gpt-realtime-2.1 lane
(L11). The paid tiers ($30/month with usage limits, $100/month) need
hosted credentials (KAR-38) and metering (L10) first, and the public
distribution hold below still applies.

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
that no legacy weights reach the bundle. When that lands, remove the
`PUBLIC=1` branch in the Makefile and this section, and add a Homebrew cask
for this repository's releases if you want one. The old cask pointed at the
upstream jev-voice-control project and was removed.
