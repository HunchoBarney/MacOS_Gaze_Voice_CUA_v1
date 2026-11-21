# Aurora

- Upstream: tornikegomareli/Aurora (https://github.com/tornikegomareli/Aurora)
- Commit: a3f9296 (2026-10-05)
- Path: Sources/Aurora
- Licence: MIT, as stated in the README's License section. Upstream has no LICENSE file; LICENSE here is the standard MIT text with the author's name, so the grant travels with the code.
- Used by: the Jarvis UI Lab only (Package.swift builds it when JARVIS_LAB=1). The shipping app does not link it.

## Patches (each marked `JARVIS PATCH` in the source)

- AuroraGlow.swift: an injectable `auroraTimes` environment value (elapsed, burst, intro, outro) used instead of the wall clock when set.
- ShaderLibrary+Aurora.swift: loads the metallib from `.bundle(.module)`; the lab compiles AuroraGlow.metal with scripts/lab-metallib.sh instead of shipping upstream's prebuilt metallibs.
- #Preview blocks removed.

Note: upstream says the look is reverse-engineered from Apple's IntelligentLightFrag shader (the algorithm only, no Apple code). Worth the owner's eye before it ships.
