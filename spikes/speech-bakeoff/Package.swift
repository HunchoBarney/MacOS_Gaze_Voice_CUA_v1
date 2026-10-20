// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speech-bakeoff",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Same pin as the app package (Package.swift: FluidAudio exact 0.17.5)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")
    ],
    targets: [
        .target(
            name: "BakeoffCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/bakeoff"
        ),
        .executableTarget(name: "bakeoff", dependencies: ["BakeoffCore"], path: "Sources/CLI"),
        .testTarget(
            name: "RecorderTests",
            dependencies: ["BakeoffCore"]
        )
    ]
)
