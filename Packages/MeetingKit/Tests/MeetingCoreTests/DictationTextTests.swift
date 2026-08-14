import XCTest
@testable import MeetingCore

final class DictationTextTests: XCTestCase {
    func testJoinTrimsAndCollapses() {
        let segments = [
            TranscribedSegment(startMs: 0, endMs: 500, text: "  Hello,"),
            TranscribedSegment(startMs: 500, endMs: 900, text: "world.  "),
            TranscribedSegment(startMs: 900, endMs: 910, text: "   ")
        ]
        XCTAssertEqual(DictationText.join(segments), "Hello, world.")
    }

    func testJoinEmpty() {
        XCTAssertEqual(DictationText.join([]), "")
        XCTAssertEqual(
            DictationText.join([TranscribedSegment(startMs: 0, endMs: 1, text: "   ")]),
            ""
        )
    }
}
