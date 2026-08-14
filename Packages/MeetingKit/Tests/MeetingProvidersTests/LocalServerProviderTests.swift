import XCTest
@testable import MeetingProviders

final class LocalServerProviderTests: XCTestCase {
    private let urlKey = "localServerBaseURL"
    private let modelKey = "localServerModel"
    private var savedURL: Any?
    private var savedModel: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedURL = defaults.object(forKey: urlKey)
        savedModel = defaults.object(forKey: modelKey)
        LocalServerProvider.clearProbe()
        defaults.removeObject(forKey: urlKey)
        defaults.removeObject(forKey: modelKey)
    }

    override func tearDown() {
        LocalServerProvider.clearProbe()
        let defaults = UserDefaults.standard
        if let savedURL { defaults.set(savedURL, forKey: urlKey) } else { defaults.removeObject(forKey: urlKey) }
        if let savedModel { defaults.set(savedModel, forKey: modelKey) } else { defaults.removeObject(forKey: modelKey) }
        super.tearDown()
    }

    func testDefaultURLIsNotReadyUntilProbed() async {
        let provider = LocalServerProvider()
        // Default URL is non-empty (localhost:11434) — that used to report Ready.
        XCTAssertFalse(LocalServerProvider.baseURLString.isEmpty)
        switch await provider.requirement() {
        case .unavailable(let reason):
            XCTAssertTrue(reason.contains("Not verified"), reason)
        default:
            XCTFail("an untested local server must not report ready")
        }
    }

    func testSuccessfulProbeMarksReadyForThatConfigOnly() async {
        let provider = LocalServerProvider()
        LocalServerProvider.baseURLString = "http://localhost:11434/v1"
        LocalServerProvider.modelName = "llama3.2"
        LocalServerProvider.recordProbe(success: true, message: nil)
        switch await provider.requirement() {
        case .none:
            break
        default:
            XCTFail("a successful probe for this URL+model should be ready")
        }

        LocalServerProvider.modelName = "other-model"
        switch await provider.requirement() {
        case .unavailable(let reason):
            XCTAssertTrue(reason.contains("Not verified"), reason)
        default:
            XCTFail("changing the model must drop ready until re-tested")
        }
    }

    func testFailedProbeIsNotReady() async {
        let provider = LocalServerProvider()
        LocalServerProvider.baseURLString = "http://localhost:11434/v1"
        LocalServerProvider.modelName = "llama3.2"
        LocalServerProvider.recordProbe(success: false, message: "Couldn’t reach the summarizer: Could not connect to the server.")
        switch await provider.requirement() {
        case .unavailable(let reason):
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason == "Needs a server URL")
        case .none:
            XCTFail("a failed probe must not report ready")
        default:
            XCTFail("failed probe should be unavailable, not a missing-URL state")
        }
    }
}
