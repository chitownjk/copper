#!/usr/bin/swift
// Sink-transport debugging: enumerates CMIO devices the C-API way (the way
// CameraSinkClient finds the sink stream) and prints each device's UID and
// per-scope stream counts.
import CoreMediaIO
import Foundation
import AVFoundation

// Extension-provided devices may only materialize in the CMIO hardware object
// space once AVFoundation's discovery machinery has run in this process.
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external],
    mediaType: .video,
    position: .unspecified
)
print("AVFoundation sees \(discovery.devices.count) device(s): \(discovery.devices.map(\.localizedName))")

func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(scope),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
}

let system = CMIOObjectID(kCMIOObjectSystemObject)
var addr = address(kCMIOHardwarePropertyDevices)
var dataSize: UInt32 = 0
var status = CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize)
print("GetPropertyDataSize status=\(status) dataSize=\(dataSize)")
let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
var ids = [CMIOObjectID](repeating: 0, count: max(count, 1))
var dataUsed: UInt32 = 0
status = CMIOObjectGetPropertyData(system, &addr, 0, nil, dataSize, &dataUsed, &ids)
print("GetPropertyData status=\(status) count=\(count)")

for id in ids where id != 0 {
    var uidAddr = address(kCMIODevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var used: UInt32 = 0
    let s = withUnsafeMutablePointer(to: &uid) { ptr in
        CMIOObjectGetPropertyData(id, &uidAddr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, ptr)
    }
    let uidString = (s == 0) ? (uid?.takeRetainedValue() as String? ?? "nil") : "err \(s)"
    var streamCounts: [String] = []
    for (name, scope) in [("in", kCMIODevicePropertyScopeInput), ("out", kCMIODevicePropertyScopeOutput), ("global", kCMIOObjectPropertyScopeGlobal)] {
        var sAddr = address(kCMIODevicePropertyStreams, scope: scope)
        var sSize: UInt32 = 0
        CMIOObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize)
        streamCounts.append("\(name)=\(Int(sSize) / MemoryLayout<CMIOStreamID>.size)")
    }
    print("device \(id): uid=\(uidString) streams \(streamCounts.joined(separator: " "))")
}
