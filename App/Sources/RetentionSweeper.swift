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
    /// passed and the policy actually deletes something. Leftover stems are
    /// dropped even when the daily gate is not due — they are not retention.
    @discardableResult
    static func sweepIfDue(now: Date = Date()) async -> Result {
        await dropLeftoverStems()
        guard RetentionSettings.policy.maximumAge != nil, RetentionSettings.isSweepDue(now: now) else {
            return Result()
        }
        let result = await sweep(now: now)
        RetentionSettings.lastSweep = now
        return result
    }

    /// Walks ready meetings and deletes mic.wav / system.wav wherever a
    /// verified mix already exists. Independent of the daily retention gate
    /// so existing meetings that still hold capture stems are reclaimed on
    /// the next launch.
    @discardableResult
    static func dropLeftoverStems() async -> Int {
        let meetings: [MeetingRow]
        do {
            meetings = try await Database.shared.read { db in
                try MeetingRow
                    .filter(Column("status") == MeetingStatus.ready.rawValue)
                    .fetchAll(db)
            }
        } catch {
            print("Leftover-stem drop failed to read meetings: \(error)")
            return 0
        }
        var dropped = 0
        for meeting in meetings {
            let directory = URL(fileURLWithPath: meeting.audioDir)
            if RecordingArtifacts.dropStemsIfMixVerified(in: directory) {
                dropped += 1
            }
        }
        return dropped
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
            let directory = URL(fileURLWithPath: meeting.audioDir)
            let bytes = RecordingArtifacts.audioBytes(in: directory)
            guard bytes > 0 else { continue }
            if sweep(meeting: meeting, now: now) {
                result.meetingsSwept += 1
                result.bytesReclaimed += bytes
            }
        }
        return result
    }

    /// Called at the end of a successful pipeline run. Honors the current
    /// policy immediately — `afterTranscription` must not wait for the daily
    /// gate, or a just-finished meeting keeps its WAVs until tomorrow.
    @discardableResult
    static func sweepMeetingIfEligible(meetingId: String, now: Date = Date()) async -> Bool {
        let meeting: MeetingRow
        do {
            guard let row = try await Database.shared.read({ db in
                try MeetingRow.fetchOne(db, key: meetingId)
            }) else { return false }
            meeting = row
        } catch {
            print("Retention sweep failed to read \(meetingId): \(error)")
            return false
        }
        guard meeting.statusEnum == .ready else { return false }
        return sweep(meeting: meeting, now: now)
    }

    /// Manual "Delete audio" on a meeting that still has files.
    @discardableResult
    static func deleteAudio(for meeting: MeetingRow) -> Bool {
        deleteAudioFiles(in: URL(fileURLWithPath: meeting.audioDir))
    }

    private static func sweep(meeting: MeetingRow, now: Date) -> Bool {
        guard let endedAt = meeting.endedAt else { return false }
        guard RetentionSettings.shouldDeleteAudio(
            endedAt: Date(timeIntervalSince1970: endedAt),
            isPinned: meeting.retentionPinned,
            isProcessed: meeting.statusEnum == .ready,
            now: now
        ) else { return false }

        let directory = URL(fileURLWithPath: meeting.audioDir)
        guard RecordingArtifacts.audioBytes(in: directory) > 0 else { return false }
        return deleteAudioFiles(in: directory)
    }

    /// Removes the WAVs but keeps the directory — its presence is how the
    /// library distinguishes "audio was swept" from "meeting never recorded".
    @discardableResult
    static func deleteAudioFiles(in directory: URL) -> Bool {
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
