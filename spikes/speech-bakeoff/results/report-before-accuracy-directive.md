# P2d Speech Bake-Off

Run `20261020T034959348218Z`; raw evidence `results/results.json`.

## Verdict

**PICK speechanalyzer-fast**

Directional priority: final latency, corpus WER, then first partial; 50 ms / 2 percentage points are engineering tolerances, not significance tests. Apple service/asset attribution gaps qualify the resource comparison.

This is one speaker's 15 prompted commands, repeated measurements, not a general ASR accuracy study.
No production engine has been replaced. G4 independent review and G7 commit remain separate gates.

## Recorded Commands

| engine | ok / measured | corpus WER | first partial p50 ms | after onset p50 ms | final p50 ms | final p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| speechanalyzer | 45 / 45 | 5.15% | 2631.1 | 2456.8 | 209.5 | 1025.6 |
| parakeet | 45 / 45 | 4.12% | 1831.3 | 1788.1 | 150.0 | 389.1 |
| speechanalyzer-fast | 45 / 45 | 5.15% | 2119.2 | 2112.8 | 84.4 | 213.1 |

First-partial target: 300 ms from capture start. Final target: 200 ms after scheduled input end.
Final latency includes model backlog; it is not measured from when the engine finishes consuming audio.
Each engine sees the identical energy-delimited PCM view. Source WAVs remain unchanged.
The 200 ms trailing padding is included; this is not a physical Fn-release measurement.
Energy onset is a proxy, not a manually annotated speech boundary; breaths/clicks can affect it.

## Paired Per-Command Medians

| command | engine | final ms | first partial ms | WER | partial count |
|---|---|---:|---:|---:|---:|
| p01 | speechanalyzer | 127.9 | 2476.9 | 0.0% | 5.0 |
| p01 | parakeet | 327.1 | 989.8 | 0.0% | 4.0 |
| p01 | speechanalyzer-fast | 82.8 | 2120.6 | 0.0% | 5.0 |
| p02 | speechanalyzer | 209.5 | 2635.3 | 9.1% | 13.0 |
| p02 | parakeet | 159.2 | 1466.5 | 0.0% | 11.0 |
| p02 | speechanalyzer-fast | 201.9 | 2121.8 | 9.1% | 13.0 |
| p03 | speechanalyzer | 240.6 | 2813.9 | 0.0% | 9.0 |
| p03 | parakeet | 138.4 | 1972.2 | 0.0% | 10.0 |
| p03 | speechanalyzer-fast | 95.5 | 2112.9 | 0.0% | 9.0 |
| p04 | speechanalyzer | 405.5 | 2445.0 | 21.4% | 16.0 |
| p04 | parakeet | 220.3 | 1643.0 | 21.4% | 19.0 |
| p04 | speechanalyzer-fast | 148.8 | 2112.8 | 21.4% | 16.0 |
| p05 | speechanalyzer | 253.4 | 2245.0 | 16.7% | 9.0 |
| p05 | parakeet | 139.5 | 1647.1 | 0.0% | 8.0 |
| p05 | speechanalyzer-fast | 94.5 | 2108.6 | 16.7% | 9.0 |
| p06 | speechanalyzer | 184.6 | 2270.1 | 0.0% | 10.0 |
| p06 | parakeet | 146.4 | 1788.1 | 0.0% | 8.0 |
| p06 | speechanalyzer-fast | 113.7 | 2108.4 | 0.0% | 10.0 |
| p07 | speechanalyzer | 653.1 | 3040.1 | 0.0% | 4.0 |
| p07 | parakeet | 126.3 | 1802.2 | 0.0% | 4.0 |
| p07 | speechanalyzer-fast | 77.6 | 2120.1 | 0.0% | 4.0 |
| p08 | speechanalyzer | 233.3 | 2456.8 | 0.0% | 8.0 |
| p08 | parakeet | 129.0 | 1322.5 | 0.0% | 6.0 |
| p08 | speechanalyzer-fast | 96.7 | 2121.2 | 0.0% | 8.0 |
| p09 | speechanalyzer | 678.6 | 3458.3 | 0.0% | 2.0 |
| p09 | parakeet | 150.0 | 2445.9 | 0.0% | 2.0 |
| p09 | speechanalyzer-fast | 45.8 | 3074.3 | 0.0% | 2.0 |
| p10 | speechanalyzer | 180.3 | 3112.4 | 0.0% | 5.0 |
| p10 | parakeet | 139.8 | 2425.8 | 0.0% | 5.0 |
| p10 | speechanalyzer-fast | 64.7 | 3071.6 | 0.0% | 5.0 |
| p11 | speechanalyzer | 51.2 | 3123.2 | 0.0% | 4.0 |
| p11 | parakeet | 154.4 | 2127.5 | 0.0% | 2.0 |
| p11 | speechanalyzer-fast | 36.3 | 3079.8 | 0.0% | 4.0 |
| p12 | speechanalyzer | 185.3 | 2364.8 | 0.0% | 6.0 |
| p12 | parakeet | 134.8 | 1628.1 | 0.0% | 8.0 |
| p12 | speechanalyzer-fast | 76.6 | 2106.1 | 0.0% | 6.0 |
| p13 | speechanalyzer | 216.1 | 2121.0 | 0.0% | 10.0 |
| p13 | parakeet | 181.6 | 1831.3 | 0.0% | 10.0 |
| p13 | speechanalyzer-fast | 102.0 | 2109.8 | 0.0% | 10.0 |
| p14 | speechanalyzer | 203.4 | 2146.0 | 0.0% | 9.0 |
| p14 | parakeet | 140.2 | 1947.6 | 0.0% | 9.0 |
| p14 | speechanalyzer-fast | 80.2 | 2109.6 | 0.0% | 9.0 |
| p15 | speechanalyzer | 194.6 | 3099.0 | 0.0% | 10.0 |
| p15 | parakeet | 162.1 | 2773.1 | 11.1% | 9.0 |
| p15 | speechanalyzer-fast | 81.9 | 3071.2 | 0.0% | 10.0 |

## Accuracy Audit

Every command with word edits in iteration 0 is shown; repetitions remain in raw JSON.
Numeral/hyphen formatting is not the same as a wrong entity. In particular, Apple's GitHub -> GateHub error is meaningful and must not be hidden behind the aggregate WER.

| engine | clip | reference | observed final | edits |
|---|---|---|---|---:|
| speechanalyzer | p02 | reply to Sarah saying I'll be there in ten minutes | Reply to Sarah saying I'll be there in 10 minutes. | 1 |
| speechanalyzer | p04 | send a slack message to the team channel saying standup is moved to eleven | Send a slack message to the team channel saying stand-up is moved to 11. | 3 |
| speechanalyzer | p05 | open github and check my notifications | Open GateHub and check my notifications. | 1 |
| parakeet | p04 | send a slack message to the team channel saying standup is moved to eleven | Send a Slack message to the team channel saying stand-up is moved to 11. | 3 |
| parakeet | p15 | note: follow up with the design review on monday | Uh note, follow up with the design review on Monday. | 1 |
| speechanalyzer-fast | p02 | reply to Sarah saying I'll be there in ten minutes | Reply to Sarah saying I'll be there in 10 minutes. | 1 |
| speechanalyzer-fast | p04 | send a slack message to the team channel saying standup is moved to eleven | Send a slack message to the team channel saying stand-up is moved to 11. | 3 |
| speechanalyzer-fast | p05 | open github and check my notifications | Open GateHub and check my notifications. | 1 |

A directional speed pick is not a ship-quality accuracy claim. P3 must guard entity/intent correctness; the SDK exposes AnalysisContext.contextualStrings[.general] for a prospective vocabulary experiment, but no context-biased run was measured here.

## Resources And Startup

| engine | fresh-process load ms | warm reuse ms | first inference ms | client load peak MB | client inference peak MB | model bytes |
|---|---:|---:|---:|---:|---:|---:|
| parakeet | 56045.9 | 0.0 | 3641.7 | 447.6 | 172.6 | 856362338.0 |
| speechanalyzer | 5167.7 | 0.0 | 3564.2 | 18.4 | 17.6 | unavailable |
| speechanalyzer-fast | 3071.0 | 0.0 | 3426.3 | 18.3 | 20.9 | unavailable |
- parakeet: pre-load baseline 14.8 MB; load/inference sampled peak deltas from that baseline 432.8/157.8 MB (not an inference-only allocation delta).
- speechanalyzer: pre-load baseline 14.8 MB; load/inference sampled peak deltas from that baseline 3.5/2.8 MB (not an inference-only allocation delta).
- speechanalyzer-fast: pre-load baseline 14.8 MB; load/inference sampled peak deltas from that baseline 3.5/6.1 MB (not an inference-only allocation delta).

Caches were not cleared. 'Warm reuse' is reusing an already-loaded driver, not a new model load.
Client RSS is sampled at 50 ms and excludes Apple XPC/ANE allocations; do not compare it as total engine RAM.
Apple shared service observations (not causally attributable to this process):
- speechanalyzer: shared localspeechrecognition RSS baseline 6.3 MB, observed peak 506.4 MB.
- parakeet: shared localspeechrecognition RSS baseline 0.0 MB, observed peak 0.0 MB.
- speechanalyzer-fast: shared localspeechrecognition RSS baseline 0.0 MB, observed peak 600.2 MB.
- Apple shared ASR asset directory bytes: 162235114; exclusive en_US bytes: unavailable.
- RAM 2x / disk 1.5x veto cannot be certified for Apple with the attribution gaps; packaging/resource gate stays open.

## Streaming Diagnosis

- [verified] speechanalyzer: 40/45 rows emit a partial before scheduled audio end; feed lag p50 10.7 ms; per-turn prepare p50 83.0 ms.
- speechanalyzer target hits: first partial <=300 ms 0/45, final <=200 ms 19/45; partial-update gap p50/p95 0.2/968.3 ms. Missing partials are misses, not zero latency.
- [verified] parakeet: 45/45 rows emit a partial before scheduled audio end; feed lag p50 15.7 ms; per-turn prepare p50 0.0 ms.
- parakeet target hits: first partial <=300 ms 0/45, final <=200 ms 37/45; partial-update gap p50/p95 261.7/521.2 ms. Missing partials are misses, not zero latency.
- [verified] speechanalyzer-fast: 45/45 rows emit a partial before scheduled audio end; feed lag p50 10.6 ms; per-turn prepare p50 30.6 ms.
- speechanalyzer-fast target hits: first partial <=300 ms 0/45, final <=200 ms 41/45; partial-update gap p50/p95 0.1/964.6 ms. Missing partials are misses, not zero latency.
- [verified] This is chunked-file replay, not the app's Fn/microphone front door. Mid-stream output does not establish production routing is correct or that first partials meet 300 ms.
- [code-inspected] Concrete display-wiring gap: `Sources/JevVoice/main.swift:599-613` connects local partials only to LocalCommandRouter when spotting is enabled, and clears callbacks in STT-only mode. `LocalCommandRouter.swift:146-157` uses partials for command speculation, not transcript display.
- [code-inspected] The visible partial event instead comes from remote transcript deltas (`RealtimeVoiceLane.swift:716-720`), which `VoiceController.swift:988-993` copies into the overlay. P3 must wire turn-tagged LOCAL partials to that display path without dispatching actions twice.
- [unverified] Fn-up/start races, local model-readiness drops and backlog remain additional integration hypotheses. The shipped app's physical Fn/mic path still needs a live check after the P3 wiring fix.

## Coverage, Authorization And Limits

- Coverage problems: none.
- Scored rows: 162; first-inference warm-ups excluded: 3.
- Libraries have tail-phrase checks, not full ground-truth WER.
- speechanalyzer library tail matches: 9/9.
- parakeet library tail matches: 9/9.
- speechanalyzer-fast library tail matches: 9/9.
- [verified] Existing local models used; benchmark code has no model download or network-transcription fallback.
- [unverified] XPC-service network activity and clean-Mac onboarding attribution were not independently tested.
- SpeechAnalyzer requires macOS 26+, matching the current root Package.swift deployment floor.
- WER is literal lowercase/punctuation-normalized word edits; numeral spellings and contractions can count as errors despite equivalent intent. No normalization was tuned to these results.
- Microphone authorization was read, not requested; no recording is performed by this benchmark.
- speechanalyzer authorization: mic=3; speech=0; not requested by this benchmark.
- parakeet authorization: mic=3; speech=0; not requested by this benchmark.
- speechanalyzer-fast authorization: mic=3; speech=0; not requested by this benchmark.

## Recompute

```bash
python3 spikes/speech-bakeoff/report.py --check
```
