import Foundation

/// Chat-completions client shared by the OpenAI provider and the local-server
/// provider — Ollama and LM Studio both expose the same wire format, so there
/// is one implementation and two configurations.
struct OpenAICompatibleClient: Sendable {
    let baseURL: URL
    let apiKey: String?
    let session: URLSession

    func complete(model: String, system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let data = try await perform(request)
        return try Self.parseCompletion(data)
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.timeoutInterval = 30

        let data = try await perform(request)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = object?["data"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["id"] as? String }
    }

    static func parseCompletion(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryProviderError.requestFailed("Unreadable response.")
        }
        let choices = object["choices"] as? [[String: Any]] ?? []
        let text = choices
            .compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
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
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)?.prefix(300).description
                ?? "unknown error"
            switch http.statusCode {
            case 401, 403:
                throw SummaryProviderError.invalidKey(message)
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw SummaryProviderError.rateLimited(retryAfter: retryAfter)
            default:
                throw SummaryProviderError.serverError(status: http.statusCode, message: message)
            }
        }
        return data
    }
}

// MARK: - OpenAI

public struct OpenAIProvider: SummaryProvider {
    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let contextCharacterBudget: Int
    }

    /// Verified against developers.openai.com in August 2026. `contextCharacterBudget`
    /// is a chunking threshold, not the model's limit — the 5.6 family accepts
    /// ~922k input tokens, and we deliberately stay far under that.
    public static let models: [Model] = [
        Model(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", contextCharacterBudget: 600_000),
        Model(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna (cheapest)", contextCharacterBudget: 600_000),
        Model(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol (most capable)", contextCharacterBudget: 600_000)
    ]

    /// Terra balances intelligence and cost, which is the right trade for
    /// summarizing a transcript.
    public static let defaultModelID = "gpt-5.6-terra"

    public static var selectedModelID: String {
        get { UserDefaults.standard.string(forKey: "openAIModelID") ?? defaultModelID }
        set { UserDefaults.standard.set(newValue, forKey: "openAIModelID") }
    }

    static var selectedModel: Model {
        models.first { $0.id == selectedModelID }
            ?? Model(id: selectedModelID, displayName: selectedModelID, contextCharacterBudget: 200_000)
    }

    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public nonisolated var id: SummaryProviderID { .openAI }
    public nonisolated var displayName: String { "OpenAI (your API key)" }
    public nonisolated var privacyLabel: SummaryPrivacyLabel { .sentTo("OpenAI") }

    public func requirement() async -> SummaryProviderRequirement {
        KeychainStore.has(.openAI) ? .none : .apiKey
    }

    public func validateConfiguration() async throws {
        guard let key = KeychainStore.get(.openAI) else {
            throw SummaryProviderError.notConfigured(.openAI)
        }
        _ = try await client(key: key).listModels()
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryResult {
        guard let key = KeychainStore.get(.openAI) else {
            throw SummaryProviderError.notConfigured(.openAI)
        }
        let model = Self.selectedModel
        let client = client(key: key)

        let content = try await ChunkedSummarization.run(
            request: request,
            contextCharacterBudget: model.contextCharacterBudget,
            generator: TextGenerator { system, user in
                try await client.complete(model: model.id, system: system, user: user)
            }
        )

        return SummaryResult(
            content: content,
            providerID: .openAI,
            model: model.id,
            templateID: request.template.id
        )
    }

    private func client(key: String) -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: baseURL, apiKey: key, session: session)
    }
}

// MARK: - Local server (Ollama / LM Studio)

public struct LocalServerProvider: SummaryProvider {
    public static let defaultBaseURL = "http://localhost:11434/v1"
    public static let defaultModelName = "llama3.2"

    public static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: "localServerBaseURL") ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "localServerBaseURL") }
    }

    public static var modelName: String {
        get { UserDefaults.standard.string(forKey: "localServerModel") ?? defaultModelName }
        set { UserDefaults.standard.set(newValue, forKey: "localServerModel") }
    }

    /// Local models tend to have small context windows; chunk early.
    public static var contextCharacterBudget: Int {
        let stored = UserDefaults.standard.integer(forKey: "localServerContextCharacters")
        return stored > 0 ? stored : 24_000
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public nonisolated var id: SummaryProviderID { .localServer }
    public nonisolated var displayName: String { "Local server (Ollama, LM Studio)" }
    public nonisolated var privacyLabel: SummaryPrivacyLabel { .sentToLocalServer }

    public func requirement() async -> SummaryProviderRequirement {
        resolvedURL() == nil ? .serverURL : .none
    }

    public func validateConfiguration() async throws {
        guard let url = resolvedURL() else {
            throw SummaryProviderError.notConfigured(.localServer)
        }
        let available = try await client(url).listModels()
        let wanted = Self.modelName
        guard available.isEmpty || available.contains(where: { $0 == wanted || $0.hasPrefix(wanted + ":") }) else {
            throw SummaryProviderError.unavailable(
                "The server is reachable but doesn’t have “\(wanted)”. It offers: \(available.prefix(8).joined(separator: ", "))."
            )
        }
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryResult {
        guard let url = resolvedURL() else {
            throw SummaryProviderError.notConfigured(.localServer)
        }
        let model = Self.modelName
        let client = client(url)

        let content = try await ChunkedSummarization.run(
            request: request,
            contextCharacterBudget: Self.contextCharacterBudget,
            generator: TextGenerator { system, user in
                try await client.complete(model: model, system: system, user: user)
            }
        )

        return SummaryResult(
            content: content,
            providerID: .localServer,
            model: model,
            templateID: request.template.id
        )
    }

    private func resolvedURL() -> URL? {
        let trimmed = Self.baseURLString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    private func client(_ url: URL) -> OpenAICompatibleClient {
        // Local servers generally ignore the bearer token; send it when the
        // user supplied one so authenticated proxies work too.
        OpenAICompatibleClient(baseURL: url, apiKey: KeychainStore.get(.localServer), session: session)
    }
}
