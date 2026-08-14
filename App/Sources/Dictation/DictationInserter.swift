import AppKit
import ApplicationServices
import Carbon

enum DictationInsertResult: Equatable {
    case inserted
    case copiedInstead
    case blocked(String)
}

/// Paste-after-stop. Tries AX selected-text first (no clipboard), then
/// synthetic ⌘V. If both fail, leaves the text on the clipboard.
enum DictationInserter {
    static func insert(_ text: String) -> DictationInsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blocked("Nothing to insert.") }

        if DictationPermissions.isSecureEventInputEnabled() {
            return .blocked("Secure Keyboard Entry is on. Turn it off to dictate.")
        }
        if let focused = focusedElement(), isSecure(focused) {
            return .blocked("Can't dictate into a password field.")
        }

        if insertViaAccessibility(trimmed) {
            return .inserted
        }
        return insertViaPaste(trimmed)
    }

    static func focusedFieldIsSecure() -> Bool {
        if DictationPermissions.isSecureEventInputEnabled() { return true }
        guard let focused = focusedElement() else { return false }
        return isSecure(focused)
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        if isSecure(element) { return false }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return error == .success
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            system,
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

    // MARK: - Clipboard paste

    private static func insertViaPaste(_ text: String) -> DictationInsertResult {
        let snapshot = PasteboardSnapshot.capture()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard postCommandV() else {
            return .copiedInstead
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            snapshot.restore()
        }
        return .inserted
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let key: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
