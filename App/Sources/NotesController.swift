import Foundation
import Observation

@MainActor
@Observable
final class NotesController {
    var text: String = ""

    private let meetingId: String
    private let recordingStart: Date
    private var lineTimestamps: [Int: Int] = [:]
    private var saveTask: Task<Void, Never>?

    init(meetingId: String, recordingStart: Date) {
        self.meetingId = meetingId
        self.recordingStart = recordingStart
    }

    /// Called from `.onChange(of: text)` — captures a timestamp for any newly-non-empty line
    /// (the moment the thought was typed) and schedules a debounced save.
    func textChanged() {
        let lines = text.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() where !line.isEmpty && lineTimestamps[idx] == nil {
            let elapsed = max(0, Int(Date().timeIntervalSince(recordingStart) * 1000))
            lineTimestamps[idx] = elapsed
        }
        scheduleSave()
    }

    /// Force-persist immediately. Called when recording stops so the pipeline sees latest notes.
    func flush() async {
        saveTask?.cancel()
        await persist()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.persist()
        }
    }

    private func persist() async {
        let snapshot = text
        let timestamps = lineTimestamps
        let id = meetingId

        let lines = snapshot.components(separatedBy: "\n")
        let rows: [NoteEntryRow] = lines.enumerated().compactMap { idx, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            return NoteEntryRow(
                id: nil,
                meetingId: id,
                tsMs: timestamps[idx] ?? 0,
                text: trimmed,
                indentLevel: leading / 2,
                ord: idx
            )
        }

        do {
            try await Database.shared.write { db in
                try db.execute(
                    sql: "DELETE FROM note_entries WHERE meeting_id = ?",
                    arguments: [id]
                )
                for var row in rows {
                    try row.insert(db)
                }
            }
        } catch {
            print("NotesController: save failed: \(error)")
        }
    }
}
