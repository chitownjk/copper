import AppKit
import CoreGraphics
import Foundation

/// On-screen meeting windows and in-call browser tabs.
///
/// CMIO "in use" is unreliable for our virtual camera (false when Meet has
/// us selected; sticky if we use RunningSomewhere). Chrome window titles
/// are often empty without Screen Recording, so we also ask Chrome/Safari
/// for tab titles over AppleScript (Automation prompt, once).
enum MeetingCallDetector {
    private static var browserCache = false
    private static var browserCacheAt = Date.distantPast
    private static let cacheLock = NSLock()

    static func isInACall() -> Bool {
        if windowListShowsCall() { return true }
        return browserTabsShowMeet()
    }

    private static func windowListShowsCall() -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
            if owner.contains("zoom") {
                if title.isEmpty || title.contains("meeting") || title.contains("webinar") {
                    return true
                }
                continue
            }
            if owner.contains("microsoft teams") || owner == "teams" { return true }
            if owner.contains("facetime") { return true }
            if owner.contains("webex") { return true }
            if isBrowser(owner), titleLooksLikeMeetCall(title) { return true }
        }
        return false
    }

    private static func isBrowser(_ owner: String) -> Bool {
        owner.contains("chrome")
            || owner.contains("safari")
            || owner.contains("arc")
            || owner.contains("firefox")
            || owner.contains("brave")
            || owner.contains("edge")
    }

    /// In-call Meet titles look like "Weekly standup - Meet" or "Meet - abc-defg-hij".
    /// The leftover "Meet" / "Google Meet" landing tab after hangup does not count.
    static func titleLooksLikeMeetCall(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("meet.google.com") { return true }
        if t.contains(" - meet") { return true }
        if t.contains("meet - ") { return true }
        if t.contains("google meet") && t != "google meet" { return true }
        return false
    }

    private static func browserTabsShowMeet() -> Bool {
        cacheLock.lock()
        let age = Date().timeIntervalSince(browserCacheAt)
        let cached = browserCache
        cacheLock.unlock()
        if age < 0.2 { return cached }

        let found = chromeOrSafariMeetTab()
        cacheLock.lock()
        browserCache = found
        browserCacheAt = Date()
        cacheLock.unlock()
        return found
    }

    private static func chromeOrSafariMeetTab() -> Bool {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        if running.contains("com.google.Chrome"), chromeMeetTabs() { return true }
        if running.contains("com.apple.Safari"), safariMeetTabs() { return true }
        if running.contains("company.thebrowser.Browser"), chromeLikeMeetTabs(app: "Arc") { return true }
        if running.contains("com.brave.Browser"), chromeLikeMeetTabs(app: "Brave Browser") { return true }
        return false
    }

    private static func chromeMeetTabs() -> Bool {
        chromeLikeMeetTabs(app: "Google Chrome")
    }

    private static func chromeLikeMeetTabs(app: String) -> Bool {
        let source = """
        tell application "\(app)"
          repeat with w in windows
            repeat with t in tabs of w
              set theTitle to title of t as string
              set theURL to ""
              try
                set theURL to URL of t as string
              end try
              if theURL contains "meet.google.com/landing" then
              else if theTitle contains "You left" then
              else if (theTitle contains " - Meet") or (theTitle contains "Meet - ") or (theURL contains "meet.google.com/") then
                try
                  set leftCall to execute t javascript "(() => { const s = document.body ? document.body.innerText : ''; return /You left the meeting|You left the call|Ready to join|Return to home screen/.test(s); })()"
                  if (leftCall as string) is "false" then return true
                on error
                  if theURL contains "meet.google.com/" and theURL does not contain "/landing" then return true
                end try
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        return runBooleanAppleScript(source)
    }

    private static func safariMeetTabs() -> Bool {
        let source = """
        tell application "Safari"
          repeat with w in windows
            repeat with t in tabs of w
              set theTitle to name of t as string
              set theURL to ""
              try
                set theURL to URL of t as string
              end try
              if theURL contains "meet.google.com/landing" then
              else if theTitle contains "You left" then
              else if (theTitle contains " - Meet") or (theTitle contains "Meet - ") or (theURL contains "meet.google.com/") then
                try
                  set leftCall to do JavaScript "(() => { const s = document.body ? document.body.innerText : ''; return /You left the meeting|You left the call|Ready to join|Return to home screen/.test(s); })()" in t
                  if (leftCall as string) is "false" then return true
                on error
                  if theURL contains "meet.google.com/" and theURL does not contain "/landing" then return true
                end try
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        return runBooleanAppleScript(source)
    }

    private static func runBooleanAppleScript(_ source: String) -> Bool {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return false }
        return result?.booleanValue == true
    }
}
