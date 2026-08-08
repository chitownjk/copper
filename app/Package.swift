// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // WhisperKit (MIT) ships inside argmax-oss-swift alongside SpeakerKit (E7.1).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        // Headless, unit-testable core: audio processing and transcription engines.
        // This is the seed of the `CompanionCore` local package in TD-6.
        .target(
            name: "MeetingCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/MeetingCore"
        ),
        // Summarization backends. Seed of the `CompanionProviders` package in TD-6.
        .target(
            name: "MeetingProviders",
            dependencies: ["MeetingCore"],
            path: "Sources/MeetingProviders"
        ),
        .executableTarget(
            name: "MeetingNotes",
            dependencies: [
                "MeetingCore",
                "MeetingProviders",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MeetingNotes",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MeetingCoreTests",
            dependencies: ["MeetingCore"],
            path: "Tests/MeetingCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MeetingProvidersTests",
            dependencies: ["MeetingProviders"],
            path: "Tests/MeetingProvidersTests"
        )
    ]
)
