import Foundation
import CompanionVideoCore

/// End-to-end app-process probe for the HUD's live → Camera Off route.
///
/// This uses the real controller, capture source, off source, and extension
/// sink. It fails if any accepted live frame reaches the sink after the final
/// Camera Off selection.
@MainActor
struct CameraModeSwitchProbe {
    struct Result {
        let liveFramesBeforeSwitch: Int
        let offFramesAfterSwitch: Int
        let staleLiveFramesAfterSwitch: Int
    }

    enum ProbeError: LocalizedError {
        case liveDidNotStart(String)
        case noLiveFrames
        case finalModeWasNotOff
        case noOffFrames
        case staleLiveFrames(Int)

        var errorDescription: String? {
            switch self {
            case .liveDidNotStart(let state):
                return "Live source did not start: \(state)"
            case .noLiveFrames:
                return "No live frames reached the sink before the switch."
            case .finalModeWasNotOff:
                return "The controller did not settle on Camera Off."
            case .noOffFrames:
                return "No Camera Off frames reached the sink after the switch."
            case .staleLiveFrames(let count):
                return "\(count) stale live frame(s) reached the sink after Camera Off."
            }
        }
    }

    func run() async throws -> Result {
        let defaults = UserDefaults.standard
        let key = CompanionCameraController.outputModeDefaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let collector = SourceCollector()
        let camera = CompanionCameraController()
        camera.frameSourceConsumer = { source in collector.record(source) }

        camera.setOutputMode(.live)
        await camera.goLive()
        guard camera.isLive else {
            throw ProbeError.liveDidNotStart(String(describing: camera.state))
        }
        try await Task.sleep(for: .seconds(1))
        let liveBefore = collector.snapshot().live
        guard liveBefore > 0 else {
            camera.stopLive()
            throw ProbeError.noLiveFrames
        }

        collector.reset()
        camera.applyOutputMode(.off)
        await camera.waitForSourceTransition()
        try await Task.sleep(for: .seconds(1))
        let after = collector.snapshot()
        let settledOff = camera.isLive && camera.outputMode == .off
        camera.stopLive()

        guard settledOff else { throw ProbeError.finalModeWasNotOff }
        guard after.off > 0 else { throw ProbeError.noOffFrames }
        guard after.live == 0 else { throw ProbeError.staleLiveFrames(after.live) }
        return Result(
            liveFramesBeforeSwitch: liveBefore,
            offFramesAfterSwitch: after.off,
            staleLiveFramesAfterSwitch: after.live
        )
    }
}

private final class SourceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var off = 0

    func record(_ source: CameraFrameSource) {
        lock.withLock {
            switch source {
            case .live: live += 1
            case .cameraOff: off += 1
            }
        }
    }

    func reset() {
        lock.withLock {
            live = 0
            off = 0
        }
    }

    func snapshot() -> (live: Int, off: Int) {
        lock.withLock { (live, off) }
    }
}
