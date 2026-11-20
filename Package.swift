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
    ] + (hasWebRTC ? [.binaryTarget(name: "LiveKitWebRTC", path: webRTC)] : [])
)
