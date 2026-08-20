import Foundation

public enum CameraFrameSource: Sendable {
    case live
    case cameraOff
}

/// Thread-safe generation token for asynchronous camera frame producers.
///
/// Capture and timer queues may still deliver callbacks after their source is
/// stopped. Only the currently activated generation is allowed to push frames
/// into the virtual-camera sink.
public final class FrameSourceGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var selectedSource: CameraFrameSource?

    public init() {}

    /// Invalidates every previously issued token and returns the new active one.
    public func activate(_ source: CameraFrameSource) -> UInt64 {
        lock.withLock {
            generation &+= 1
            selectedSource = source
            return generation
        }
    }

    /// Invalidates the current source without activating a replacement.
    public func invalidate() {
        lock.withLock {
            generation &+= 1
            selectedSource = nil
        }
    }

    /// Returns true only for frames produced by the final selected source.
    public func routes(_ source: CameraFrameSource, token: UInt64) -> Bool {
        lock.withLock {
            generation == token && selectedSource == source
        }
    }
}
