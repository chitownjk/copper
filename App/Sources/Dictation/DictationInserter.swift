import AppKit
import ApplicationServices
import Carbon
import os.log

enum DictationInsertResult: Equatable {
    case insertedViaAX
    case pasted
    case copiedInstead
    case blocked(String)

    var debugLabel: String {
        switch self {
        case .insertedViaAX: return "inserted via AX"
        case .pasted: return "pasted"
        case .copiedInstead: return "clipboard only"
        case .blocked(let message): return "blocked: \(message)"
        }
    }
}

/// Paste-after-stop. Mail and Gmail often refuse AXSelectedText and ignore
/// a HID-tap ⌘V that never reaches their process. We try AX on the
/// frontmost app's focused element, then clipboard + ⌘V posted to that
/// app's pid, then leave the text on the clipboard.
enum DictationInserter {
    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "dictation")

    /// Last insert outcome, for the HUD / toast.
    static var lastDebugLabel = ""

    static func insert(_ text: String) -> DictationInsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return finish(.blocked("Nothing to insert.")) }

        if DictationPermissions.isSecureEventInputEnabled() {
            return finish(.blocked("Secure Keyboard Entry is on. Turn it off to dictate."))
        }

        let target = targetApplication()
        if let element = focusedElement(in: target), isSecure(element) {
            return finish(.blocked("Can't dictate into a password field."))
        }

        if insertViaAccessibility(trimmed, in: target) {
            return finish(.insertedViaAX)
        }
        return finish(insertViaPaste(trimmed, into: target))
    }

    static func focusedFieldIsSecure() -> Bool {
        if DictationPermissions.isSecureEventInputEnabled() { return true }
        guard let element = focusedElement(in: targetApplication()) else { return false }
        return isSecure(element)
    }

    private static func finish(_ result: DictationInsertResult) -> DictationInsertResult {
        lastDebugLabel = result.debugLabel
        logger.info("insert \(result.debugLabel, privacy: .public)")
        print("dictation insert: \(result.debugLabel)")
        return result
    }

    // MARK: - Target app

    /// Frontmost regular app that is not Companion. The HUD is a
    /// non-activating panel, so this should still be Mail / the browser.
    private static func targetApplication() -> NSRunningApplication? {
        let ours = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ours {
            return front
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.isActive && $0.processIdentifier != ours && $0.activationPolicy == .regular
        }
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String, in app: NSRunningApplication?) -> Bool {
        guard let element = focusedElement(in: app) else { return false }
        if isSecure(element) { return false }
        if setSelectedText(element, text) { return true }
        if spliceIntoValue(element, text) { return true }
        return false
    }

    private static func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    /// Insert at the selection (or append) by rewriting AXValue. Never
    /// replace the whole field unless we know the selected range or the
    /// current value is empty — wiping a Mail draft would be worse.
    private static func spliceIntoValue(_ element: AXUIElement, _ text: String) -> Bool {
        guard let current = stringAttribute(element, kAXValueAttribute as CFString) else { return false }
        let ns = current as NSString
        let range: NSRange
        if let selected = selectedRange(element) {
            let loc = min(max(selected.location, 0), ns.length)
            let len = min(max(selected.length, 0), ns.length - loc)
            range = NSRange(location: loc, length: len)
        } else if current.isEmpty {
            range = NSRange(location: 0, length: 0)
        } else {
            return false
        }
        let updated = ns.replacingCharacters(in: range, with: text)
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        ) == .success
    }

    private static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        if let app {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            if let element = copyFocusedElement(from: appEl) {
                return element
            }
        }
        return copyFocusedElement(from: AXUIElementCreateSystemWide())
    }

    private static func copyFocusedElement(from root: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute as CFString) == "AXSecureTextField"
            || stringAttribute(element, kAXSubroleAttribute as CFString) == "AXSecureTextField"
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Clipboard paste

    private static func insertViaPaste(_ text: String, into app: NSRunningApplication?) -> DictationInsertResult {
        let snapshot = PasteboardSnapshot.capture()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Mail / Chrome often ignore a HID-tap Command-V. Post to the
        // focused app's pid so the keystroke cannot land in our HUD.
        let posted: Bool
        if let pid = app?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            posted = postCommandV(to: pid)
        } else {
            posted = false
        }

        if posted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                snapshot.restore()
            }
            return .pasted
        }

        // Last resort: leave the text on the clipboard. Do not restore.
        return .copiedInstead
    }

    /// Isolated event source so leftover Control-Option from the talk
    /// chord cannot turn Command-V into a different shortcut.
    private static func postCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.localEventsSuppressionInterval = 0
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

private struct PasteboardSnapshot {
    let items: [[String: Data]]

    static func capture() -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            items.append(dict)
        }
        return PasteboardSnapshot(items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for dict in items {
            let item = NSPasteboardItem()
            for (raw, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            pasteboard.writeObjects([item])
        }
    }
}
