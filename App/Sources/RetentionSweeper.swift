import Foundation
import GRDB
import MeetingCore

/// Applies the retention policy to recorded audio once a day (PRD A7, E3.4).
///
/// Deletes WAV files only. Transcripts, notes, and summaries stay forever —
/// they're what the user actually came for, and they're kilobytes.
enum RetentionSweeper {
    struct Result {
        var meetingsSwept = 0
        var bytesReclaimed: Int64 = 0
    }

    /// Called at launch and after each pipeline run. No-ops unless a day has
    /// passed and the policy actually deletes something.
    @discardableResult
    static func sweepIfDue(now: Date = Date()) async -> Result {
        guard RetentionSettings.policy.maximumAge != nil, RetentionSettings.isSweepDue(now: now) else {
            return Result()
        }
        let result = await sweep(now: now)
        RetentionSettings.lastSweep = now
        return result
    }

    /// Runs regardless of the daily gate — used by the "Delete audio now"
    /// button in Settings.
    @discardableResult
    static func sweep(now: Date = Date()) async -> Result {
        var result = Result()
        let candidates: [MeetingRow]
        do {
            candidates = try await Database.shared.read { db in
                try MeetingRow
                    .filter(Column("status") == MeetingStatus.ready.rawValue)
                    .filter(Column("retention_pinned") == false)
                    .fetchAll(db)
            }
        } catch {
            print("Retention sweep failed to read meetings: \(error)")
            return result
        }

        for meeting in candidates {
            guard let endedAt = meeting.endedAt else { continue }
            guard RetentionSettings.shouldDeleteAudio(
                endedAt: Date(timeIntervalSince1970: endedAt),
                isPinned: meeting.retentionPinned,
                isProcessed: true,
                now: now
            ) else { continue }

            let directory = URL(fileURLWithPath: meeting.audioDir)
            let bytes = RecordingArtifacts.audioBytes(in: directory)
            guard bytes > 0 else { continue }

            if deleteAudioFiles(in: directory) {
                result.meetingsSwept += 1
                result.bytesReclaimed += bytes
            }
        }
        return result
    }

    /// Removes the WAVs but keeps the directory — its presence is how the
    /// library distinguishes "audio was swept" from "meeting never recorded".
    private static func deleteAudioFiles(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        var deletedAnything = false
        for name in names where name.hasSuffix(".wav") {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                deletedAnything = true
            } catch {
                print("Retention sweep couldn't delete \(name): \(error)")
            }
        }
        return deletedAnything
    }

    /// Bytes the audio for all meetings currently occupies.
    static func totalAudioBytes() async -> Int64 {
        let meetings = (try? await Database.shared.read { db in
            try MeetingRow.fetchAll(db)
        }) ?? []
        return meetings.reduce(into: Int64(0)) { total, meeting in
            total += RecordingArtifacts.audioBytes(in: URL(fileURLWithPath: meeting.audioDir))
        }
    }
}
