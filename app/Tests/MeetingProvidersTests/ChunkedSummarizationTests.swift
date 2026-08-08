import XCTest
@testable import MeetingProviders

final class ChunkedSummarizationTests: XCTestCase {
    private func transcript(lines: Int, lineLength: Int = 80) -> String {
        (0..<lines)
            .map { "[00:00:\(String(format: "%02d", $0 % 60)) TRANSCRIPT] " + String(repeating: "a", count: lineLength) }
            .joined(separator: "\n")
    }

    // MARK: - Splitting

    func testSplitKeepsChunksUnderBudget() {
        let text = transcript(lines: 200)
        let chunks = ChunkedSummarization.split(text, maxCharacters: 1_000)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 1_000)
        }
    }

    func testSplitNeverBreaksMidLine() {
        let text = transcript(lines: 50)
        let chunks = ChunkedSummarization.split(text, maxCharacters: 500)
        let original = text.split(separator: "\n").map(String.init)
        let roundTripped = chunks.flatMap { $0.split(separator: "\n").map(String.init) }

        XCTAssertEqual(roundTripped, original, "every line must survive intact")
    }

    func testOverlongSingleLineIsEmittedWholeRatherThanSliced() {
        let line = String(repeating: "x", count: 5_000)
        let chunks = ChunkedSummarization.split(line, maxCharacters: 100)

        XCTAssertEqual(chunks, [line])
    }

    // MARK: - Single pass vs map-reduce

    func testShortTranscriptTakesTheSinglePassPath() async throws {
        let calls = CallLog()
        let generator = TextGenerator { system, _ in
            await calls.record(system)
            return "summary"
        }

        let result = try await ChunkedSummarization.run(
            request: SummaryRequest(transcript: "a short meeting", template: .general),
            contextCharacterBudget: 10_000,
            generator: generator
        )

        XCTAssertEqual(result, "summary")
        let recorded = await calls.entries
        XCTAssertEqual(recorded.count, 1, "no map-reduce for a short transcript")
        XCTAssertEqual(recorded[0], SummaryTemplate.general.systemPrompt)
    }

    func testLongTranscriptMapsThenReduces() async throws {
        let calls = CallLog()
        let generator = TextGenerator { system, _ in
            await calls.record(system)
            return "partial"
        }

        let result = try await ChunkedSummarization.run(
            request: SummaryRequest(transcript: transcript(lines: 100), template: .standup),
            contextCharacterBudget: 2_000,
            generator: generator
        )

        XCTAssertEqual(result, "partial")
        let recorded = await calls.entries
        XCTAssertGreaterThan(recorded.count, 2, "expected several map calls plus one reduce")

        let mapCalls = recorded.dropLast()
        for call in mapCalls {
            XCTAssertTrue(call.contains("intermediate artifact"), "map calls use the extraction prompt")
        }
        let reduceCall = recorded.last!
        XCTAssertTrue(reduceCall.contains("Per Person"), "reduce call carries the requested template")
        XCTAssertTrue(reduceCall.contains("per-section"), "reduce call explains the input shape")
    }

    func testNotesAreWrappedAlongsideTheTranscript() {
        let composed = ChunkedSummarization.compose(
            transcript: "[00:00:01 TRANSCRIPT] hello",
            notes: "[00:00:02 NOTE] follow up with Dana"
        )
        XCTAssertTrue(composed.contains("<notes>"))
        XCTAssertTrue(composed.contains("<transcript>"))
        XCTAssertTrue(composed.contains("follow up with Dana"))
    }

    func testTranscriptOnlyIsPassedThroughUnwrapped() {
        let composed = ChunkedSummarization.compose(transcript: "just this", notes: nil)
        XCTAssertEqual(composed, "just this")
    }

    /// A transcript so long its own partials overflow must still converge
    /// rather than throwing or looping forever.
    func testPartialsThatOverflowAreFoldedAgain() async throws {
        let calls = CallLog()
        let generator = TextGenerator { _, _ in
            await calls.record("call")
            let count = await calls.entries.count
            // Emit bulky partials for the first round so the reduce input
            // overflows, then collapse.
            return count < 12 ? String(repeating: "p", count: 400) : "final"
        }

        let result = try await ChunkedSummarization.run(
            request: SummaryRequest(transcript: transcript(lines: 120), template: .general),
            contextCharacterBudget: 1_500,
            generator: generator
        )

        XCTAssertEqual(result, "final")
    }
}

private actor CallLog {
    private(set) var entries: [String] = []
    func record(_ value: String) { entries.append(value) }
}
