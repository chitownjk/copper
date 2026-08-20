import Foundation
import GRDB
import MeetingCore

struct Meeting: Identifiable, Hashable {
    let id: String
    let startedAt: Date
    let directory: URL
}

extension Notification.Name {
    static let recordingDiskSpaceLow = Notification.Name("recordingDiskSpaceLow")
}

enum RecordingCapture: String {
    case micAndSystem
    case micOnly
}

struct RecordingRequest {
    var title: String? = nil
    var source: String = "manual"
    var calendarEventId: String? = nil
    var capture: RecordingCapture = .micAndSystem

    static let manual = RecordingRequest()
    static let cameraPrompt = RecordingRequest(source: "camera-prompt", capture: .micAndSystem)
    /// Walk-in / no calendar / no Zoom. Mic only — system audio is for calls.
    static let instant = RecordingRequest(title: "Instant meeting", source: "instant", capture: .micOnly)

    static func calendar(_ event: UpcomingEvent, capture: RecordingCapture) -> RecordingRequest {
        RecordingRequest(
            title: event.title,
            source: "calendar",
            calendarEventId: event.id,
            capture: capture
        )
    }
}

final class RecordingSession {
    let meeting: Meeting
    let capture: RecordingCapture
    let systemAudioFallbackReason: String?
    private let mic: MicRecorder
    private let system: SystemAudioRecorder?
    private var diskWatchdog: Task<Void, Never>?

    private init(
        meeting: Meeting,
        capture: RecordingCapture,
        systemAudioFallbackReason: String?,
        mic: MicRecorder,
        system: SystemAudioRecorder?
    ) {
        self.meeting = meeting
        self.capture = capture
        self.systemAudioFallbackReason = systemAudioFallbackReason
        self.mic = mic
        self.system = system
    }

    /// Warns once if free space drops below the floor mid-meeting (E1.5).
    /// Recording is never stopped automatically — losing the rest of a meeting
    /// is worse than filling the disk.
    private func startDiskWatchdog() {
        diskWatchdog = Task.detached(priority: .utility) {
            var warned = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if !warned, DiskSpace.isLowDuringRecording() {
                    warned = true
                    let available = DiskSpace.availableBytes() ?? 0
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .recordingDiskSpaceLow,
                            object: nil,
                            userInfo: ["available": DiskSpace.describe(available)]
                        )
                    }
                }
            }
        }
    }

    static func start(_ request: RecordingRequest = .manual) async throws -> RecordingSession {
        // Refuse rather than fail halfway through a meeting (E1.5).
        if !DiskSpace.canStartRecording() {
            throw DiskSpaceError.insufficientToStart(available: DiskSpace.availableBytes() ?? 0)
        }

        let id = compactTimestampID()
        let dir = try Paths.makeRecordingDirectory(for: id)
        let startedAt = Date()
        let meeting = Meeting(id: id, startedAt: startedAt, directory: dir)

        let row = MeetingRow(
            id: id,
            title: request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultTitle(at: startedAt),
            startedAt: startedAt.timeIntervalSince1970,
            endedAt: nil,
            source: request.source,
            calendarEventId: request.calendarEventId,
            audioDir: dir.path,
            status: MeetingStatus.recording.rawValue
        )
        var mic: MicRecorder?
        var system: SystemAudioRecorder?
        do {
            try await Database.shared.write { db in
                var insertable = row
                try insertable.insert(db)
            }

            let recorder = try MicRecorder(outputURL: dir.appendingPathComponent("mic.wav"))
            mic = recorder
            try recorder.start()

            var actualCapture = request.capture
            var fallbackReason: String?
            if request.capture == .micAndSystem {
                let systemRecorder = SystemAudioRecorder(
                    outputURL: dir.appendingPathComponent("system.wav")
                )
                do {
                    try await systemRecorder.start()
                    system = systemRecorder
                } catch {
                    // A denied Screen Recording permission must not make the
                    // microphone recording disappear. Continue transparently
                    // as mic-only and tell the user exactly what was lost.
                    actualCapture = .micOnly
                    fallbackReason = error.localizedDescription
                }
            }

            let session = RecordingSession(
                meeting: meeting,
                capture: actualCapture,
                systemAudioFallbackReason: fallbackReason,
                mic: recorder,
                system: system
            )
            session.startDiskWatchdog()
            return session
        } catch {
            // Startup is transactional: never leave a hot microphone, orphan
            // database row, or empty recording directory after a failed start.
            if let system {
                try? await system.stop()
            }
            mic?.stop()
            _ = try? await Database.shared.write { db in
                try MeetingRow.deleteOne(db, key: id)
            }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    func stop() async throws {
        diskWatchdog?.cancel()
        diskWatchdog = nil

        var firstError: Error?
        do {
            try await system?.stop()
        } catch {
            firstError = error
        }
        // Never let a ScreenCaptureKit shutdown error keep the mic recording.
        mic.stop()

        let endedAt = Date().timeIntervalSince1970
        let id = meeting.id
        do {
            try await Database.shared.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET ended_at = ? WHERE id = ?",
                    arguments: [endedAt, id]
                )
            }
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

private func compactTimestampID() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = .current
    let stamp = formatter.string(from: Date())
    let suffix = UUID().uuidString.prefix(8)
    return "\(stamp)-\(suffix)"
}

private func defaultTitle(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
