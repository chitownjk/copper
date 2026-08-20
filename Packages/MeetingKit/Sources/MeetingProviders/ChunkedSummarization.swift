import Foundation

/// One model round-trip: system prompt in, text out.
public struct TextGenerator: Sendable {
    public let generate: @Sendable (_ system: String, _ user: String) async throws -> String

    public init(generate: @escaping @Sendable (_ system: String, _ user: String) async throws -> String) {
        self.generate = generate
    }
}

/// Map-reduce over long transcripts so a two-hour meeting doesn't overflow a
/// provider's context window (E2.3).
///
/// Short meetings — the overwhelming majority — take the single-pass path and
/// pay nothing for this. Only when the transcript exceeds the budget do we
/// split on line boundaries, summarize each chunk, then reduce the partials
/// into one summary in the requested template's shape.
public enum ChunkedSummarization {
    /// Rough characters-per-token for English prose. Used only to decide when
    /// to chunk, so an approximation is fine — we stay well clear of real limits.
    public static let charactersPerToken = 4

    public static func run(
        request: SummaryRequest,
        contextCharacterBudget: Int,
        generator: TextGenerator
    ) async throws -> String {
        let body = compose(transcript: request.transcript, notes: request.notes)

        if body.count <= contextCharacterBudget {
            let single = try await generator.generate(request.template.systemPrompt, body)
            return SummarySanitizer.clean(single)
        }

        let chunks = split(body, maxCharacters: contextCharacterBudget)
        var partials: [String] = []
        partials.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let raw = try await generator.generate(
                mapPrompt(part: index + 1, of: chunks.count),
                chunk
            )
            let partial = SummarySanitizer.clean(raw)
            // Do not label these "## Part N of M". On-device models copy that
            // heading into the user-visible summary and skip the merge.
            partials.append(
                "<extract n=\"\(index + 1)\" of=\"\(chunks.count)\">\n\(partial)\n</extract>"
            )
        }

        let joined = partials.joined(separator: "\n\n")

        // Pathological case: even the partials don't fit. Fold them pairwise
        // until they do rather than failing the whole pipeline.
        if joined.count > contextCharacterBudget {
            return try await run(
                request: SummaryRequest(transcript: joined, notes: nil, template: request.template),
                contextCharacterBudget: contextCharacterBudget,
                generator: generator
            )
        }

        var merged = SummarySanitizer.clean(
            try await generator.generate(reducePrompt(request.template), joined)
        )
        if SummarySanitizer.looksUnmerged(merged) {
            merged = SummarySanitizer.clean(
                try await generator.generate(reducePrompt(request.template), merged)
            )
        }
        return merged
    }

    // MARK: - Internals

    static func compose(transcript: String, notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return transcript }
        return """
        <notes>
        \(notes)
        </notes>

        <transcript>
        \(transcript)
        </transcript>
        """
    }

    /// Splits on line boundaries so a chunk never cuts a spoken segment in half.
    /// A single line longer than the budget is emitted whole rather than sliced
    /// mid-word — providers handle slight overage better than mangled text.
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        precondition(maxCharacters > 0)
        var chunks: [String] = []
        var current = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(line) : current + "\n" + line
            if candidate.count <= maxCharacters {
                current = candidate
                continue
            }
            if !current.isEmpty {
                chunks.append(current)
            }
            current = String(line)
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func mapPrompt(part: Int, of total: Int) -> String {
        """
        You are reading part \(part) of \(total) of a long meeting transcript. \
        Lines prefixed [HH:MM:SS NOTE] are the user's own notes and carry \
        editorial weight; [HH:MM:SS TRANSCRIPT] lines are recorded speech.

        Extract, as terse markdown bullets, only what a summarizer would need \
        from this section: decisions, action items with owners, open questions, \
        and any quote worth keeping verbatim. Preserve timestamps on anything \
        time-sensitive. Do not write an introduction or a conclusion — this is \
        an intermediate artifact, not a finished summary.

        Do not use section headings (no TL;DR, Key Decisions, Action Items, \
        or "Part \(part) of \(total)"). Unlabeled bullets only. Never repeat \
        a word back-to-back.
        """
    }

    static func reducePrompt(_ template: SummaryTemplate) -> String {
        """
        \(template.systemPrompt)

        The input below is not a raw transcript: it is a set of per-section \
        extracts from one long meeting, in chronological order. Merge them into \
        a single summary in the format above. Deduplicate items that appear in \
        more than one section, and resolve contradictions in favour of the later \
        section — the meeting may have changed its mind.

        Output exactly one summary. Never emit "Part 1 of N" headings. Never \
        write more than one TL;DR. If the input already looks like finished \
        summaries, merge them — do not concatenate them. Quotes are one \
        sentence each; never repeat a word.
        """
    }
}
