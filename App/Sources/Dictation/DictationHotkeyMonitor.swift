import AppKit
import Carbon
import CoreGraphics
import MeetingCore

/// Talk chord: Control-Option (no Command/Shift), or Fn alone on Apple
/// keyboards. Hold starts push-to-talk; double-tap starts hands-free.
///
/// Implemented as a session event tap so Esc can be swallowed while
/// listening. Creating the tap requires Accessibility.
@MainActor
final class DictationHotkeyMonitor {
    var onAction: ((DictationGestureMachine.Action) -> Void)?

    private var machine = DictationGestureMachine()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var timer: Timer?
    private var chordWasActive = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        stop()
        HotkeyBox.shared.owner = self
        if installTap() {
            return
        }
        // Tap creation fails without Accessibility. Global monitors still
        // see flags once trusted, but cannot swallow Esc.
        installMonitors()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            }
        }
        tap = nil
        tapSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        HotkeyBox.shared.owner = nil
        HotkeyBox.shared.tap = nil
    }

    func resetMachine() {
        machine.reset()
        HotkeyBox.shared.swallowEscape = false
        timer?.invalidate()
        timer = nil
    }

    func handleHUDStop() {
        emit(machine.requestStop())
    }

    var isListening: Bool { machine.isListening }

    // MARK: - Event tap

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: dictationTapCallback,
            userInfo: nil
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
        HotkeyBox.shared.tap = tap
        return true
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        if type == .flagsChanged {
            handleFlags(event.flags)
            return false
        }
        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == Int64(kVK_Escape), machine.isListening {
                emit(machine.escape())
                return true
            }
        }
        return false
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            handleFlags(event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            return
        }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), machine.isListening {
            emit(machine.escape())
        }
    }

    private func handleFlags(_ flags: CGEventFlags) {
        let active = DictationChord.isActive(flags)
        if active, !chordWasActive {
            chordWasActive = true
            emit(machine.chordDown(at: now()))
            scheduleTick()
        } else if !active, chordWasActive {
            chordWasActive = false
            emit(machine.chordUp(at: now()))
            scheduleTick()
        }
        HotkeyBox.shared.swallowEscape = machine.isListening
    }

    private func scheduleTick() {
        timer?.invalidate()
        switch machine.phase {
        case .pressing:
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        case .pendingSecondTap:
            timer = Timer.scheduledTimer(
                withTimeInterval: DictationGestureMachine.doubleTapWindow,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        default:
            timer = nil
        }
    }

    private func tick() {
        emit(machine.tick(at: now()))
        if machine.phase != .pressing, machine.phase != .pendingSecondTap {
            timer?.invalidate()
            timer = nil
        }
        HotkeyBox.shared.swallowEscape = machine.isListening
    }

    private func emit(_ action: DictationGestureMachine.Action) {
        guard action != .none else { return }
        HotkeyBox.shared.swallowEscape = machine.isListening
        onAction?(action)
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

enum DictationChord {
    /// Control-Option without Command/Shift is the reliable chord.
    /// Fn alone is accepted on Apple keyboards; Fn plus any other
    /// modifier is treated as a function-key combo and ignored.
    static func isActive(_ flags: CGEventFlags) -> Bool {
        let mods = flags.intersection([
            .maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn
        ])
        let controlOption = mods.contains(.maskControl)
            && mods.contains(.maskAlternate)
            && !mods.contains(.maskCommand)
            && !mods.contains(.maskShift)
        if controlOption { return true }
        return mods == .maskSecondaryFn
    }
}

/// C tap callback is not actor-isolated; this box hops to the monitor.
private final class HotkeyBox: @unchecked Sendable {
    static let shared = HotkeyBox()
    weak var owner: DictationHotkeyMonitor?
    var tap: CFMachPort?
    var swallowEscape = false
}

private func dictationTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotkeyBox.shared.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == Int64(kVK_Escape), HotkeyBox.shared.swallowEscape {
            DispatchQueue.main.async {
                _ = HotkeyBox.shared.owner?.handleCGEvent(type: type, event: event)
            }
            return nil
        }
    }
    if type == .flagsChanged {
        let flags = event.flags
        DispatchQueue.main.async {
            HotkeyBox.shared.owner?.handleFlagsFromTap(flags)
        }
    }
    return Unmanaged.passUnretained(event)
}

extension DictationHotkeyMonitor {
    fileprivate func handleFlagsFromTap(_ flags: CGEventFlags) {
        handleFlags(flags)
    }
}
