import Foundation
import CoreMediaIO
import os.log

let extensionLogger = Logger(subsystem: "com.strongrise.meetingcompanion.cameraextension", category: "extension")

/// Provider: the root object the CMIO subsystem talks to. One device.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "Copper Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        extensionLogger.info("client connected: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        extensionLogger.info("client disconnected: \(client.signingID ?? "unknown", privacy: .public) pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Copper"
        }
        if properties.contains(.providerName) {
            providerProperties.name = "Copper Camera Provider"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties.
    }
}
