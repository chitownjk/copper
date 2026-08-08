import Foundation
import CoreMediaIO

// The extension process is launched and owned by the CMIO subsystem. All it
// ever does is serve frames — the tracer bullet serves a generated test card;
// later, frames pushed by the app through the sink stream. Effects, capture,
// and ML never run here (CLAUDE.md hard rule 2 / TECH_PLAN R2).
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
