import Foundation

/// A summarization style: a system prompt plus the sections it asks for.
/// `id` is persisted on the `summaries` row — don't rename built-in ids.
public struct SummaryTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let systemPrompt: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, systemPrompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.isBuiltIn = isBuiltIn
    }
}

public extension SummaryTemplate {
    /// Shared preamble: how to read the interleaved notes/transcript format the
    /// pipeline produces, and the length ceiling.
    private static let format = """
    The input may include lines prefixed with [HH:MM:SS NOTE] (the user's own \
    bullet points) interleaved with [HH:MM:SS TRANSCRIPT] (the recorded speech). \
    Notes carry editorial weight — surface what the user flagged.

    Output markdown. Keep total output under 400 words. If a section has nothing \
    meaningful, omit it entirely rather than writing "none".
    """

    static let general = SummaryTemplate(
        id: "general",
        name: "General",
        systemPrompt: """
        You are summarizing a meeting transcript. \(format)

        Sections:
        - **TL;DR** — 2 sentences
        - **Key Decisions**
        - **Action Items** — with owner if mentioned
        - **Open Questions**
        - **Notable Quotes**
        """,
        isBuiltIn: true
    )

    static let oneOnOne = SummaryTemplate(
        id: "one-on-one",
        name: "1:1",
        systemPrompt: """
        You are summarizing a 1:1 between a manager and a report. \(format)

        Sections:
        - **TL;DR** — 2 sentences
        - **Topics Discussed**
        - **Commitments** — who owes what, by when
        - **Blockers & Support Needed**
        - **Follow Up Next Time**
        """,
        isBuiltIn: true
    )

    static let standup = SummaryTemplate(
        id: "standup",
        name: "Standup",
        systemPrompt: """
        You are summarizing a team standup. \(format)

        Sections:
        - **Per Person** — a line each: what shipped, what's next, what's blocked
        - **Blockers Needing Escalation**
        - **Decisions**
        """,
        isBuiltIn: true
    )

    static let salesCall = SummaryTemplate(
        id: "sales-call",
        name: "Sales call",
        systemPrompt: """
        You are summarizing a sales call. \(format)

        Sections:
        - **TL;DR** — 2 sentences
        - **Prospect Context** — company, role, current setup
        - **Pain Points & Objections**
        - **Requirements Mentioned**
        - **Next Steps** — with owner and date if stated
        """,
        isBuiltIn: true
    )

    static let interview = SummaryTemplate(
        id: "interview",
        name: "Interview",
        systemPrompt: """
        You are summarizing a job interview. Stay factual and quote the candidate \
        where it matters; do not infer traits that weren't demonstrated. \(format)

        Sections:
        - **TL;DR** — 2 sentences
        - **Background Covered**
        - **Signals Observed** — with the evidence for each
        - **Candidate's Questions**
        - **Open Areas To Probe**
        """,
        isBuiltIn: true
    )

    static let builtIns: [SummaryTemplate] = [
        .general, .oneOnOne, .standup, .salesCall, .interview
    ]

    static func builtIn(id: String) -> SummaryTemplate? {
        builtIns.first { $0.id == id }
    }
}

/// Built-ins plus any custom templates the user wrote. Custom templates live in
/// UserDefaults as JSON — they're small, and this avoids a schema migration.
public enum SummaryTemplateStore {
    private static let customKey = "summaryTemplatesCustom"
    private static let selectedKey = "summaryTemplateSelected"

    public static var custom: [SummaryTemplate] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customKey),
                  let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let sanitized = newValue.map {
                SummaryTemplate(id: $0.id, name: $0.name, systemPrompt: $0.systemPrompt, isBuiltIn: false)
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(sanitized), forKey: customKey)
        }
    }

    public static var all: [SummaryTemplate] {
        SummaryTemplate.builtIns + custom
    }

    public static func template(id: String) -> SummaryTemplate? {
        all.first { $0.id == id }
    }

    /// The template new meetings use unless overridden per-meeting.
    public static var selected: SummaryTemplate {
        get {
            let id = UserDefaults.standard.string(forKey: selectedKey) ?? SummaryTemplate.general.id
            return template(id: id) ?? .general
        }
        set { UserDefaults.standard.set(newValue.id, forKey: selectedKey) }
    }
}
