import Foundation
import GRDB

enum MeetingSearch {
    /// Returns meeting IDs ranked by FTS5 bm25 relevance for the given query.
    /// An empty/whitespace query returns nil (caller should show all meetings unfiltered).
    static func search(_ query: String) async throws -> [String]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let matchExpr = ftsMatchExpression(trimmed)

        return try await Database.shared.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT meeting_id FROM meetings_fts
                WHERE meetings_fts MATCH ?
                ORDER BY bm25(meetings_fts)
                """,
                arguments: [matchExpr]
            )
        }
    }

    /// FTS5 doesn't tolerate raw user input — wrap each token as a prefix match,
    /// quote anything with non-alphanumerics, and join with spaces (implicit AND).
    private static func ftsMatchExpression(_ raw: String) -> String {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
        return tokens.map { token -> String in
            let safe = token.replacingOccurrences(of: "\"", with: "")
            return "\"\(safe)\"*"
        }.joined(separator: " ")
    }
}
