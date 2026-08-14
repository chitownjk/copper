import AppKit
import CoreMediaIO
import Foundation
import Observation

/// Watches physical cameras (not Companion Camera / the test card).
/// Rising edge → "Record this?" HUD. Never auto-starts.
@MainActor
@Observable
final class CameraUseMonitor {
    private static let photoBooth = "com.apple.PhotoBooth"
    private static let pollNanos: UInt64 = 1_500_000_000

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var camerasWereOn = false
    @ObservationIgnored private var dismissedThisPulse = false
    @ObservationIgnored private let hud = CameraRecordPromptHUD()
    @ObservationIgnored private var isRecording: () -> Bool = { false }
    @ObservationIgnored private var weAreCapturing: () -> Bool = { false }
    @ObservationIgnored private var onYes: () -> Void = {}

    func attach(
        isRecording: @escaping () -> Bool,
        weAreCapturing: @escaping () -> Bool,
        onYes: @escaping () -> Void
    ) {
        self.isRecording = isRecording
        self.weAreCapturing = weAreCapturing
        self.onYes = onYes
        hud.onYes = { [weak self] in
            self?.dismissedThisPulse = true
            self?.hud.hide()
            onYes()
        }
        hud.onDismiss = { [weak self] in
            self?.dismissedThisPulse = true
            self?.hud.hide()
        }
        start()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollNanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        hud.hide()
    }

    private func tick() {
        if ScreenLock.isLocked {
            hud.hide()
            return
        }
        let on = physicalCameraInUseBySomeoneElse()
        if on && !camerasWereOn {
            if !dismissedThisPulse && !isRecording() {
                hud.show()
            }
        }
        if !on && camerasWereOn {
            dismissedThisPulse = false
            hud.hide()
        }
        camerasWereOn = on
    }

    private func physicalCameraInUseBySomeoneElse() -> Bool {
        if weAreCapturing() { return false }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.photoBooth {
            return false
        }
        return CameraUseProbe.physicalCameraRunningSomewhere(
            excludingUID: CameraSinkClient.deviceUID
        )
    }
}

enum CameraUseProbe {
    static func physicalCameraRunningSomewhere(excludingUID: String) -> Bool {
        for device in allDevices() {
            guard let uid = deviceUID(of: device), uid != excludingUID else { continue }
            if isRunningSomewhere(device) { return true }
        }
        return false
    }

    private static func allDevices() -> [CMIOObjectID] {
        var addr = address(kCMIOHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == kCMIOHardwareNoError,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, dataSize, &used, &ids) == kCMIOHardwareNoError else {
            return []
        }
        return ids
    }

    private static func deviceUID(of device: CMIOObjectID) -> String? {
        var addr = address(kCMIODevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, pointer)
        }
        guard status == kCMIOHardwareNoError, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutablePointer(to: &running) { pointer in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, pointer)
        }
        return status == kCMIOHardwareNoError && running != 0
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
