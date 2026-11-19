// swift-tools-version:5.9
import PackageDescription

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
            dependencies: ["JarvisCore"],
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
    ]
)
