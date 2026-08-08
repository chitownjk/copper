import Foundation
import GRDB
import MeetingCore

enum Database {
    static let shared: DatabaseQueue = {
        do {
            let dbURL = Paths.applicationSupport.appendingPathComponent("meetings.sqlite")
            let queue = try DatabaseQueue(path: dbURL.path)
            try migrator.migrate(queue)
            return queue
        } catch {
            fatalError("Database init failed: \(error)")
        }
    }()

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "meetings") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "Untitled meeting")
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("calendar_event_id", .text)
                t.column("audio_dir", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "recording")
            }

            try db.create(table: "segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(index: "idx_segments_meeting", on: "segments", columns: ["meeting_id", "start_ms"])

            try db.create(table: "note_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("ts_ms", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("indent_level", .integer).notNull().defaults(to: 0)
                t.column("ord", .integer).notNull()
            }
            try db.create(index: "idx_notes_meeting", on: "note_entries", columns: ["meeting_id", "ord"])

            try db.create(table: "summaries") { t in
                t.column("meeting_id", .text).primaryKey()
                    .references("meetings", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("generated_at", .double).notNull()
            }

            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.column("meeting_id")
                t.column("title")
                t.column("transcript")
                t.column("notes")
                t.column("summary")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        // Summaries become multi-row per meeting so "regenerate" keeps history
        // (E2.5), and each row records which provider and template produced it
        // (E2.1). Existing rows survive with NULL provenance.
        m.registerMigration("v2_summary_provenance") { db in
            try db.create(table: "summaries_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("generated_at", .double).notNull()
                t.column("provider", .text)
                t.column("model", .text)
                t.column("template", .text)
            }
            try db.execute(sql: """
                INSERT INTO summaries_new (meeting_id, content, generated_at)
                SELECT meeting_id, content, generated_at FROM summaries
                """)
            try db.drop(table: "summaries")
            try db.rename(table: "summaries_new", to: "summaries")
            try db.create(
                index: "idx_summaries_meeting",
                on: "summaries",
                columns: ["meeting_id", "generated_at"]
            )
        }

        return m
    }
}
