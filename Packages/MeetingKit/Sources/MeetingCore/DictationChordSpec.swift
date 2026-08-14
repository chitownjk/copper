import Foundation

/// Which modifiers form the talk chord. Command is never part of the chord
/// (Control-Option-Command-R is the global stop-recording safety net).
public struct DictationChordSpec: Equatable, Sendable, Codable {
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    /// Fn alone, on Apple keyboards that emit `maskSecondaryFn`.
    public var alsoFnAlone: Bool

    public init(control: Bool, option: Bool, shift: Bool, alsoFnAlone: Bool) {
        self.control = control
        self.option = option
        self.shift = shift
        self.alsoFnAlone = alsoFnAlone
    }

    public static let `default` = DictationChordSpec(
        control: true, option: true, shift: false, alsoFnAlone: true
    )

    public var displayName: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if parts.isEmpty {
            return alsoFnAlone ? "Fn" : "None"
        }
        let chord = parts.joined(separator: "-")
        if alsoFnAlone { return "\(chord) or Fn" }
        return chord
    }

    /// Pure matcher so tests do not need CGEventFlags.
    /// Extra Fn on top of a modifier chord is ignored (Apple keyboards).
    /// Command always rejects.
    public func matches(control: Bool, option: Bool, shift: Bool, command: Bool, fn: Bool) -> Bool {
        if command { return false }
        let requiredHeld = self.control || self.option || self.shift
        if requiredHeld,
           self.control == control,
           self.option == option,
           self.shift == shift {
            return true
        }
        if alsoFnAlone && fn && !control && !option && !shift {
            return true
        }
        return false
    }
}

public enum DictationChordPreset: String, CaseIterable, Sendable, Codable, Identifiable {
    case controlOption
    case option
    case control
    case controlShift
    case optionShift
    case fnOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .controlOption: return "Control-Option"
        case .option:        return "Option"
        case .control:       return "Control"
        case .controlShift:  return "Control-Shift"
        case .optionShift:   return "Option-Shift"
        case .fnOnly:        return "Fn"
        }
    }

    public func spec(alsoFnAlone: Bool) -> DictationChordSpec {
        switch self {
        case .controlOption:
            return DictationChordSpec(control: true, option: true, shift: false, alsoFnAlone: alsoFnAlone)
        case .option:
            return DictationChordSpec(control: false, option: true, shift: false, alsoFnAlone: alsoFnAlone)
        case .control:
            return DictationChordSpec(control: true, option: false, shift: false, alsoFnAlone: alsoFnAlone)
        case .controlShift:
            return DictationChordSpec(control: true, option: false, shift: true, alsoFnAlone: alsoFnAlone)
        case .optionShift:
            return DictationChordSpec(control: false, option: true, shift: true, alsoFnAlone: alsoFnAlone)
        case .fnOnly:
            return DictationChordSpec(control: false, option: false, shift: false, alsoFnAlone: true)
        }
    }
}

/// Persisted talk-chord. Default remains Control-Option plus Fn alone.
public enum DictationHotkeySettings {
    private static let presetKey = "dictationChordPreset"
    private static let fnKey = "dictationAlsoFnAlone"

    public static var preset: DictationChordPreset {
        get {
            let raw = UserDefaults.standard.string(forKey: presetKey) ?? DictationChordPreset.controlOption.rawValue
            return DictationChordPreset(rawValue: raw) ?? .controlOption
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: presetKey) }
    }

    public static var alsoFnAlone: Bool {
        get {
            if UserDefaults.standard.object(forKey: fnKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: fnKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: fnKey) }
    }

    public static var current: DictationChordSpec {
        preset.spec(alsoFnAlone: preset == .fnOnly ? true : alsoFnAlone)
    }
}
