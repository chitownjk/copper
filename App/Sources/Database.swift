import AppKit
import Foundation
import GRDB
import MeetingCore

enum Database {
    /// First touch happens on the main thread during `AppState.init`. On an
    /// unreadable store this blocks on a modal (same precedent as the crash-
    /// recovery prompt) instead of the old `fatalError` — a corrupt file, a
    /// full disk, or a bad migration used to kill the app with no message.
    static let shared: DatabaseQueue = open()

    private static func open() -> DatabaseQueue {
        let dbURL = Paths.applicationSupport.appendingPathComponent("meetings.sqlite")
        do {
            return try openAndMigrate(dbURL)
        } catch {
            switch promptForRecovery(error: error, dbURL: dbURL) {
            case .quit:
                exit(0)
            case .startFresh:
                moveAside(dbURL)
                do {
                    return try openAndMigrate(dbURL)
                } catch {
                    // A fresh file also failing means the problem is the
                    // location (permissions, disk), not the data.
                    presentFatal(error)
                    exit(1)
                }
            }
        }
    }

    private static func openAndMigrate(_ url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)
        return queue
    }

    private enum RecoveryChoice { case quit, startFresh }

    private static func promptForRecovery(error: Error, dbURL: URL) -> RecoveryChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Your meeting library can’t be opened"
        alert.informativeText = """
        The database at \(dbURL.path) couldn’t be read:

        \(error.localizedDescription)

        You can set the unreadable file aside and start with an empty library. \
        The old file is kept next to the new one, and your audio recordings \
        are not touched either way.
        """
        alert.addButton(withTitle: "Back Up and Start Fresh")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .startFresh : .quit
    }

    /// Preserves the unreadable store (plus SQLite sidecar files) under a
    /// timestamped name so support can attempt recovery later.
    private static func moveAside(_ dbURL: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: dbURL.path + ".unreadable-\(stamp)" + suffix)
            try? fm.moveItem(at: source, to: destination)
        }
    }

    private static func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Meeting library can’t be created"
        alert.informativeText = """
        Even a brand-new database couldn’t be created — this usually means the \
        disk is full or Application Support isn’t writable.

        \(error.localizedDescription)
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

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

        // Per-meeting override for the retention sweep (PRD A7).
        m.registerMigration("v3_retention_pin") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "retention_pinned", .boolean).notNull().defaults(to: false)
            }
        }

        return m
    }
}
