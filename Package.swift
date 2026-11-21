// swift-tools-version:5.9
import Foundation
import PackageDescription

// GPT-Live's WebRTC transport links LiveKit's build of libwebrtc once
// ThirdParty/WebRTC/fetch.py has put its macOS slice in build/vendor/WebRTC
// (`make test` and `make release` run it). Without it the app builds
// without that transport, so a focused `swift test` never needs the download.
// SwiftPM caches this manifest's result regardless of the file, so the make
// targets that fetch it build with --manifest-cache none.
let webRTC = "build/vendor/WebRTC/LiveKitWebRTC.xcframework"
let hasWebRTC = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + webRTC)

// The Jarvis UI Lab (Lab/README.md): the redesign's component variants, the
// lab app and their clip renderer. They exist only when JARVIS_LAB=1 (make lab,
// make redesign), so make test, CI and the shipping app never build or link the
// vendored UI libraries until the owner picks a direction.
let lab = Context.environment["JARVIS_LAB"] == "1"
let labTargets: [Target] = [
    .target(name: "Orb", path: "Lab/Vendor/Orb", exclude: ["LICENSE", "VENDOR.md"]),
    .target(name: "BorderBeamKit", path: "Lab/Vendor/BorderBeamKit", exclude: ["LICENSE", "VENDOR.md"],
            resources: [.copy("Resources/beam-spec.json"), .process("BeamShaders.metal")]),
    .target(name: "ThinkingOrbsKit", path: "Lab/Vendor/ThinkingOrbsKit", exclude: ["LICENSE", "VENDOR.md"]),
    .target(name: "VoiceGlowKit", path: "Lab/Vendor/VoiceGlowKit", exclude: ["LICENSE", "VENDOR.md"],
            resources: [.process("VoiceGlowShaders.metal")]),
    .target(name: "VoiceCore", path: "Lab/Vendor/VoiceCore", exclude: ["LICENSE", "VENDOR.md"],
            resources: [.process("Render/Refract.metal")]),
    .target(name: "VoiceRingKit", dependencies: ["VoiceCore"], path: "Lab/Vendor/VoiceRingKit",
            exclude: ["LICENSE", "VENDOR.md"]),
    .target(name: "Aurora", path: "Lab/Vendor/Aurora", exclude: ["LICENSE", "VENDOR.md"],
            resources: [.process("AuroraGlow.metal")]),
    .target(name: "Inferno", path: "Lab/Vendor/Inferno", exclude: ["LICENSE", "VENDOR.md"],
            resources: [.process("Shaders")]),
    .target(name: "JarvisRedesign",
            dependencies: ["Orb", "BorderBeamKit", "ThinkingOrbsKit", "VoiceGlowKit", "VoiceRingKit", "Inferno", "Aurora"],
            path: "Lab/Redesign"),
    .executableTarget(name: "JarvisLab", dependencies: ["JarvisRedesign"], path: "Lab/App"),
    .executableTarget(name: "JarvisRedesignRender", dependencies: ["JarvisRedesign"], path: "Lab/Render"),
]

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "JarvisCore",
            path: "Sources/JarvisCore"
        ),
        .executableTarget(
            name: "Jarvis",
            dependencies: ["JarvisCore"] + (hasWebRTC ? ["LiveKitWebRTC"] : []),
            path: "Sources/Jarvis"
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisTests"
        ),
        .testTarget(
            name: "JarvisAppTests",
            dependencies: ["Jarvis", "JarvisCore"],
            path: "Tests/JarvisAppTests"
        ),
        .testTarget(
            name: "JarvisGalleryTests",
            dependencies: ["Jarvis", "JarvisCore"],
            path: "Tests/JarvisGalleryTests"
        ),
    ] + (hasWebRTC ? [.binaryTarget(name: "LiveKitWebRTC", path: webRTC)] : []) + (lab ? labTargets : [])
)
