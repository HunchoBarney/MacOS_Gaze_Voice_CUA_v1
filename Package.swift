// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "JarvisCore",
            path: "Sources/JarvisCore"
        ),
        .executableTarget(
            name: "Jarvis",
            dependencies: ["JarvisCore", .product(name: "GRDB", package: "GRDB.swift")],
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
