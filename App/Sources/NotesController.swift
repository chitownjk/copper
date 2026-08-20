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
            guard let parsed = Self.parseLine(line) else { return nil }
            return NoteEntryRow(
                id: nil,
                meetingId: id,
                tsMs: timestamps[idx] ?? 0,
                text: parsed.text,
                indentLevel: parsed.indent,
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

    /// Leading spaces/tabs become indent (tab = 2 spaces). A leading `- ` or `* `
    /// is a list marker, not part of the saved text, so the library does not
    /// render "• - item".
    static func parseLine(_ line: String) -> (text: String, indent: Int)? {
        var spaces = 0
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == " " {
                spaces += 1
            } else if ch == "\t" {
                spaces += 2
            } else {
                break
            }
            index = line.index(after: index)
        }
        var rest = String(line[index...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if rest == "-" || rest == "*" {
            return nil
        }
        guard !rest.isEmpty else { return nil }
        return (rest, spaces / 2)
    }
}
