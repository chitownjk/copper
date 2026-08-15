import XCTest
@testable import MeetingProviders

final class SummaryTemplateStoreTests: XCTestCase {
    private let customKey = "summaryTemplatesCustom"
    private let selectedKey = "summaryTemplateSelected"
    private let overridesKey = "summaryTemplateOverrides"
    private var savedCustom: Any?
    private var savedSelected: Any?
    private var savedOverrides: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedCustom = defaults.object(forKey: customKey)
        savedSelected = defaults.object(forKey: selectedKey)
        savedOverrides = defaults.object(forKey: overridesKey)
        defaults.removeObject(forKey: customKey)
        defaults.removeObject(forKey: selectedKey)
        defaults.removeObject(forKey: overridesKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedCustom { defaults.set(savedCustom, forKey: customKey) } else { defaults.removeObject(forKey: customKey) }
        if let savedSelected { defaults.set(savedSelected, forKey: selectedKey) } else { defaults.removeObject(forKey: selectedKey) }
        if let savedOverrides { defaults.set(savedOverrides, forKey: overridesKey) } else { defaults.removeObject(forKey: overridesKey) }
        super.tearDown()
    }

    func testBuiltInsRemainTheShippedStartingText() {
        XCTAssertEqual(SummaryTemplate.builtIns.map(\.id), ["general", "one-on-one", "standup", "sales-call", "interview"])
        XCTAssertEqual(Array(SummaryTemplateStore.all.map(\.id).prefix(5)), ["general", "one-on-one", "standup", "sales-call", "interview"])
        XCTAssertTrue(SummaryTemplateStore.all.prefix(5).allSatisfy(\.isBuiltIn))
    }

    func testOverrideChangesNameAndPromptInAllTemplateAndSelected() {
        SummaryTemplateStore.selected = .general
        SummaryTemplateStore.saveBuiltInOverride(
            id: "general",
            name: "Jay general",
            systemPrompt: "Write it like Jay talks."
        )

        XCTAssertTrue(SummaryTemplateStore.isBuiltInOverridden(id: "general"))
        XCTAssertEqual(SummaryTemplateStore.template(id: "general")?.name, "Jay general")
        XCTAssertEqual(SummaryTemplateStore.template(id: "general")?.systemPrompt, "Write it like Jay talks.")
        XCTAssertEqual(SummaryTemplateStore.template(id: "general")?.isBuiltIn, true)
        XCTAssertEqual(SummaryTemplateStore.all.first { $0.id == "general" }?.name, "Jay general")
        XCTAssertEqual(SummaryTemplateStore.selected.name, "Jay general")
        XCTAssertEqual(SummaryTemplateStore.selected.systemPrompt, "Write it like Jay talks.")
        // Factory copy stays in the binary for Reset.
        XCTAssertEqual(SummaryTemplate.general.name, "General")
        XCTAssertNotEqual(SummaryTemplate.general.systemPrompt, "Write it like Jay talks.")
    }

    func testResetRestoresOriginalBuiltIn() {
        SummaryTemplateStore.saveBuiltInOverride(
            id: "standup",
            name: "Daily",
            systemPrompt: "Three bullets, no fluff."
        )
        XCTAssertEqual(SummaryTemplateStore.template(id: "standup")?.name, "Daily")

        SummaryTemplateStore.resetBuiltInOverride(id: "standup")

        XCTAssertFalse(SummaryTemplateStore.isBuiltInOverridden(id: "standup"))
        XCTAssertEqual(SummaryTemplateStore.template(id: "standup"), SummaryTemplate.standup)
        XCTAssertEqual(SummaryTemplateStore.all.first { $0.id == "standup" }, SummaryTemplate.standup)
    }

    func testSavingOriginalTextClearsOverride() {
        SummaryTemplateStore.saveBuiltInOverride(
            id: "interview",
            name: "Hiring loop",
            systemPrompt: "Stay skeptical."
        )
        SummaryTemplateStore.saveBuiltInOverride(
            id: "interview",
            name: SummaryTemplate.interview.name,
            systemPrompt: SummaryTemplate.interview.systemPrompt
        )
        XCTAssertFalse(SummaryTemplateStore.isBuiltInOverridden(id: "interview"))
        XCTAssertEqual(SummaryTemplateStore.template(id: "interview"), SummaryTemplate.interview)
    }

    func testCustomTemplatesAreUnchangedByBuiltInOverrides() {
        let custom = SummaryTemplate(
            id: "custom-board",
            name: "Board minutes",
            systemPrompt: "Formal minutes."
        )
        SummaryTemplateStore.custom = [custom]
        SummaryTemplateStore.saveBuiltInOverride(
            id: "general",
            name: "Rewritten",
            systemPrompt: "Different."
        )

        XCTAssertEqual(SummaryTemplateStore.custom, [custom])
        XCTAssertEqual(SummaryTemplateStore.template(id: "custom-board"), custom)
        XCTAssertTrue(SummaryTemplateStore.all.contains(custom))
        XCTAssertEqual(SummaryTemplateStore.all.first { $0.id == "general" }?.name, "Rewritten")
    }

    func testOverrideOnUnknownIdIsIgnored() {
        SummaryTemplateStore.saveBuiltInOverride(
            id: "not-a-template",
            name: "Nope",
            systemPrompt: "Should not persist."
        )
        XCTAssertFalse(SummaryTemplateStore.isBuiltInOverridden(id: "not-a-template"))
        XCTAssertNil(SummaryTemplateStore.template(id: "not-a-template"))
    }

    func testQuickActionsStayOutOfDefaultStylesAndAreNotOverridden() {
        SummaryTemplateStore.saveBuiltInOverride(
            id: "shorter",
            name: "Tiny",
            systemPrompt: "Even shorter."
        )
        XCTAssertFalse(SummaryTemplateStore.all.contains { $0.id == "shorter" })
        XCTAssertEqual(SummaryTemplateStore.template(id: "shorter"), SummaryTemplate.shorter)
    }
}
