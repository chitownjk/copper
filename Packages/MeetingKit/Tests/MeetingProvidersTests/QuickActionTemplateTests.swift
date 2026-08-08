import XCTest
@testable import MeetingProviders

/// E2.6 quick-action templates. Resolution is offline; the generation test
/// runs against the real on-device model and skips where unavailable.
final class QuickActionTemplateTests: XCTestCase {
    func testQuickActionTemplatesResolveById() {
        XCTAssertEqual(SummaryTemplateStore.template(id: "shorter")?.name, "Shorter")
        XCTAssertEqual(SummaryTemplateStore.template(id: "follow-up-email")?.name, "Follow-up email")
    }

    func testQuickActionsAreNotOfferedAsDefaultStyles() {
        // They're verbs on an existing meeting; offering "Shorter" as a
        // default template in Settings would be nonsense.
        XCTAssertFalse(SummaryTemplate.builtIns.contains { $0.id == "shorter" })
        XCTAssertFalse(SummaryTemplateStore.all.contains { $0.id == "follow-up-email" })
    }

    func testFollowUpEmailGeneratesAPasteableDraftOnDevice() async throws {
        let provider = AppleFoundationModelsProvider()
        if case .unavailable(let reason) = await provider.requirement() {
            throw XCTSkip("Apple Intelligence unavailable here: \(reason)")
        }

        let result = try await provider.summarize(SummaryRequest(
            transcript: """
            [00:00:02 TRANSCRIPT] Okay, so the launch date. Priya, can we hold the 14th?
            [00:00:09 TRANSCRIPT] Not if the installer isn't notarized. That's the blocker.
            [00:00:15 TRANSCRIPT] Then Marco owns notarization and reports back Thursday.
            """,
            notes: nil,
            template: .followUpEmail
        ))

        XCTAssertEqual(result.templateID, "follow-up-email")
        XCTAssertTrue(
            result.content.hasPrefix("Subject:"),
            "email draft must lead with a subject line, got:\n\(result.content)"
        )
        XCTAssertTrue(result.content.lowercased().contains("marco"), "owner should survive into the email")
        print("Follow-up email draft:\n\(result.content)")
    }
}
