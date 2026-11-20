# Vosk

Standby listens for "Hey <name>" with [Vosk](https://github.com/alphacep/vosk-api)
(Alpha Cephei, Apache-2.0, `LICENSE`) in grammar mode, in two passes
(`Sources/Jarvis/Voice/WakeWordDetector.swift`):

1. A listener that knows only the wake phrase runs on all microphone audio.
2. When it hears the phrase, the 2.5 s before and 1 s after are decoded
   again by a checker that also knows "Hey <first name>" for each of the
   1,306 names in macOS's `/usr/share/dict/propernames`. The wake phrase
   counts when every word of it scores at least 0.6 confidence.

- Library: `libvosk.dylib` (12 MB, universal2, links only Accelerate,
  libc++ and libSystem) from the official `vosk-0.3.44` macOS wheel,
  SHA-256 of the wheel
  `029d0b3d6a5cff874c575b8a5814a4cccfb37608cff52e846c02a8c67a882801`.
  It is loaded with `dlopen`, so the Swift build doesn't link it.
- Model: `vosk-model-small-en-us-0.15` (Apache-2.0, 68 MB unpacked),
  SHA-256 of the zip
  `30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498`.
- `fetch.sh` downloads both, checks the hashes and unpacks them into
  `build/vendor/Vosk`. `make test` and `make release` run it; `make release`
  copies them to `Contents/Resources/Vosk/`.

What it can't do: a name has to be a word in the model's vocabulary (41 of
45 assistant and personal names tried; not "Cortana", "Xander", "Karanvir"
or "Aarav"). A short name that sounds like another first name is missed
more often, because the checker hears the other name: on synthetic voices
"Hey Jake" was accepted 60 % of the time (the voices drop the final "k" and
the checker hears "Hey Jay"), against 96 % for "Hey Jarvis".

To upgrade, change the URLs and hashes in `fetch.sh` and rerun
`make test`.
