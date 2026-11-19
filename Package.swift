// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JevVoice",
    platforms: [.macOS("26.0")],
    dependencies: [
        // FluidAudio: Parakeet Ultra (batch ASR), parakeet-realtime-eou-120m
        // (160ms streaming EOU partials) and PocketTTS all live inside the
        // single Apache-2.0 `FluidAudio` product — no `FluidAudioTTS` product
        // exists at this tag and nothing in the package links ESpeakNG/GPL.
        // 0.17.5 released 2026-10-01 (>=7 days stable when pinned).
        // `exact` — the ASR/EOU and legacy test call sites were written against
        // this tag's API surface; `from:` would silently float to 0.17.7.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .target(
            name: "JevVoiceCore",
            path: "Sources/JevVoiceCore"
        ),
        .executableTarget(
            name: "JevVoice",
            dependencies: [
                "JevVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/JevVoice"
        ),
        .testTarget(
            name: "JevVoiceTests",
            dependencies: ["JevVoiceCore"],
            path: "Tests/JevVoiceTests"
        ),
        .testTarget(
            name: "JevVoiceAppTests",
            dependencies: [
                "JevVoice",
                "JevVoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Tests/JevVoiceAppTests"
        ),
    ]
)
