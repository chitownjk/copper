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

final class RecordingSession {
    let meeting: Meeting
    private let mic: MicRecorder
    private let system: SystemAudioRecorder
    private var diskWatchdog: Task<Void, Never>?

    private init(meeting: Meeting, mic: MicRecorder, system: SystemAudioRecorder) {
        self.meeting = meeting
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

    static func start() async throws -> RecordingSession {
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
            title: defaultTitle(at: startedAt),
            startedAt: startedAt.timeIntervalSince1970,
            endedAt: nil,
            source: "manual",
            calendarEventId: nil,
            audioDir: dir.path,
            status: MeetingStatus.recording.rawValue
        )
        try await Database.shared.write { db in
            var insertable = row
            try insertable.insert(db)
        }

        let mic = try MicRecorder(outputURL: dir.appendingPathComponent("mic.wav"))
        let system = SystemAudioRecorder(outputURL: dir.appendingPathComponent("system.wav"))

        try mic.start()
        try await system.start()

        let session = RecordingSession(meeting: meeting, mic: mic, system: system)
        session.startDiskWatchdog()
        return session
    }

    func stop() async throws {
        diskWatchdog?.cancel()
        diskWatchdog = nil
        try await system.stop()
        mic.stop()

        let endedAt = Date().timeIntervalSince1970
        let id = meeting.id
        try await Database.shared.write { db in
            try db.execute(
                sql: "UPDATE meetings SET ended_at = ? WHERE id = ?",
                arguments: [endedAt, id]
            )
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
