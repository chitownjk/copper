import AppKit
import SwiftUI

/// Locked identity. See docs/BRAND.md.
enum Brand {
    static let accent = Color(red: 196 / 255, green: 132 / 255, blue: 90 / 255)
    static let accentHover = Color(red: 212 / 255, green: 148 / 255, blue: 106 / 255)
    static let darkSurface = Color(red: 28 / 255, green: 25 / 255, blue: 22 / 255)
    static let darkElevated = Color(red: 42 / 255, green: 37 / 255, blue: 32 / 255)

    static let nsAccent = NSColor(srgbRed: 196 / 255, green: 132 / 255, blue: 90 / 255, alpha: 1)
}

extension Color {
    static var companionAccent: Color { Brand.accent }
}

extension MeetingStatus {
    /// Human chrome. Never show `rawValue` in the UI.
    var displayName: String {
        switch self {
        case .recording:    return "Recording"
        case .mixing:       return "Mixing"
        case .transcribing: return "Transcribing"
        case .summarizing:  return "Summarizing"
        case .ready:        return "Ready"
        case .failed:       return "Failed"
        }
    }

    var displayColor: Color {
        switch self {
        case .recording: return .red
        case .failed:    return .orange
        case .ready:     return .secondary
        default:         return Brand.accent
        }
    }
}
