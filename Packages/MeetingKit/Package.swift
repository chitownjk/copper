// swift-tools-version:5.9
import PackageDescription

// MeetingKit: the app's headless core, consumed by the Xcode app target as a
// local package (TD-6). Two products so the future camera-extension target can
// link only what it needs.
let package = Package(
    name: "MeetingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingProviders", targets: ["MeetingProviders"])
    ],
    dependencies: [
        // WhisperKit (MIT) ships inside argmax-oss-swift alongside SpeakerKit (E7.1).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        // Headless, unit-testable core: audio processing and transcription engines.
        .target(
            name: "MeetingCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        // Summarization backends.
        .target(
            name: "MeetingProviders",
            dependencies: ["MeetingCore"]
        ),
        .testTarget(
            name: "MeetingCoreTests",
            dependencies: ["MeetingCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MeetingProvidersTests",
            dependencies: ["MeetingProviders"]
        )
    ]
)
