import Foundation

/// Which backend produced (or should produce) a summary. Persisted on the
/// `summaries` row, so raw values are part of the schema — don't rename them.
public enum SummaryProviderID: String, CaseIterable, Sendable {
    case appleFoundationModels = "apple"
    case anthropic
    case openAI = "openai"
    case localServer = "local"
}

/// What a provider needs before it can run.
public enum SummaryProviderRequirement: Equatable, Sendable {
    /// Ready to use right now.
    case none
    /// Needs an API key in the Keychain.
    case apiKey
    /// Needs a base URL for a local OpenAI-compatible server.
    case serverURL
    /// Can't run on this machine at all, with a user-facing reason.
    case unavailable(String)
}

/// Where transcript text goes when this provider runs — surfaced verbatim in
/// Settings so the privacy story is never implicit (PRD §5).
public enum SummaryPrivacyLabel: Equatable, Sendable {
    case onDevice
    case sentTo(String)
    case sentToLocalServer

    public var description: String {
        switch self {
        case .onDevice:
            return "Stays on this Mac"
        case .sentTo(let vendor):
            return "Transcript is sent to \(vendor)"
        case .sentToLocalServer:
            return "Sent to the local server you configured"
        }
    }
}

public struct SummaryRequest: Sendable {
    public let transcript: String
    public let notes: String?
    public let template: SummaryTemplate

    public init(transcript: String, notes: String? = nil, template: SummaryTemplate = .general) {
        self.transcript = transcript
        self.notes = notes
        self.template = template
    }
}

public struct SummaryResult: Sendable {
    public let content: String
    public let providerID: SummaryProviderID
    public let model: String?
    public let templateID: String

    public init(content: String, providerID: SummaryProviderID, model: String?, templateID: String) {
        self.content = content
        self.providerID = providerID
        self.model = model
        self.templateID = templateID
    }
}

public protocol SummaryProvider: Sendable {
    nonisolated var id: SummaryProviderID { get }
    nonisolated var displayName: String { get }
    nonisolated var privacyLabel: SummaryPrivacyLabel { get }

    /// Capability probe. Called whenever Settings or the pipeline needs to know
    /// whether this provider can run — never cached across launches.
    func requirement() async -> SummaryProviderRequirement

    /// Round-trips a trivial request to prove the configuration works.
    /// Powers the "Test connection" button and save-time key validation.
    func validateConfiguration() async throws

    func summarize(_ request: SummaryRequest) async throws -> SummaryResult
}

public extension SummaryProvider {
    func isReady() async -> Bool {
        await requirement() == .none
    }
}

public enum SummaryProviderError: Error, LocalizedError {
    case notConfigured(SummaryProviderID)
    case unavailable(String)
    case invalidKey(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int, message: String)
    case requestFailed(String)
    case refused(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let id):
            return "The \(id.rawValue) summarizer isn’t configured yet."
        case .unavailable(let reason):
            return reason
        case .invalidKey(let detail):
            return "That API key was rejected: \(detail)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Try again in about \(Int(retryAfter.rounded())) s."
            }
            return "Rate limited by the provider. Try again shortly."
        case .serverError(let status, let message):
            return "The provider returned an error (\(status)): \(message)"
        case .requestFailed(let detail):
            return "Couldn’t reach the summarizer: \(detail)"
        case .refused(let detail):
            return "The model declined to summarize this meeting: \(detail)"
        case .emptyResponse:
            return "The summarizer returned nothing."
        }
    }

    /// Whether retrying the identical request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .requestFailed:
            return true
        case .serverError(let status, _):
            return status >= 500
        default:
            return false
        }
    }
}
