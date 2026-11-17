# Speech components

Jev Voice links FluidAudio 0.17.5, from
https://github.com/FluidInference/FluidAudio, under Apache-2.0.
The accompanying LICENSE and ThirdPartyLicenses directory are copied
from the exact Package.resolved checkout during C1 staging.

The current local speech installation uses these separately stored models:

- Parakeet Ultra, converted to Core ML by FluidInference from Moondream's
  post-training of NVIDIA Parakeet TDT 0.6B v3. The Core ML conversion uses
  an int8 encoder and fp16 decoder/joint. The published checkpoint license
  is CC-BY-4.0: https://creativecommons.org/licenses/by/4.0/
  Model source: https://huggingface.co/FluidInference/parakeet-ultra-coreml
- Parakeet Realtime EOU 120M, converted to Core ML by FluidInference from
  NVIDIA's streaming recognizer. Jev uses the 160ms variant for provisional
  text. The upstream weights use the NVIDIA Open Model License:
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/
  Model source: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
  Upstream: https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1

Model sources and license statements were checked against their published
model cards during C1. The component manifest records the actual local
file hashes. This candidate does not bundle those speech weights; portable
model distribution and the full transitive license review remain C3 work.
No model conversion, new weights or model modification was performed.

FluidVoice UI attribution is separate and remains in ThirdParty/FluidVoice.
