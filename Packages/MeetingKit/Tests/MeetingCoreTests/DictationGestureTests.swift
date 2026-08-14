import XCTest
@testable import MeetingCore

final class DictationGestureTests: XCTestCase {
    func testHoldPastThresholdStartsAndReleaseStops() {
        var m = DictationGestureMachine()
        XCTAssertEqual(m.chordDown(at: 0), .none)
        XCTAssertEqual(m.tick(at: 0.10), .none)
        XCTAssertEqual(m.tick(at: 0.18), .startHold)
        XCTAssertEqual(m.phase, .holdListening)
        XCTAssertEqual(m.chordUp(at: 1.20), .stop)
        XCTAssertEqual(m.phase, .idle)
    }

    func testSingleTapDoesNotStart() {
        var m = DictationGestureMachine()
        XCTAssertEqual(m.chordDown(at: 0), .none)
        XCTAssertEqual(m.chordUp(at: 0.08), .none)
        XCTAssertEqual(m.phase, .pendingSecondTap)
        XCTAssertEqual(m.tick(at: 0.08 + DictationGestureMachine.doubleTapWindow), .none)
        XCTAssertEqual(m.phase, .idle)
    }

    func testDoubleTapStartsHandsFreeAndSameShortcutStops() {
        var m = DictationGestureMachine()
        XCTAssertEqual(m.chordDown(at: 0), .none)
        XCTAssertEqual(m.chordUp(at: 0.07), .none)
        XCTAssertEqual(m.chordDown(at: 0.20), .startHandsFree)
        XCTAssertEqual(m.phase, .handsFreeListening)
        // The second tap's up must not stop listening.
        XCTAssertEqual(m.chordUp(at: 0.27), .none)
        XCTAssertEqual(m.phase, .handsFreeListening)
        XCTAssertEqual(m.chordDown(at: 2.00), .stop)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.chordUp(at: 2.05), .none)
    }

    func testEscapeCancelsListeningNotIdle() {
        var m = DictationGestureMachine()
        XCTAssertEqual(m.escape(), .none)
        _ = m.chordDown(at: 0)
        _ = m.tick(at: 0.20)
        XCTAssertEqual(m.escape(), .cancel)
        XCTAssertEqual(m.phase, .idle)
    }

    func testEscapeDuringPressIsIgnored() {
        var m = DictationGestureMachine()
        _ = m.chordDown(at: 0)
        XCTAssertEqual(m.escape(), .none)
        XCTAssertEqual(m.phase, .idle)
    }

    func testRequestStopFromHUD() {
        var m = DictationGestureMachine()
        _ = m.chordDown(at: 0)
        _ = m.chordUp(at: 0.05)
        _ = m.chordDown(at: 0.15)
        XCTAssertEqual(m.requestStop(), .stop)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.requestStop(), .none)
    }

    func testHoldThresholdBoundary() {
        var m = DictationGestureMachine()
        _ = m.chordDown(at: 0)
        XCTAssertEqual(m.tick(at: DictationGestureMachine.holdThreshold - 0.001), .none)
        XCTAssertEqual(m.tick(at: DictationGestureMachine.holdThreshold), .startHold)
    }
}
