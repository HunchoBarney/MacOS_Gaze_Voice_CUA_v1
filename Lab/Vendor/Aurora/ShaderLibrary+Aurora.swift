import SwiftUI

// JARVIS PATCH: the lab compiles AuroraGlow.metal into this target's
// default.metallib (scripts/lab-metallib.sh), so the library loads from
// Bundle.module instead of upstream's precompiled Metallibs folder.
extension ShaderLibrary {
  static let aurora: ShaderLibrary = .bundle(.module)
}
