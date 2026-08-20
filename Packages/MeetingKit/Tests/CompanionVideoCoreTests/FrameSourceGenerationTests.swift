import XCTest
@testable import CompanionVideoCore

final class FrameSourceGenerationTests: XCTestCase {
    func testSwitchingToCameraOffRejectsLiveFramesAndRoutesOffFrames() {
        let gate = FrameSourceGeneration()

        let live = gate.activate(.live)
        XCTAssertTrue(gate.routes(.live, token: live))
        XCTAssertFalse(gate.routes(.cameraOff, token: live))

        let cameraOff = gate.activate(.cameraOff)
        XCTAssertFalse(gate.routes(.live, token: live))
        XCTAssertFalse(gate.routes(.live, token: cameraOff))
        XCTAssertTrue(gate.routes(.cameraOff, token: cameraOff))
    }

    func testStoppingSourceInvalidatesCurrentToken() {
        let gate = FrameSourceGeneration()
        let token = gate.activate(.live)

        gate.invalidate()

        XCTAssertFalse(gate.routes(.live, token: token))
    }

    func testRapidSwitchingRoutesOnlyFinalSelectedMode() async {
        let gate = FrameSourceGeneration()
        let firstLive = gate.activate(.live)
        let firstOff = gate.activate(.cameraOff)
        let secondLive = gate.activate(.live)
        let finalOff = gate.activate(.cameraOff)

        await withTaskGroup(of: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    [
                        gate.routes(.live, token: firstLive),
                        gate.routes(.cameraOff, token: firstOff),
                        gate.routes(.live, token: secondLive),
                        gate.routes(.cameraOff, token: finalOff)
                    ]
                }
            }
            for await routed in group {
                XCTAssertEqual(routed, [false, false, false, true])
            }
        }
    }
}
