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

    func testDisplayTitleFallsBackWhenEmpty() {
        XCTAssertEqual(CalendarRecordPolicy.displayTitle(nil), "Untitled event")
        XCTAssertEqual(CalendarRecordPolicy.displayTitle("   "), "Untitled event")
        XCTAssertEqual(CalendarRecordPolicy.displayTitle("Driving school review"), "Driving school review")
    }

    func testShouldDisplayHidesAllDayAndMissingDates() {
        let start = Date(timeIntervalSince1970: 1_787_068_800) // 2026-08-18 16:00 UTC
        let end = start.addingTimeInterval(3600)
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "Holiday", start: start, end: end, isAllDay: true))
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "X", start: nil, end: end, isAllDay: false))
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "X", start: start, end: nil, isAllDay: false))
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "X", start: start, end: start, isAllDay: false))
        XCTAssertTrue(CalendarRecordPolicy.shouldDisplay(title: "Driving school review", start: start, end: end, isAllDay: false))
    }

    func testShouldDisplayHidesUntitledMidnightLeftover() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_787_011_200) // 2026-08-18 00:00 UTC
        let end = start.addingTimeInterval(24 * 3600)
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "", start: start, end: end, isAllDay: false, calendar: cal))
        XCTAssertFalse(CalendarRecordPolicy.shouldDisplay(title: "  ", start: start, end: end, isAllDay: false, calendar: cal))
    }

    func testShouldDisplayKeepsUntitledTimedEvent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_787_011_200 + 11 * 3600 + 30 * 60) // 11:30 UTC
        let end = start.addingTimeInterval(30 * 60)
        XCTAssertTrue(CalendarRecordPolicy.shouldDisplay(title: "", start: start, end: end, isAllDay: false, calendar: cal))
    }
}
