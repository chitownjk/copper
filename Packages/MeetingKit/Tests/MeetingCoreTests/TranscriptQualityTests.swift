import XCTest
@testable import MeetingCore

final class TranscriptQualityTests: XCTestCase {
    func testThankYouAtZeroIsAHallucination() {
        XCTAssertTrue(TranscriptQuality.isHallucination("thank you"))
        XCTAssertTrue(TranscriptQuality.isHallucination("Thank you."))
        XCTAssertTrue(TranscriptQuality.isHallucination("  Thanks for watching!  "))
        XCTAssertTrue(TranscriptQuality.isHallucination("subtitle"))
        XCTAssertTrue(TranscriptQuality.isHallucination(""))
    }

    func testRealSpeechIsKept() {
        XCTAssertFalse(TranscriptQuality.isHallucination("let's start with the budget"))
        XCTAssertFalse(TranscriptQuality.isHallucination("thank you everyone, next slide"))
    }

    func testFilterDropsCaptionJunk() {
        let segments = [
            TranscribedSegment(startMs: 0, endMs: 800, text: "Thank you."),
            TranscribedSegment(startMs: 900, endMs: 2400, text: "Let's start with the budget."),
        ]
        let kept = TranscriptQuality.filter(segments)
        XCTAssertEqual(kept.map(\.text), ["Let's start with the budget."])
    }

    func testShortTakeOfOnlyThankYouIsUnusable() {
        let segments = [TranscribedSegment(startMs: 0, endMs: 400, text: "thank you")]
        XCTAssertFalse(TranscriptQuality.isUsable(segments: segments, recordingDurationSeconds: 4))
        XCTAssertFalse(TranscriptQuality.isUsable(segments: [], recordingDurationSeconds: 4))
    }

    func testLongerMeetingWithRealWordsIsUsable() {
        let segments = [
            TranscribedSegment(startMs: 0, endMs: 2000, text: "Good morning everyone"),
            TranscribedSegment(startMs: 2000, endMs: 5000, text: "the launch is Friday"),
        ]
        XCTAssertTrue(TranscriptQuality.isUsable(segments: segments, recordingDurationSeconds: 45 * 60))
    }

    func testShortTakeWithARealSentenceIsUsable() {
        let segments = [
            TranscribedSegment(startMs: 0, endMs: 3000, text: "Remind me to email Priya about the invoice."),
        ]
        XCTAssertTrue(TranscriptQuality.isUsable(segments: segments, recordingDurationSeconds: 5))
    }
}
