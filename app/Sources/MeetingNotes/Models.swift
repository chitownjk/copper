import Foundation
import GRDB

enum MeetingStatus: String, Codable {
    case recording
    case mixing
    case transcribing
    case summarizing
    case ready
    case failed
}

struct MeetingRow: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "meetings"

    var id: String
    var title: String
    var startedAt: Double
    var endedAt: Double?
    var source: String
    var calendarEventId: String?
    var audioDir: String
    var status: String

    enum CodingKeys: String, CodingKey {
        case id, title
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case source
        case calendarEventId = "calendar_event_id"
        case audioDir = "audio_dir"
        case status
    }

    var statusEnum: MeetingStatus {
        MeetingStatus(rawValue: status) ?? .failed
    }
}

struct SegmentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "segments"

    var id: Int64?
    var meetingId: String
    var startMs: Int
    var endMs: Int
    var text: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct NoteEntryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "note_entries"

    var id: Int64?
    var meetingId: String
    var tsMs: Int
    var text: String
    var indentLevel: Int
    var ord: Int

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case tsMs = "ts_ms"
        case text
        case indentLevel = "indent_level"
        case ord
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct SummaryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "summaries"

    var id: Int64?
    var meetingId: String
    var content: String
    var generatedAt: Double
    /// `SummaryProviderID` raw value. Nullable for rows written by the old
    /// claude-CLI path before the provider layer existed.
    var provider: String?
    var model: String?
    /// `SummaryTemplate.id`.
    var template: String?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case content
        case generatedAt = "generated_at"
        case provider
        case model
        case template
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Summaries are multi-row now (regenerate keeps history — E2.5), so
    /// "the summary" always means the newest one.
    static func latest(_ db: GRDB.Database, meetingId: String) throws -> SummaryRow? {
        try SummaryRow
            .filter(Column("meeting_id") == meetingId)
            .order(Column("generated_at").desc, Column("id").desc)
            .fetchOne(db)
    }

    static func history(_ db: GRDB.Database, meetingId: String) throws -> [SummaryRow] {
        try SummaryRow
            .filter(Column("meeting_id") == meetingId)
            .order(Column("generated_at").desc, Column("id").desc)
            .fetchAll(db)
    }

    /// Keeps the newest `limit` generations and deletes the rest.
    static func prune(_ db: GRDB.Database, meetingId: String, keeping limit: Int = 3) throws {
        let ids = try history(db, meetingId: meetingId).compactMap(\.id)
        guard ids.count > limit else { return }
        let stale = ids.dropFirst(limit)
        try db.execute(
            sql: "DELETE FROM summaries WHERE id IN (\(stale.map { _ in "?" }.joined(separator: ",")))",
            arguments: StatementArguments(Array(stale))
        )
    }
}
