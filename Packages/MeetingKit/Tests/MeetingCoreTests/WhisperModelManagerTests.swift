import XCTest
@testable import MeetingCore

@MainActor
final class WhisperModelManagerTests: XCTestCase {
    func testVerifyReportsMissingForAnUnknownModel() {
        let manager = WhisperModelManager()
        XCTAssertEqual(manager.verify("openai_whisper-not-a-real-model"), .missing)
    }

    func testStateStartsNotInstalledForAnUninstalledModel() throws {
        let manager = WhisperModelManager()
        let uninstalled = WhisperModelStore.catalog
            .first { !WhisperModelStore.isDownloaded($0.id) }
        try XCTSkipIf(uninstalled == nil, "every catalog model happens to be installed")
        XCTAssertEqual(manager.state(of: uninstalled!.id), .notInstalled)
    }

    /// Runs only when the default model is actually on disk — proves the
    /// integrity check accepts a real, working install rather than just
    /// rejecting a fake one.
    func testVerifyAcceptsTheRealInstalledModel() throws {
        let modelID = WhisperModelStore.defaultModelID
        try XCTSkipUnless(
            WhisperModelStore.isDownloaded(modelID),
            "default model not installed on this machine"
        )
        let manager = WhisperModelManager()
        XCTAssertEqual(manager.verify(modelID), .complete)
        XCTAssertTrue(manager.state(of: modelID).isInstalled)
        XCTAssertGreaterThan(WhisperModelStore.installedBytes(of: modelID), 500_000_000)
    }

    /// A model folder with the right shape but a gutted component must be
    /// rejected — this is the interrupted-download case.
    func testVerifyRejectsAnIncompleteInstall() throws {
        let modelID = "openai_whisper-base"
        let folder = WhisperModelStore.localFolder(for: modelID)
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: folder.path),
            "would clobber a real install of \(modelID)"
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let fm = FileManager.default
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try fm.createDirectory(
                at: folder.appendingPathComponent("\(component).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))

        let manager = WhisperModelManager()
        guard case .incomplete(let reason) = manager.verify(modelID) else {
            return XCTFail("expected .incomplete for a model with no compiled weights")
        }
        XCTAssertTrue(reason.contains("compiled weights"), reason)
    }
}
