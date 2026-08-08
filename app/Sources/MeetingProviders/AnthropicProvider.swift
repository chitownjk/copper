import Foundation

/// Bring-your-own-key summarization via the Anthropic Messages API.
///
/// Raw `URLSession` rather than an SDK: Anthropic ships no first-party Swift
/// SDK, and the Messages API surface we need here is one POST.
public struct AnthropicProvider: SummaryProvider {
    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        /// `output_config.effort` is only accepted on models that implement it.
        public let supportsEffort: Bool
        /// Conservative slice of the context window to hand a single request,
        /// in characters. Chunking kicks in past this.
        public let contextCharacterBudget: Int
    }

    public static let models: [Model] = [
        Model(
            id: "claude-sonnet-5",
            displayName: "Claude Sonnet 5",
            supportsEffort: true,
            contextCharacterBudget: 600_000
        ),
        Model(
            id: "claude-opus-5",
            displayName: "Claude Opus 5",
            supportsEffort: true,
            contextCharacterBudget: 600_000
        ),
        Model(
            id: "claude-haiku-4-5",
            displayName: "Claude Haiku 4.5",
            supportsEffort: false,
            contextCharacterBudget: 120_000
        )
    ]

    public static let defaultModelID = "claude-sonnet-5"

    public static var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: "anthropicModelID") ?? defaultModelID }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicModelID") }
    }

    static var selectedModel: Model {
        models.first { $0.id == selectedModelID } ?? models[0]
    }

    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public nonisolated var id: SummaryProviderID { .anthropic }
    public nonisolated var displayName: String { "Anthropic (your API key)" }
    public nonisolated var privacyLabel: SummaryPrivacyLabel { .sentTo("Anthropic") }

    public func requirement() async -> SummaryProviderRequirement {
        KeychainStore.has(.anthropic) ? .none : .apiKey
    }

    /// Cheap round-trip that proves the key works without spending output
    /// tokens. Called at save time so a bad key surfaces inline (E2.3 AC).
    public func validateConfiguration() async throws {
        guard let key = KeychainStore.get(.anthropic) else {
            throw SummaryProviderError.notConfigured(.anthropic)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        _ = try await perform(request)
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryResult {
        guard let key = KeychainStore.get(.anthropic) else {
            throw SummaryProviderError.notConfigured(.anthropic)
        }
        let model = Self.selectedModel

        let generator = TextGenerator { system, user in
            try await self.complete(system: system, user: user, model: model, key: key)
        }
        let content = try await ChunkedSummarization.run(
            request: request,
            contextCharacterBudget: model.contextCharacterBudget,
            generator: generator
        )

        return SummaryResult(
            content: content,
            providerID: .anthropic,
            model: model.id,
            templateID: request.template.id
        )
    }

    // MARK: - Messages API

    private func complete(system: String, user: String, model: Model, key: String) async throws -> String {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 8_192,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        // Summarization is not a reasoning-heavy task; low effort keeps latency
        // and spend down. Sampling parameters are rejected on current models —
        // steer with the template prompt instead.
        if model.supportsEffort {
            body["output_config"] = ["effort": "low"]
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let data = try await perform(request)
        return try Self.parseMessage(data)
    }

    static func parseMessage(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.requestFailed("Unreadable response from Anthropic.")
        }

        // Check stop_reason before touching content: a classifier decline
        // returns HTTP 200 with an empty or partial content array.
        if let stopReason = object["stop_reason"] as? String, stopReason == "refusal" {
            let details = object["stop_details"] as? [String: Any]
            let explanation = details?["explanation"] as? String
                ?? details?["category"] as? String
                ?? "no reason given"
            throw SummaryProviderError.refused(explanation)
        }

        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw SummaryProviderError.emptyResponse }
        return text
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SummaryProviderError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SummaryProviderError.requestFailed("Malformed response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, headers: http, data: data)
        }
        return data
    }

    static func error(status: Int, headers: HTTPURLResponse, data: Data) -> SummaryProviderError {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: data, encoding: .utf8)?.prefix(300).description
            ?? "unknown error"

        switch status {
        case 401, 403:
            return .invalidKey(message)
        case 429:
            let retryAfter = (headers.value(forHTTPHeaderField: "retry-after"))
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .serverError(status: status, message: message)
        }
    }
}
