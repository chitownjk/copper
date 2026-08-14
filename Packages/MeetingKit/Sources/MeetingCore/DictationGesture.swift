import Foundation

/// Pure hold / double-tap machine for the talk chord.
///
/// Hardware lives in the app (`DictationHotkeyMonitor`). This type is only
/// the timing rules so they can be unit-tested without posting events.
public struct DictationGestureMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case pressing
        case pendingSecondTap
        case holdListening
        case handsFreeListening
    }

    public enum Action: Equatable, Sendable {
        case none
        case startHold
        case startHandsFree
        case stop
        case cancel
    }

    /// Press longer than this and it is hold-to-talk, not a tap.
    public static let holdThreshold: TimeInterval = 0.18
    /// Second tap must land within this window after the first release.
    public static let doubleTapWindow: TimeInterval = 0.35

    public private(set) var phase: Phase = .idle
    private var pressStartedAt: TimeInterval?
    private var firstTapUpAt: TimeInterval?
    /// True after a hands-free start (or stop) while the triggering tap is
    /// still down, so that tap's up does not fire a second action.
    private var ignoreNextUp = false

    public init() {}

    public var isListening: Bool {
        switch phase {
        case .holdListening, .handsFreeListening: return true
        default: return false
        }
    }

    public mutating func chordDown(at t: TimeInterval) -> Action {
        switch phase {
        case .idle:
            phase = .pressing
            pressStartedAt = t
            ignoreNextUp = false
            return .none
        case .pendingSecondTap:
            phase = .handsFreeListening
            pressStartedAt = t
            ignoreNextUp = true
            firstTapUpAt = nil
            return .startHandsFree
        case .handsFreeListening:
            phase = .idle
            pressStartedAt = nil
            ignoreNextUp = true
            return .stop
        case .pressing, .holdListening:
            return .none
        }
    }

    public mutating func chordUp(at t: TimeInterval) -> Action {
        if ignoreNextUp {
            ignoreNextUp = false
            pressStartedAt = nil
            return .none
        }
        switch phase {
        case .pressing:
            phase = .pendingSecondTap
            firstTapUpAt = t
            pressStartedAt = nil
            return .none
        case .holdListening:
            phase = .idle
            pressStartedAt = nil
            return .stop
        case .idle, .pendingSecondTap, .handsFreeListening:
            return .none
        }
    }

    public mutating func tick(at t: TimeInterval) -> Action {
        switch phase {
        case .pressing:
            if let start = pressStartedAt, t - start >= Self.holdThreshold {
                phase = .holdListening
                return .startHold
            }
            return .none
        case .pendingSecondTap:
            if let up = firstTapUpAt, t - up >= Self.doubleTapWindow {
                phase = .idle
                firstTapUpAt = nil
            }
            return .none
        default:
            return .none
        }
    }

    public mutating func escape() -> Action {
        switch phase {
        case .idle:
            return .none
        case .pressing, .pendingSecondTap:
            reset()
            return .none
        case .holdListening, .handsFreeListening:
            reset()
            return .cancel
        }
    }

    public mutating func requestStop() -> Action {
        guard isListening else { return .none }
        reset()
        return .stop
    }

    public mutating func reset() {
        phase = .idle
        pressStartedAt = nil
        firstTapUpAt = nil
        ignoreNextUp = false
    }
}
