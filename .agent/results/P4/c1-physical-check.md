# One brief physical C1 check

Artifact: `~/jarvis-local/c1-review-c292e120/Jev Voice.app`, executable
c292e12024dc04bfc6a924b0d7f6ceb41a2c1c23ed38ffcba8f404750f9264eb.
Daily app is untouched. This is a human smoke check, not full P3
qualification, a benchmark population or release acceptance.

Use only a new owned TextEdit document and Calculator. Keep other
documents unchanged. Do not run two Jev Fn monitors at once.

The exact candidate is already launched and its normal controller has
initialized. Startup initially waited on macOS Keychain; no approval was
automated. The preparation watcher opened the owned `C1 voice check.txt`
document, named in [current preparation](c1-physical-current.json).
It generated no key, click, voice command or model answer. Wait for the
pill to be ready before starting the four checks.

1. With TextEdit focused, hold **Fn+Ctrl**, say “The total is forty-two,
   not twenty-four. Keep the final word: cedar,” and release normally.
   Check the numbers, negation and final word; text should appear once
   in the intended field.
2. Hold **Fn**, say “open Calculator,” then release. Check Calculator
   actually becomes active and the pill settles.
3. In an owned TextEdit document with enough lines to scroll, look at it,
   hold **Fn**, say “scroll down,” and release. Check that document's
   viewport moves, with other windows unchanged.
4. Start another hold, say a few words, then press **Escape before
   releasing Fn**. Check it cancels and produces no late text or action.

Report what failed or felt slow, and whether the final word survived.
One pass is enough; stop on wrong-target, duplicate or delayed
post-cancellation action. Do not repeat the old 27-hold qualification.

When collecting diagnostics, use the existing `JARVIS_VOICE_EVIDENCE_DIR`
with a fresh owner-only directory and a normal LaunchServices launch.
`open` supports `--env NAME=value` on this Mac. Do not enable audit modes,
use the historical five-request physical profile or repurpose its grant.
No new budget is imposed on Jev.

Afterward quit the candidate through its menu. The original daily app
can be reopened at `~/jarvis-local/Jev Voice.app`; no replacement or
rollback copy is necessary because its bytes were never changed.

Human input/results: **pending**. No physical proof has been fabricated.
