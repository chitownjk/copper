import XCTest
@testable import MeetingCore

final class RetentionPolicyTests: XCTestCase {
    func testDays30KeepsRecentAudio() {
        let ended = Date().addingTimeInterval(-7 * 24 * 3600)
        XCTAssertFalse(RetentionSettings.shouldDeleteAudio(
            endedAt: ended, isPinned: false, isProcessed: true, policy: .days30
        ))
    }

    func testDays30DeletesAudioOlderThan30Days() {
        let ended = Date().addingTimeInterval(-31 * 24 * 3600)
        XCTAssertTrue(RetentionSettings.shouldDeleteAudio(
            endedAt: ended, isPinned: false, isProcessed: true, policy: .days30
        ))
    }

    func testAfterTranscriptionDeletesOnceProcessed() {
        XCTAssertTrue(RetentionSettings.shouldDeleteAudio(
            endedAt: Date(), isPinned: false, isProcessed: true, policy: .afterTranscription
        ))
        XCTAssertFalse(RetentionSettings.shouldDeleteAudio(
            endedAt: Date(), isPinned: false, isProcessed: false, policy: .afterTranscription
        ))
    }

    func testForeverNeverDeletes() {
        let ended = Date().addingTimeInterval(-365 * 24 * 3600)
        XCTAssertFalse(RetentionSettings.shouldDeleteAudio(
            endedAt: ended, isPinned: false, isProcessed: true, policy: .forever
        ))
    }

    func testPinAlwaysWins() {
        XCTAssertFalse(RetentionSettings.shouldDeleteAudio(
            endedAt: Date().addingTimeInterval(-60),
            isPinned: true,
            isProcessed: true,
            policy: .afterTranscription
        ))
    }

    func testUnsetPolicyFallsBackTo30Days() {
        XCTAssertEqual(RetentionPolicy.days30.maximumAge, 30 * 24 * 60 * 60)
        XCTAssertEqual(RetentionPolicy.afterTranscription.maximumAge, 0)
        XCTAssertNil(RetentionPolicy.forever.maximumAge)
        XCTAssertEqual(RetentionPolicy.allCases.first, .days30)
    }
}
