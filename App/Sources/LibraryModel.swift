import Foundation
import Observation
import GRDB

@MainActor
@Observable
final class LibraryModel {
    var allMeetings: [MeetingRow] = []
    var searchQuery: String = ""
    var searchResultIds: Set<String>? = nil // nil == no active filter
    var selectedMeetingId: String?

    var detailSummary: String = ""
    var detailNotes: [NoteEntryRow] = []
    var detailSegments: [SegmentRow] = []

    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    init() {
        startObservingMeetings()
    }

    var visibleMeetings: [MeetingRow] {
        guard let ids = searchResultIds else { return allMeetings }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return allMeetings
            .filter { ids.contains($0.id) }
            .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    var selectedMeeting: MeetingRow? {
        guard let id = selectedMeetingId else { return nil }
        return allMeetings.first(where: { $0.id == id })
    }

    func searchChanged() {
        searchTask?.cancel()
        let query = searchQuery
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let ids = try await MeetingSearch.search(query)
                if Task.isCancelled { return }
                self?.searchResultIds = ids.map(Set.init)
            } catch {
                print("Library search failed: \(error)")
            }
        }
    }

    func selectMeeting(_ id: String?) {
        selectedMeetingId = id
        loadDetail(for: id)
    }

    func renameSelected(to newTitle: String) async {
        guard let id = selectedMeetingId else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await Database.shared.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET title = ? WHERE id = ?",
                    arguments: [trimmed, id]
                )
                try db.execute(
                    sql: "UPDATE meetings_fts SET title = ? WHERE meeting_id = ?",
                    arguments: [trimmed, id]
                )
            }
        } catch {
            print("Rename failed: \(error)")
        }
    }

    func deleteSelected() async {
        guard let id = selectedMeetingId else { return }
        do {
            try await Database.shared.write { db in
                try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM note_entries WHERE meeting_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM summaries WHERE meeting_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM meetings_fts WHERE meeting_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
            }
            selectedMeetingId = nil
            detailSummary = ""
            detailNotes = []
            detailSegments = []
        } catch {
            print("Delete failed: \(error)")
        }
    }

    private func loadDetail(for id: String?) {
        detailTask?.cancel()
        guard let id else {
            detailSummary = ""
            detailNotes = []
            detailSegments = []
            return
        }
        detailTask = Task { [weak self] in
            do {
                let (summary, notes, segments) = try await Database.shared.read { db -> (String, [NoteEntryRow], [SegmentRow]) in
                    let summary = try SummaryRow.latest(db, meetingId: id)?.content ?? ""
                    let notes = try NoteEntryRow
                        .filter(Column("meeting_id") == id)
                        .order(Column("ord"))
                        .fetchAll(db)
                    let segments = try SegmentRow
                        .filter(Column("meeting_id") == id)
                        .order(Column("start_ms"))
                        .fetchAll(db)
                    return (summary, notes, segments)
                }
                if Task.isCancelled { return }
                self?.detailSummary = summary
                self?.detailNotes = notes
                self?.detailSegments = segments
            } catch {
                print("Detail load failed: \(error)")
            }
        }
    }

    private func startObservingMeetings() {
        let observation = ValueObservation.tracking { db in
            try MeetingRow
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
        observationTask = Task { [weak self] in
            do {
                for try await meetings in observation.values(in: Database.shared) {
                    await MainActor.run {
                        guard let self else { return }
                        self.allMeetings = meetings
                        if let id = self.selectedMeetingId {
                            self.loadDetail(for: id)
                        }
                    }
                }
            } catch {
                print("Library meeting observation error: \(error)")
            }
        }
    }
}
