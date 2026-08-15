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

    // MARK: Quick-action templates (E2.6)
    //
    // Not in `builtIns` — they're verbs on an existing meeting, not default
    // styles a user picks in Settings. Their ids still land on summary rows
    // ("shorter") or nowhere ("follow-up-email" output is never stored).

    static let shorter = SummaryTemplate(
        id: "shorter",
        name: "Shorter",
        systemPrompt: """
        You are condensing a meeting transcript to its bare minimum. \(format)

        Hard cap: 120 words total, overriding any other length guidance.
        Sections:
        - **TL;DR** — 1–2 sentences
        - **Action Items** — with owner if mentioned
        Nothing else.
        """,
        isBuiltIn: true
    )

    static let followUpEmail = SummaryTemplate(
        id: "follow-up-email",
        name: "Follow-up email",
        systemPrompt: """
        Write a follow-up email for this meeting, ready to paste into a mail \
        client. \(format)

        Format:
        - First line: "Subject: " and a specific subject
        - A one-line greeting to the attendees (no invented names)
        - A short paragraph of what was decided
        - Bulleted action items with owners if mentioned
        - A sign-off placeholder on its own line: [Your name]
        Plain text, not markdown headings. Keep it under 200 words.
        """,
        isBuiltIn: true
    )

    static let quickActions: [SummaryTemplate] = [.shorter, .followUpEmail]
}

/// Built-ins plus any custom templates the user wrote. Custom templates live in
/// UserDefaults as JSON — they're small, and this avoids a schema migration.
/// Built-in name/prompt rewrites are stored separately so the shipped defaults
/// stay in the binary as Reset targets.
public enum SummaryTemplateStore {
    private static let customKey = "summaryTemplatesCustom"
    private static let selectedKey = "summaryTemplateSelected"
    private static let overridesKey = "summaryTemplateOverrides"

    private struct BuiltInOverride: Codable, Equatable {
        var name: String
        var systemPrompt: String
    }

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

    private static var builtInOverrides: [String: BuiltInOverride] {
        get {
            guard let data = UserDefaults.standard.data(forKey: overridesKey),
                  let decoded = try? JSONDecoder().decode([String: BuiltInOverride].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: overridesKey)
            } else {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: overridesKey)
            }
        }
    }

    /// Shipped built-ins with any persisted name/prompt rewrite applied.
    public static var builtInsResolved: [SummaryTemplate] {
        SummaryTemplate.builtIns.map(applyingOverride)
    }

    public static var all: [SummaryTemplate] {
        builtInsResolved + custom
    }

    public static func template(id: String) -> SummaryTemplate? {
        (all + SummaryTemplate.quickActions).first { $0.id == id }
    }

    /// The template new meetings use unless overridden per-meeting.
    public static var selected: SummaryTemplate {
        get {
            let id = UserDefaults.standard.string(forKey: selectedKey) ?? SummaryTemplate.general.id
            return template(id: id) ?? applyingOverride(.general)
        }
        set { UserDefaults.standard.set(newValue.id, forKey: selectedKey) }
    }

    public static func isBuiltInOverridden(id: String) -> Bool {
        builtInOverrides[id] != nil
    }

    /// Persist a rewrite of a shipped built-in. Saving the original name and
    /// prompt is treated as Reset so an unchanged Save does not leave a stale
    /// "Edited" badge.
    public static func saveBuiltInOverride(id: String, name: String, systemPrompt: String) {
        guard let original = SummaryTemplate.builtIn(id: id) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !systemPrompt.isEmpty else { return }
        if name == original.name && systemPrompt == original.systemPrompt {
            resetBuiltInOverride(id: id)
            return
        }
        var overrides = builtInOverrides
        overrides[id] = BuiltInOverride(name: name, systemPrompt: systemPrompt)
        builtInOverrides = overrides
    }

    public static func resetBuiltInOverride(id: String) {
        var overrides = builtInOverrides
        overrides.removeValue(forKey: id)
        builtInOverrides = overrides
    }

    private static func applyingOverride(_ template: SummaryTemplate) -> SummaryTemplate {
        guard template.isBuiltIn, let override = builtInOverrides[template.id] else {
            return template
        }
        return SummaryTemplate(
            id: template.id,
            name: override.name,
            systemPrompt: override.systemPrompt,
            isBuiltIn: true
        )
    }
}
