import XCTest
@testable import MeetingCore

final class MeetingURLClassifierTests: XCTestCase {
    func testZoomHosts() {
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://zoom.us/j/123")), .zoom)
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://us02web.zoom.us/j/123?pwd=abc")), .zoom)
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://zoom.com/j/123")), .zoom)
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://www.zoom.com/meeting/123")), .zoom)
    }

    func testGoogleMeet() {
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://meet.google.com/abc-defg-hij")), .googleMeet)
    }

    func testTeams() {
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://teams.microsoft.com/l/meetup-join/19%3ameeting")), .teams)
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://teams.live.com/meet/123")), .teams)
    }

    func testWebex() {
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://company.webex.com/meet/jane")), .webex)
        XCTAssertEqual(MeetingURLClassifier.classify(url("https://webex.com/meet/jane")), .webex)
    }

    func testDriveDocsCalendarAndRandomHTTPSAreNotMeetingLinks() {
        XCTAssertNil(MeetingURLClassifier.classify(url("https://drive.google.com/file/d/abc123/view")))
        XCTAssertNil(MeetingURLClassifier.classify(url("https://docs.google.com/document/d/abc123/edit")))
        XCTAssertNil(MeetingURLClassifier.classify(url("https://calendar.google.com/calendar/event?eid=xyz")))
        XCTAssertNil(MeetingURLClassifier.classify(url("https://example.com/standup")))
        XCTAssertNil(MeetingURLClassifier.classify(url("https://notion.so/meeting-notes")))
        XCTAssertNil(MeetingURLClassifier.classify(url("https://google.com")))
    }

    func testDetectIgnoresDriveAndReturnsNil() {
        XCTAssertNil(MeetingURLClassifier.detect(in: [
            "Budget review",
            "https://drive.google.com/file/d/abc123/view"
        ]))
    }

    func testDetectPicksZoomWhenDriveIsAlsoPresent() {
        let hit = MeetingURLClassifier.detect(in: [
            "See deck: https://drive.google.com/file/d/abc/view",
            "Join: https://us06web.zoom.us/j/999"
        ])
        XCTAssertEqual(hit?.kind, .zoom)
        XCTAssertEqual(hit?.url.host, "us06web.zoom.us")
    }

    func testDetectFindsMeetInNotes() {
        let hit = MeetingURLClassifier.detect(in: [
            "Sync",
            nil,
            "Dial in at https://meet.google.com/aaa-bbbb-ccc please"
        ])
        XCTAssertEqual(hit?.kind, .googleMeet)
    }

    func testEmptyPieces() {
        XCTAssertNil(MeetingURLClassifier.detect(in: [nil, nil, ""]))
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }
}
