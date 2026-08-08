#!/usr/bin/swift
// E5.1 verification probe: lists every camera the system offers to apps,
// exactly the way Photo Booth/Zoom discover them. Run after approving the
// extension:  swift Scripts/list-cameras.swift
import AVFoundation

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
    mediaType: .video,
    position: .unspecified
)
if discovery.devices.isEmpty {
    print("no cameras visible")
}
for device in discovery.devices {
    print("\(device.localizedName)  [\(device.deviceType.rawValue)]  id=\(device.uniqueID)")
}
