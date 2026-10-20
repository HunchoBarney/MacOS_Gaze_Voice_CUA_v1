# Speech Bake-Off (P2d)

Measurements are complete for run `20261020T034959348218Z`.
Performance-only candidate: SpeechAnalyzer fast-results (84.4 ms final p50).
Production selection is ON HOLD following the user's accuracy directive:
known action-changing errors block promotion, regardless of speed.
First-partial target misses, accuracy errors and resource attribution
gaps are explicit in `results/REPORT.md`. Independent G4 review passed
(including the verifier hardening recheck); no production ASR changed.

## Run The Comparison

After recording the corpus, build and test the optimized benchmark:

```bash
python3 scripts/with-desktop-lock.py scripts/verification-lane.sh speech-release
python3 scripts/with-desktop-lock.py python3 spikes/speech-bakeoff/bench.py
python3 spikes/speech-bakeoff/report.py
python3 spikes/speech-bakeoff/report.py --check
python3 spikes/speech-bakeoff/verify.py
python3 spikes/speech-bakeoff/verify_scope.py
python3 spikes/speech-bakeoff/verify_hygiene.py
```

Each variant runs in a fresh process with a 20-minute limit; interrupted
children are terminated and reaped. Warm-up results are labeled `iter=-1`
and excluded from scoring. A complete run is 162 scored rows: 18 clips,
three repetitions, three variants (Parakeet EOU+Ultra, SpeechAnalyzer
progressive, SpeechAnalyzer fast-results). Only the 15 confirmed command
clips have full WER ground truth; the three longer library clips have
tail-phrase checks. Both engines consume the same non-destructive
energy-delimited view; source audio hashes are verified afterward.

Final latency is relative to the scheduled audio end, including any
processing backlog. Mid-stream partials prove streaming capability, not
that the app's physical Fn path works. The report distinguishes client
RSS from Apple's shared XPC service memory and unknown model attribution.
Legacy debug smoke measurements are archived and not used for the pick.

## Record Your Corpus

From the repository root, test one phrase first:

```bash
./spikes/speech-bakeoff/.build/debug/bakeoff record --only p01
```

Press Enter when ready. Speak after `REC` appears. Capture stops on its
own (6 seconds for short prompts, longer for longer prompts). Then:

- Enter keeps the clip, confirming that you read the displayed words correctly.
- `p` plays the saved audio so you can check it.
- `r` retries without replacing the previous accepted recording.
- `q` quits; previously kept clips remain saved.

Once that works, run the remaining phrases:

```bash
./spikes/speech-bakeoff/.build/debug/bakeoff record
```

The recorder skips completed phrases. `--only p01` explicitly retakes
one. Saved WAV duration is checked before a clip can be accepted. Quiet
clips require a retry. The meter indicates audio levels, not speech
recognition; your confirmation supplies the reference-text check.

Every attempt has a unique filename. Old recordings are never deleted
or overwritten. Native captures and normalized 16 kHz WAVs stay in
gitignored `corpus/recordings/`. No audio is uploaded.

## Verification

Dependencies are already resolved locally. The tests do not download models.
Real fixture audio must be available as `corpus/library/lib03.wav`
(`bakeoff setup-corpus` copies it from the existing FluidAudio checkout).

```bash
python3 scripts/with-desktop-lock.py scripts/verification-lane.sh speech
```

Opt in to microphone tests (three 2-second captures and a 6-second
PTY-driven test of the actual CLI):

```bash
JARVIS_RECORDER_LIVE=1 python3 scripts/with-desktop-lock.py scripts/verification-lane.sh speech
```

The PTY check deliberately types extra Enters during recording and
asserts they do not truncate or auto-accept it. Quitting must leave the
original corpus and manifest byte-for-byte unchanged. Diagnostic audio
also remains local and ignored.

## Recorder Failure And Guard

The former tap signaled `AVAudioConverterInputStatus.endOfStream` after
every microphone buffer, permanently finishing a reused converter.
With real speech the negative control reduces 6 seconds to 0.085 seconds,
matching the reported 0.1-second files. This was not proved to be a
buffered Enter race.

The replacement uses `AVAudioRecorder` for native file capture and does
sample-rate conversion only after the recording is closed. Tests assert
on actual WAV frames, not merely a successful build or timer.
