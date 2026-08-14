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

/// Paste-after-stop. Mail, Gmail, and Slack often accept an AX write
/// (`.success`) without changing the focused field. We never report
/// inserted/pasted unless a re-read of the field contains the new text.
enum DictationInserter {
    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "dictation")

    /// Last insert outcome, for the HUD / toast.
    static var lastDebugLabel = ""

    @MainActor
    static func insert(_ text: String) async -> DictationInsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return finish(.blocked("Nothing to insert.")) }

        if DictationPermissions.isSecureEventInputEnabled() {
            return finish(.blocked("Secure Keyboard Entry is on. Turn it off to dictate."))
        }

        var target = targetApplication()
        if let element = focusedElement(in: target), isSecure(element) {
            return finish(.blocked("Can't dictate into a password field."))
        }

        // Clipboard is the honest fallback. Stage it first so a failed
        // insert still leaves the sentence ready for ⌘V.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)

        if let app = target, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .milliseconds(80))
            target = targetApplication() ?? app
        }

        if await pasteAndVerify(trimmed, into: target) {
            return finish(.pasted)
        }
        if await axInsertAndVerify(trimmed, in: target) {
            return finish(.insertedViaAX)
        }
        return finish(.copiedInstead)
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

    // MARK: - Verify

    private struct FieldSnapshot: Equatable {
        var value: String?
        var selected: String?
    }

    private static func snapshot(_ element: AXUIElement) -> FieldSnapshot {
        FieldSnapshot(
            value: stringAttribute(element, kAXValueAttribute as CFString),
            selected: stringAttribute(element, kAXSelectedTextAttribute as CFString)
        )
    }

    private static func fieldContains(_ text: String, _ snap: FieldSnapshot) -> Bool {
        if let selected = snap.selected, selected.contains(text) { return true }
        if let value = snap.value, value.contains(text) { return true }
        return false
    }

    /// Hard proof the focused field now holds `text`. A no-op AX write
    /// returns `.success` but leaves the snapshot unchanged.
    private static func verifiedInsert(_ text: String, before: FieldSnapshot, after: FieldSnapshot) -> Bool {
        guard fieldContains(text, after) else { return false }
        if after != before { return true }
        // Field already contained the same sentence (re-dictate). Treat as
        // landed only if we can still read it back.
        return after.value != nil || after.selected != nil
    }

    // MARK: - Accessibility

    @MainActor
    private static func axInsertAndVerify(_ text: String, in app: NSRunningApplication?) async -> Bool {
        guard let element = focusedElement(in: app) else { return false }
        if isSecure(element) { return false }
        let before = snapshot(element)
        let wrote = setSelectedText(element, text) || spliceIntoValue(element, text)
        guard wrote else { return false }
        try? await Task.sleep(for: .milliseconds(80))
        let after = snapshot(element)
        return verifiedInsert(text, before: before, after: after)
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

    @MainActor
    private static func pasteAndVerify(_ text: String, into app: NSRunningApplication?) async -> Bool {
        guard let pid = app?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return false
        }
        let element = focusedElement(in: app)
        let before = element.map(snapshot) ?? FieldSnapshot()
        guard postCommandV(to: pid) else { return false }
        try? await Task.sleep(for: .milliseconds(280))
        let afterElement = focusedElement(in: app) ?? element
        let after = afterElement.map(snapshot) ?? FieldSnapshot()
        return verifiedInsert(text, before: before, after: after)
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
