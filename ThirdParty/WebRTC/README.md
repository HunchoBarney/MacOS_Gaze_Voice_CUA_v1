# WebRTC

GPT-Live sessions (`Sources/Jarvis/Voice/Live/`) run over WebRTC using
LiveKit's build of Google's libwebrtc:

- Package: [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework)
  `150.7871.08` (released 2026-11-19), built from
  [webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc) `m150_release`.
- Licence: libwebrtc is BSD-3-Clause with Google's patent grant (`LICENSE` in
  the framework, copied into the app as `Resources/ThirdParty/WebRTC/LICENSE`).
  LiveKit's packaging repository is Apache-2.0. Classes carry the `LK` prefix
  (`LKRTCPeerConnectionFactory`).
- Pinned: the release zip's SHA-256 is
  `008dbf8187843ab708afa44b65b8041d8ce8da99e530608cd85aa6ea3551529a`
  (verified on download). The zip is 687 MB for every Apple platform plus
  dSYMs, so `fetch.py` reads only the macOS framework from it with HTTP range
  requests (about 30 MB) and checks the result against a tree hash taken from a
  copy extracted from the verified zip. It writes a macOS-only xcframework to
  `build/vendor/WebRTC`. `make test` and `make release` run it, and
  `Package.swift` links the framework only when it's there.
- `make release` copies the framework to `Contents/Frameworks` and adds the
  `@executable_path/../Frameworks` rpath. The app's signature covers it.

## Why LiveKit's build and not stasel/WebRTC

Live's WebRTC capture and Jarvis's wake word must hear the same microphone. The
L1 spike (KAR-75, 2026-11-20) measured three set-ups on the owner's MacBook Pro:

| Set-up | Our AVAudioEngine tap | WebRTC's capture |
| --- | --- | --- |
| stasel M158, our tap without voice processing | 4 engine configuration changes; even with restarts, 17,000 of 48,000 frames a second and gaps up to 3.35 s | real audio |
| stasel M158, our tap with voice processing | unaffected (238 ms largest gap) | near-silence (level 0.00003) |
| LiveKit 150.7871.08, AVAudioEngine audio module, our tap on its engine | continuous, 100 ms largest gap, before, during and after a call | real audio (level 0.002) |

stasel's macOS slice has no custom audio device (`RTCAudioDevice` ships only
for iOS), so it can't share. LiveKit's `RTCAudioDeviceModule` runs one
AVAudioEngine with Apple's voice processing, starts recording without a call
(`initAndStartRecording`) and lets the app tap the engine's input node from
its `configureInputFromSource` hook. That makes one owner for the microphone:
the wake word, Silero and a local copy of the audio can ride the same engine
Live uses. Closing a call stops that engine, so after a session Jarvis starts
recording again at once.

## Upgrade

Change `VERSION` and `ZIP_SHA256` in `fetch.py`, download the zip once and
check its SHA-256 against LiveKit's `Package.swift`, extract its
`macos-arm64_x86_64` framework, `LICENSE` and `Info.plist`, and print the new
tree hash with `fetch.py <dest> --print-tree-hash`. Pin it as `TREE_SHA256`,
then rerun `make test`.
