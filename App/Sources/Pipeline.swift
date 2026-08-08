import Foundation
import GRDB
import MeetingCore
import MeetingProviders

extension Notification.Name {
    static let pipelineDidComplete = Notification.Name("pipelineDidComplete")
    static let pipelineDidFail = Notification.Name("pipelineDidFail")
    static let summarizationDidFail = Notification.Name("summarizationDidFail")
}

actor Pipeline {
    static let shared = Pipeline()

    /// Resolved per run so an engine change in Settings applies to the next
    /// meeting without a restart (E1.4).
    private var engine: TranscriptionEngine { TranscriptionEngines.current() }

    func process(meetingId: String) async {
        do {
            try await runStages(meetingId: meetingId)
            try await setStatus(meetingId, .ready)
            let title = (try? await fetchMeeting(meetingId).title) ?? "Meeting"
            await postNotification(.pipelineDidComplete, userInfo: ["meetingId": meetingId, "title": title])
        } catch {
            print("Pipeline failed for \(meetingId): \(error)")
            try? await setStatus(meetingId, .failed)
            let title = (try? await fetchMeeting(meetingId).title) ?? "Meeting"
            await postNotification(.pipelineDidFail, userInfo: [
                "meetingId": meetingId,
                "title": title,
                "error": error.localizedDescription
            ])
        }
    }

    private func postNotification(_ name: Notification.Name, userInfo: [String: Any]) async {
        await MainActor.run {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }

    private func runStages(meetingId: String) async throws {
        let meeting = try await fetchMeeting(meetingId)
        let dir = URL(fileURLWithPath: meeting.audioDir)
        let systemURL = dir.appendingPathComponent("system.wav")
        let micURL = dir.appendingPathComponent("mic.wav")
        let mixedURL = dir.appendingPathComponent("mixed.wav")

        try await setStatus(meetingId, .mixing)
        try await AudioMixer.mix(systemURL: systemURL, micURL: micURL, outputURL: mixedURL)

        try await setStatus(meetingId, .transcribing)
        let segments = try await engine.transcribe(
            audioURL: mixedURL,
            language: TranscriptionSettings.language,
            progress: nil
        )
        try await Database.shared.write { db in
            for seg in segments {
                var row = SegmentRow(
                    id: nil,
                    meetingId: meetingId,
                    startMs: seg.startMs,
                    endMs: seg.endMs,
                    text: seg.text
                )
                try row.insert(db)
            }
        }

        // Summarization is best-effort. With no provider configured — the state
        // of a clean Mac — the meeting still lands as `ready` with a transcript,
        // and the UI offers "Add a summarizer" (E1.6). A provider that errors
        // is likewise reported without discarding the transcript.
        let transcriptText = formatTranscript(segments)
        let notesText = try await fetchNotesText(meetingId)
        if let provider = await SummaryProviderRegistry.shared.resolveActive() {
            try await setStatus(meetingId, .summarizing)
            do {
                let result = try await provider.summarize(
                    SummaryRequest(
                        transcript: transcriptText,
                        notes: notesText,
                        template: SummaryTemplateStore.selected
                    )
                )
                try await store(result, for: meetingId)
            } catch {
                print("Summarization failed for \(meetingId): \(error)")
                await postNotification(.summarizationDidFail, userInfo: [
                    "meetingId": meetingId,
                    "error": error.localizedDescription
                ])
            }
        }

        try await rebuildFTS(for: meetingId)
    }

    /// Writes a generation and trims history to the last three (E2.5).
    func store(_ result: SummaryResult, for meetingId: String) async throws {
        try await Database.shared.write { db in
            var row = SummaryRow(
                id: nil,
                meetingId: meetingId,
                content: result.content,
                generatedAt: Date().timeIntervalSince1970,
                provider: result.providerID.rawValue,
                model: result.model,
                template: result.templateID
            )
            try row.insert(db)
            try SummaryRow.prune(db, meetingId: meetingId)
        }
        try await rebuildFTS(for: meetingId)
    }

    /// Re-runs summarization on an existing transcript — the "Regenerate" and
    /// per-meeting template-override paths (E2.6). History keeps the last 3
    /// generations, so this never clobbers anything silently.
    func regenerateSummary(meetingId: String, template: SummaryTemplate) async throws {
        let (provider, request) = try await preparedRequest(meetingId: meetingId, template: template)
        let result = try await provider.summarize(request)
        try await store(result, for: meetingId)
    }

    /// One-off generation that is shown but never stored — the "As follow-up
    /// email" sheet (E2.6). Deliberately bypasses `store` so an email draft
    /// can't displace a real summary in the generation history.
    func generateOneOff(meetingId: String, template: SummaryTemplate) async throws -> String {
        let (provider, request) = try await preparedRequest(meetingId: meetingId, template: template)
        return try await provider.summarize(request).content
    }

    private func preparedRequest(
        meetingId: String,
        template: SummaryTemplate
    ) async throws -> (SummaryProvider, SummaryRequest) {
        guard let provider = await SummaryProviderRegistry.shared.resolveActive() else {
            throw SummaryProviderError.notConfigured(.appleFoundationModels)
        }
        let transcript = try await Database.shared.read { db in
            try SegmentRow
                .filter(Column("meeting_id") == meetingId)
                .order(Column("start_ms"))
                .fetchAll(db)
        }
        let segments = transcript.map {
            TranscribedSegment(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }
        let request = SummaryRequest(
            transcript: formatTranscript(segments),
            notes: try await fetchNotesText(meetingId),
            template: template
        )
        return (provider, request)
    }

    // MARK: - DB helpers

    private func fetchMeeting(_ id: String) async throws -> MeetingRow {
        try await Database.shared.read { db in
            guard let row = try MeetingRow.fetchOne(db, key: id) else {
                throw NSError(domain: "Pipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meeting \(id) not found"])
            }
            return row
        }
    }

    private func fetchNotesText(_ meetingId: String) async throws -> String? {
        try await Database.shared.read { db in
            let notes = try NoteEntryRow
                .filter(Column("meeting_id") == meetingId)
                .order(Column("ord"))
                .fetchAll(db)
            guard !notes.isEmpty else { return nil }
            return notes.map { entry in
                let ts = formatTimestampMs(entry.tsMs)
                return "[\(ts) NOTE] \(entry.text)"
            }.joined(separator: "\n")
        }
    }

    private func setStatus(_ meetingId: String, _ status: MeetingStatus) async throws {
        try await Database.shared.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ? WHERE id = ?",
                arguments: [status.rawValue, meetingId]
            )
        }
    }

    private func rebuildFTS(for meetingId: String) async throws {
        try await Database.shared.write { db in
            try db.execute(
                sql: "DELETE FROM meetings_fts WHERE meeting_id = ?",
                arguments: [meetingId]
            )

            guard let meeting = try MeetingRow.fetchOne(db, key: meetingId) else { return }

            let segments = try SegmentRow
                .filter(Column("meeting_id") == meetingId)
                .order(Column("start_ms"))
                .fetchAll(db)
            let transcriptText = segments.map(\.text).joined(separator: " ")

            let notes = try NoteEntryRow
                .filter(Column("meeting_id") == meetingId)
                .order(Column("ord"))
                .fetchAll(db)
            let notesText = notes.map(\.text).joined(separator: " ")

            let summary = try SummaryRow.latest(db, meetingId: meetingId)?.content ?? ""

            try db.execute(
                sql: """
                INSERT INTO meetings_fts (meeting_id, title, transcript, notes, summary)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [meeting.id, meeting.title, transcriptText, notesText, summary]
            )
        }
    }

    private func formatTranscript(_ segments: [TranscribedSegment]) -> String {
        segments.map { seg in
            "[\(formatTimestampMs(seg.startMs)) TRANSCRIPT] \(seg.text)"
        }.joined(separator: "\n")
    }
}

func formatTimestampMs(_ ms: Int) -> String {
    let totalSeconds = ms / 1000
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
    let s = totalSeconds % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}
