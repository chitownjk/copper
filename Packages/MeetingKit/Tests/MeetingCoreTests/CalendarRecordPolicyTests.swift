import XCTest
@testable import MeetingCore

final class CalendarRecordPolicyTests: XCTestCase {
    func testThisTimeWinsOverSeries() {
        let tags = [
            CalendarEventTag(eventId: "occ-1", seriesId: "series-A", decision: .skip, grain: .thisTime),
            CalendarEventTag(eventId: "other", seriesId: "series-A", decision: .record, grain: .thisSeries)
        ]
        XCTAssertEqual(
            CalendarRecordPolicy.taggedDecision(eventId: "occ-1", seriesId: "series-A", tags: tags),
            .skip
        )
        XCTAssertEqual(
            CalendarRecordPolicy.taggedDecision(eventId: "occ-2", seriesId: "series-A", tags: tags),
            .record
        )
    }

    func testAbsenceMeansDefault() {
        XCTAssertNil(CalendarRecordPolicy.taggedDecision(eventId: "x", seriesId: "y", tags: []))
    }

    func testNonRecurringHasNoSeriesFallback() {
        let tags = [
            CalendarEventTag(eventId: "solo", seriesId: nil, decision: .record, grain: .thisTime)
        ]
        XCTAssertEqual(
            CalendarRecordPolicy.taggedDecision(eventId: "solo", seriesId: nil, tags: tags),
            .record
        )
        XCTAssertNil(CalendarRecordPolicy.taggedDecision(eventId: "other", seriesId: nil, tags: tags))
    }

    func testCaptureModeFollowsMeetingLink() {
        XCTAssertTrue(CalendarRecordPolicy.includesSystemAudio(hasMeetingLink: true))
        XCTAssertFalse(CalendarRecordPolicy.includesSystemAudio(hasMeetingLink: false))
    }

    func testSeriesIdStripsOccurrenceSuffix() {
        XCTAssertEqual(
            CalendarRecordPolicy.seriesId(
                fromEventIdentifier: "BASE-ID/20260814T150000Z",
                hasRecurrence: true
            ),
            "BASE-ID"
        )
        XCTAssertNil(CalendarRecordPolicy.seriesId(fromEventIdentifier: "BASE-ID/20260814T150000Z", hasRecurrence: false))
        XCTAssertEqual(
            CalendarRecordPolicy.seriesId(fromEventIdentifier: "BASE-ID", hasRecurrence: true),
            "BASE-ID"
        )
    }
}
