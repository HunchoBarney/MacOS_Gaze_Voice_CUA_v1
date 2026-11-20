# Silero VAD (Core ML)

Hands-free listening scores microphone audio on the Mac with this model and
uploads audio to the speech service only while someone is speaking
(`Sources/Jarvis/Voice/VoiceActivityGate.swift`).

- Model: Silero VAD v6.2.1 by the Silero Team, MIT (`LICENSE`).
- Core ML conversion: `silero-vad-unified-256ms-v6.2.1.mlmodelc` from
  [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml),
  MIT, at revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96`.
- Input: 64 samples of context plus 4,096 new samples of 16 kHz mono audio
  (256 ms), and the LSTM state. Output: speech probability and the next state.
- `make release` copies the model to `Contents/Resources/SileroVAD/` and
  this licence to `Contents/Resources/ThirdParty/SileroVAD/`.

SHA-256 of the pinned files:

| File | SHA-256 |
| --- | --- |
| `analytics/coremldata.bin` | `8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909` |
| `coremldata.bin` | `7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41` |
| `metadata.json` | `2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6` |
| `model.mil` | `c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270` |
| `weights/weight.bin` | `53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063` |

To upgrade, download the new revision, update the table and the model name
in `VoiceActivityGate.swift`, and rerun `swift test --filter VoiceActivityGateTests`.
