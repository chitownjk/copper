import XCTest
@testable import MeetingProviders

/// Response parsing and error mapping for the Messages API. Network calls are
/// not exercised here — these are the branches that decide what the user sees.
final class AnthropicProviderTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: - Parsing

    func testJoinsTextBlocks() throws {
        let data = json([
            "stop_reason": "end_turn",
            "content": [
                ["type": "text", "text": "**TL;DR** "],
                ["type": "text", "text": "We shipped it."]
            ]
        ])
        XCTAssertEqual(try AnthropicProvider.parseMessage(data), "**TL;DR** We shipped it.")
    }

    func testIgnoresNonTextBlocks() throws {
        let data = json([
            "content": [
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": "summary"]
            ]
        ])
        XCTAssertEqual(try AnthropicProvider.parseMessage(data), "summary")
    }

    /// A classifier decline arrives as HTTP 200 with empty content — reading
    /// `content[0]` first would surface as an empty summary instead of a reason.
    func testRefusalIsSurfacedBeforeContentIsRead() {
        let data = json([
            "stop_reason": "refusal",
            "stop_details": ["type": "refusal", "category": "cyber", "explanation": "policy decline"],
            "content": []
        ])
        XCTAssertThrowsError(try AnthropicProvider.parseMessage(data)) { error in
            guard case SummaryProviderError.refused(let detail) = error else {
                return XCTFail("expected .refused, got \(error)")
            }
            XCTAssertEqual(detail, "policy decline")
        }
    }

    func testRefusalWithoutExplanationFallsBackToCategory() {
        let data = json([
            "stop_reason": "refusal",
            "stop_details": ["category": "bio"],
            "content": []
        ])
        XCTAssertThrowsError(try AnthropicProvider.parseMessage(data)) { error in
            guard case SummaryProviderError.refused(let detail) = error else {
                return XCTFail("expected .refused, got \(error)")
            }
            XCTAssertEqual(detail, "bio")
        }
    }

    func testEmptyContentThrows() {
        let data = json(["stop_reason": "end_turn", "content": []])
        XCTAssertThrowsError(try AnthropicProvider.parseMessage(data)) { error in
            guard case SummaryProviderError.emptyResponse = error else {
                return XCTFail("expected .emptyResponse, got \(error)")
            }
        }
    }

    func testGarbageBodyThrowsRequestFailed() {
        XCTAssertThrowsError(try AnthropicProvider.parseMessage(Data("not json".utf8))) { error in
            guard case SummaryProviderError.requestFailed = error else {
                return XCTFail("expected .requestFailed, got \(error)")
            }
        }
    }

    // MARK: - Error mapping

    func testUnauthorizedMapsToInvalidKey() {
        let body = json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])
        let error = AnthropicProvider.error(status: 401, headers: response(status: 401), data: body)

        guard case SummaryProviderError.invalidKey(let detail) = error else {
            return XCTFail("expected .invalidKey, got \(error)")
        }
        XCTAssertEqual(detail, "invalid x-api-key")
        XCTAssertFalse(error.isRetryable)
    }

    func testRateLimitCarriesRetryAfter() {
        let error = AnthropicProvider.error(
            status: 429,
            headers: response(status: 429, headers: ["retry-after": "30"]),
            data: json(["error": ["message": "rate_limit_error"]])
        )
        guard case SummaryProviderError.rateLimited(let retryAfter) = error else {
            return XCTFail("expected .rateLimited, got \(error)")
        }
        XCTAssertEqual(retryAfter, 30)
        XCTAssertTrue(error.isRetryable)
    }

    func testServerErrorsAreRetryableAndClientErrorsAreNot() {
        let overloaded = AnthropicProvider.error(
            status: 529,
            headers: response(status: 529),
            data: json(["error": ["message": "overloaded_error"]])
        )
        XCTAssertTrue(overloaded.isRetryable)

        let badRequest = AnthropicProvider.error(
            status: 400,
            headers: response(status: 400),
            data: json(["error": ["message": "max_tokens too large"]])
        )
        XCTAssertFalse(badRequest.isRetryable)
    }

    // MARK: - Configuration

    func testDefaultModelIsInTheCatalogAndSupportsEffort() {
        let model = AnthropicProvider.models.first { $0.id == AnthropicProvider.defaultModelID }
        XCTAssertNotNil(model)
        XCTAssertTrue(model!.supportsEffort)
    }

    /// `output_config.effort` is rejected by models that don't implement it, so
    /// the catalog flag has to stay honest.
    func testHaikuIsMarkedAsNotSupportingEffort() {
        let haiku = AnthropicProvider.models.first { $0.id == "claude-haiku-4-5" }
        XCTAssertEqual(haiku?.supportsEffort, false)
    }

    func testPrivacyLabelNamesTheRecipient() {
        XCTAssertEqual(
            AnthropicProvider().privacyLabel.description,
            "Transcript is sent to Anthropic"
        )
    }
}

final class OpenAICompatibleParsingTests: XCTestCase {
    func testParsesChoiceContent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": "summary text"]]]
        ])
        XCTAssertEqual(try OpenAICompatibleClient.parseCompletion(data), "summary text")
    }

    func testEmptyChoicesThrows() throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": []])
        XCTAssertThrowsError(try OpenAICompatibleClient.parseCompletion(data)) { error in
            guard case SummaryProviderError.emptyResponse = error else {
                return XCTFail("expected .emptyResponse, got \(error)")
            }
        }
    }
}

final class SummaryTemplateTests: XCTestCase {
    func testBuiltInIDsAreStableAndUnique() {
        let ids = SummaryTemplate.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["general", "one-on-one", "standup", "sales-call", "interview"])
    }

    func testEveryBuiltInExplainsTheNotesTranscriptFormat() {
        for template in SummaryTemplate.builtIns {
            XCTAssertTrue(
                template.systemPrompt.contains("[HH:MM:SS NOTE]"),
                "\(template.id) must tell the model how to read interleaved notes"
            )
        }
    }
}
