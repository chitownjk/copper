import AppKit
import Carbon
import SwiftUI

/// Carbon hotkey callbacks are not actor-isolated; this box lets the C handler
/// hop to the main queue without touching `StatusItemController` directly.
private final class StopHotKeyBox: @unchecked Sendable {
    static let shared = StopHotKeyBox()
    var onPress: (() -> Void)?
}

/// Owns the menu-bar extra as a real `NSStatusItem` created once and never
/// removed. Replaces SwiftUI `MenuBarExtra`, whose scene-owned status item
/// was getting crowded off (or torn down) when the camera/mic privacy
/// indicators appeared and a meeting app ate the left side of the menu bar.
@MainActor
final class StatusItemController: NSObject {
    private let appState: AppState
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var claimTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var unseenReaderSince: Date?
    private static let unclaimGrace: TimeInterval = 0.35

    init(appState: AppState) {
        self.appState = appState
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.autosaveName = "MeetingCompanion.statusItem"
        // Do not allow the user (or the system overflow) to remove this item.
        item.behavior = []
        item.isVisible = true

        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Meeting Companion"

        let root = MenuBarView()
            .environment(appState)
            .padding(12)
            .frame(width: 280)

        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 304, height: 360)
        popover.contentViewController = host

        AppDelegate.dockMenuBuilder = { [weak self] in
            self?.makeDockMenu() ?? NSMenu()
        }
        AppDelegate.onBecomeActive = { [weak self] in
            self?.keepVisible()
        }

        startObserving()
        startClaimTimer()
        registerStopHotKey()
        refreshButton()
        keepVisible()
    }

    // MARK: - Button

    private func startObserving() {
        withObservationTracking {
            _ = appState.menuBarSymbol
            _ = appState.status
            _ = appState.camera.state
            _ = appState.virtualCameraClaimed
            _ = appState.dictation.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.startObserving()
            }
        }
    }

    private func refreshButton() {
        item.button?.image = menuBarImage()
        keepVisible()
    }

    private func menuBarImage() -> NSImage? {
        if appState.dictation.isActive {
            let name = appState.dictation.phase == .transcribing
                ? "text.badge.waveform"
                : "mic.fill"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dictating")
            image?.isTemplate = true
            return image
        }
        if appState.status == .recording {
            let image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "Recording"
            )
            image?.isTemplate = true
            return image
        }
        if let custom = NSImage(named: "MenuBarMark") {
            custom.isTemplate = true
            custom.size = NSSize(width: 18, height: 18)
            return custom
        }
        let image = NSImage(
            systemSymbolName: appState.menuBarSymbol,
            accessibilityDescription: "Meeting Companion"
        )
        image?.isTemplate = true
        return image
    }

    func keepVisible() {
        item.isVisible = true
    }

    @objc private func togglePopover(_ sender: Any?) {
        keepVisible()
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Virtual-camera claim (test-card path)

    private func startClaimTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClaimAndKeepVisible()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        claimTimer = timer
        pollClaimAndKeepVisible()
    }

    private func pollClaimAndKeepVisible() {
        // isInUseByAnotherApplication is false for this CMIO device.
        // MeetingCallDetector (windows + Chrome/Safari Meet tabs) is the
        // hangup signal. Do not treat "we are live" as still in a call.
        let readers = CameraSinkClient.isVirtualCameraRunningSomewhere()
        let claimed: Bool
        if readers {
            unseenReaderSince = nil
            claimed = true
        } else {
            if unseenReaderSince == nil {
                unseenReaderSince = Date()
            }
            // Rising edge is immediate. Falling edge waits N seconds of
            // no readers so a Meet camera-toggle blip does not tear down
            // the feed — and a sticky CMIO flag cannot leave a zombie HUD.
            let elapsed = Date().timeIntervalSince(unseenReaderSince ?? Date())
            claimed = appState.virtualCameraClaimed && elapsed < Self.unclaimGrace
        }
        if appState.virtualCameraClaimed != claimed {
            appState.virtualCameraClaimed = claimed
        }
        appState.refreshCameraHUD()
        keepVisible()
    }

    // MARK: - Dock menu

    private func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        if appState.status == .recording {
            addItem(menu, "Stop Recording", #selector(dockStopRecording))
        } else {
            addItem(menu, "Start Recording", #selector(dockStartRecording))
        }
        if appState.camera.isLive {
            addItem(menu, "Stop Virtual Camera", #selector(dockStopCamera))
        } else {
            addItem(menu, "Go Live", #selector(dockGoLive))
        }
        menu.addItem(.separator())
        addItem(menu, "Open Meeting Companion", #selector(dockOpenMain))
        addItem(menu, "Settings…", #selector(dockOpenSettings))
        return menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func dockStartRecording() {
        Task { await appState.startRecording() }
    }

    @objc private func dockStopRecording() {
        Task { await appState.stopRecording() }
    }

    @objc private func dockGoLive() {
        Task { await appState.camera.goLive() }
    }

    @objc private func dockStopCamera() {
        appState.camera.stopLive()
    }

    @objc private func dockOpenMain() {
        appState.mainWindow.show()
    }

    @objc private func dockOpenSettings() {
        appState.openSettings()
    }

    func handleStopHotKey() {
        guard appState.status == .recording else { return }
        Task { await appState.stopRecording() }
    }

    // MARK: - Global Control-Option-Command-R (works while Zoom/Meet is frontmost)

    private func registerStopHotKey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        StopHotKeyBox.shared.onPress = { [weak self] in
            self?.handleStopHotKey()
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async {
                    StopHotKeyBox.shared.onPress?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &hotKeyHandler
        )
        let hotKeyID = EventHotKeyID(signature: 0x4D4E5352, id: 1) // 'MNSR'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
