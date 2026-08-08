import AppKit
import Foundation
import GRDB
import MeetingCore

/// Finds recordings that never finished — `status = recording` rows left behind
/// by a crash, force quit, or power loss — and offers to salvage them (E1.5).
///
/// The audio writers flush as they go, so the partial WAVs on disk are usually
/// playable right up to the moment the process died. `AudioMixer` already
/// tolerates a missing or empty track, so recovery is just "run the pipeline
/// over whatever landed".
enum CrashRecovery {
    struct Orphan {
        let meeting: MeetingRow
        let audioBytes: Int64

        var hasAudio: Bool { audioBytes > 0 }
        var sizeDescription: String { DiskSpace.describe(audioBytes) }
    }

    static func findOrphans() async throws -> [Orphan] {
        let rows = try await Database.shared.read { db in
            try MeetingRow
                .filter(Column("status") == MeetingStatus.recording.rawValue)
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
        return rows.map { Orphan(meeting: $0, audioBytes: audioBytes(in: $0.audioDir)) }
    }

    /// Marks the recording as ended and re-enters the normal post-meeting
    /// pipeline. An orphan with no audio can't be recovered — discard instead.
    static func recover(_ orphan: Orphan) async throws {
        let id = orphan.meeting.id
        let endedAt = lastModified(in: orphan.meeting.audioDir) ?? Date().timeIntervalSince1970
        try await Database.shared.write { db in
            try db.execute(
                sql: "UPDATE meetings SET ended_at = COALESCE(ended_at, ?) WHERE id = ?",
                arguments: [endedAt, id]
            )
        }
        await Pipeline.shared.process(meetingId: id)
    }

    /// Deletes the row and its audio directory. Destructive and immediate —
    /// only ever called after the user picks "Discard" in the prompt.
    static func discard(_ orphan: Orphan) async throws {
        let id = orphan.meeting.id
        let dir = orphan.meeting.audioDir
        try await Database.shared.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meetings_fts WHERE meeting_id = ?", arguments: [id])
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir))
    }

    // MARK: - Helpers

    private static func audioBytes(in directory: String) -> Int64 {
        let url = URL(fileURLWithPath: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return 0 }
        return names
            .filter { $0.hasSuffix(".wav") }
            .reduce(into: Int64(0)) { total, name in
                let size = try? url.appendingPathComponent(name)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize
                total += Int64(size ?? 0)
            }
    }

    /// Best estimate of when the recording actually stopped: the newest write
    /// to any of its audio files.
    private static func lastModified(in directory: String) -> Double? {
        let url = URL(fileURLWithPath: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let dates = names.compactMap { name -> Date? in
            try? url.appendingPathComponent(name)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max()?.timeIntervalSince1970
    }
}

@MainActor
enum CrashRecoveryPrompt {
    /// Runs once at launch, before the user starts anything new.
    static func runIfNeeded() async {
        let orphans: [CrashRecovery.Orphan]
        do {
            orphans = try await CrashRecovery.findOrphans()
        } catch {
            print("Crash recovery scan failed: \(error)")
            return
        }
        guard !orphans.isEmpty else { return }

        for orphan in orphans {
            await handle(orphan)
        }
    }

    private static func handle(_ orphan: CrashRecovery.Orphan) async {
        let alert = NSAlert()
        alert.messageText = "“\(orphan.meeting.title)” didn’t finish recording"

        if orphan.hasAudio {
            alert.informativeText = """
            The app quit while this meeting was still recording. \
            \(orphan.sizeDescription) of audio was saved — it can still be \
            transcribed and summarized.
            """
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Decide Later")
        } else {
            alert.informativeText = """
            The app quit while this meeting was still recording, and no audio \
            was captured before it stopped. There is nothing to recover.
            """
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Decide Later")
        }

        let response = alert.runModal()
        let choice = orphan.hasAudio ? response : (response == .alertFirstButtonReturn ? .alertSecondButtonReturn : .alertThirdButtonReturn)

        switch choice {
        case .alertFirstButtonReturn:
            ToastPresenter.shared.show(.info, title: "Recovering recording", subtitle: orphan.meeting.title)
            Task.detached(priority: .utility) {
                try? await CrashRecovery.recover(orphan)
            }
        case .alertSecondButtonReturn:
            Task.detached(priority: .utility) {
                try? await CrashRecovery.discard(orphan)
            }
        default:
            break // Left as-is; the prompt reappears next launch.
        }
    }
}
