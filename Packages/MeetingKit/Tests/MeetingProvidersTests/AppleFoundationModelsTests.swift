import XCTest
@testable import MeetingProviders

/// Exercises the on-device provider against the real Apple Intelligence model.
///
/// Skips itself on a Mac that can't run it (pre-macOS 26, ineligible hardware,
/// Apple Intelligence switched off), so it is safe to leave in the default
/// suite — on a supported machine it is a genuine end-to-end check, and
/// elsewhere it costs nothing.
final class AppleFoundationModelsProviderTests: XCTestCase {
    private let provider = AppleFoundationModelsProvider()

    /// The capability probe must always produce a specific, actionable reason
    /// rather than a bare "unavailable" — this is the string Settings shows.
    func testRequirementIsEitherReadyOrExplainsWhyNot() async {
        switch await provider.requirement() {
        case .none:
            break
        case .unavailable(let reason):
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(reason.hasSuffix("."), "reason should read as a sentence: \(reason)")
        case .apiKey, .serverURL:
            XCTFail("an on-device provider must never ask for credentials")
        }
    }

    func testPrivacyLabelIsOnDevice() {
        XCTAssertEqual(provider.privacyLabel, .onDevice)
        XCTAssertEqual(provider.privacyLabel.description, "Stays on this Mac")
    }

    func testSummarizesARealTranscriptOnDevice() async throws {
        try await XCTSkipUnlessAvailable(provider)

        let request = SummaryRequest(
            transcript: """
            [00:00:02 TRANSCRIPT] Okay, so the launch date. Priya, can we hold the 14th?
            [00:00:09 TRANSCRIPT] Not if the installer isn't notarized. That's the blocker.
            [00:00:15 TRANSCRIPT] Then Marco owns notarization and reports back Thursday.
            [00:00:21 TRANSCRIPT] Agreed. We slip to the 21st if Thursday isn't green.
            """,
            notes: "[00:00:16 NOTE] Marco owns notarization — Thursday",
            template: .general
        )

        let result = try await provider.summarize(request)

        XCTAssertEqual(result.providerID, .appleFoundationModels)
        XCTAssertEqual(result.templateID, "general")
        XCTAssertFalse(result.content.isEmpty)
        // The model should have picked up the one name the notes flagged.
        XCTAssertTrue(
            result.content.lowercased().contains("marco"),
            "expected the flagged owner in the summary:\n\(result.content)"
        )
        print("Apple Intelligence summary:\n\(result.content)")
    }

    /// A transcript past the on-device context budget must map-reduce rather
    /// than fail — the path most likely to break on a small local model.
    func testLongTranscriptMapReducesOnDevice() async throws {
        try await XCTSkipUnlessAvailable(provider)

        let line = "[00:00:00 TRANSCRIPT] We reviewed the quarterly numbers and agreed to revisit pricing."
        let long = Array(repeating: line, count: 400).joined(separator: "\n")
        XCTAssertGreaterThan(long.count, AppleFoundationModelsProvider.contextCharacterBudget)

        let result = try await provider.summarize(
            SummaryRequest(transcript: long, template: .general)
        )
        XCTAssertFalse(result.content.isEmpty)
    }

    private func XCTSkipUnlessAvailable(
        _ provider: AppleFoundationModelsProvider,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        if case .unavailable(let reason) = await provider.requirement() {
            throw XCTSkip("Apple Intelligence unavailable here: \(reason)", file: file, line: line)
        }
    }
}
