import Foundation
import SystemExtensions
import os.log

/// Activates/deactivates the bundled CMIO camera extension (E5.1).
///
/// The OS owns the actual lifecycle: activation stages the extension out of
/// our bundle, asks the user for approval in System Settings the first time,
/// and keeps serving the *old* copy until an upgrade is approved. This class
/// just submits the request and reports what happened.
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.strongrise.meetingcompanion.cameraextension"
    private static let logger = Logger(subsystem: "com.strongrise.meetingcompanion", category: "camera-extension")

    enum Outcome {
        case completed
        case willCompleteAfterReboot
        case needsUserApproval // terminal for our request only in the sense that the OS takes over
        case failed(Error)
    }

    /// Called on every state change worth surfacing; may fire more than once
    /// (e.g. `needsUserApproval` followed by `completed`).
    var onOutcome: ((Outcome) -> Void)?

    // Keep the in-flight request's installer alive; OSSystemExtensionManager
    // holds the delegate weakly.
    private static var active: CameraExtensionInstaller?

    static func install(onOutcome: @escaping (Outcome) -> Void) {
        submit(activation: true, onOutcome: onOutcome)
    }

    static func uninstall(onOutcome: @escaping (Outcome) -> Void) {
        submit(activation: false, onOutcome: onOutcome)
    }

    private static func submit(activation: Bool, onOutcome: @escaping (Outcome) -> Void) {
        let installer = CameraExtensionInstaller()
        installer.onOutcome = onOutcome
        active = installer
        let request: OSSystemExtensionRequest = activation
            ? .activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
            : .deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
        logger.info("submitted \(activation ? "activation" : "deactivation", privacy: .public) request")
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Self.logger.info("replacing \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Self.logger.info("needs user approval in System Settings")
        onOutcome?(.needsUserApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            Self.logger.info("request completed")
            onOutcome?(.completed)
        case .willCompleteAfterReboot:
            Self.logger.info("request will complete after reboot")
            onOutcome?(.willCompleteAfterReboot)
        @unknown default:
            Self.logger.error("unknown result \(String(describing: result), privacy: .public)")
            onOutcome?(.completed)
        }
        Self.active = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Self.logger.error("request failed: \(error.localizedDescription, privacy: .public)")
        onOutcome?(.failed(error))
        Self.active = nil
    }
}
