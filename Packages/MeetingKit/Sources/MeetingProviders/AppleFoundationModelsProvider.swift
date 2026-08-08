import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device summarization via Apple Foundation Models — the zero-setup default
/// on macOS 26+ with Apple Intelligence enabled (TD-3).
///
/// Compiled against the macOS 26 SDK but gated at runtime, so the same binary
/// still launches on macOS 14/15 with this provider reporting `.unavailable`.
public struct AppleFoundationModelsProvider: SummaryProvider {
    /// The on-device model's context window is small next to a cloud model's,
    /// so long meetings map-reduce far more often here.
    public static let contextCharacterBudget = 12_000

    public init() {}

    public nonisolated var id: SummaryProviderID { .appleFoundationModels }
    public nonisolated var displayName: String { "Apple Intelligence (on-device)" }
    public nonisolated var privacyLabel: SummaryPrivacyLabel { .onDevice }

    public func requirement() async -> SummaryProviderRequirement {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            return .unavailable("Needs macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .none
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn’t support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings to use this.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still downloading its model. Try again shortly.")
        case .unavailable:
            return .unavailable("Apple Intelligence isn’t available right now.")
        }
        #else
        return .unavailable("This build wasn’t compiled with Apple Intelligence support.")
        #endif
    }

    public func validateConfiguration() async throws {
        let requirement = await requirement()
        if case .unavailable(let reason) = requirement {
            throw SummaryProviderError.unavailable(reason)
        }
    }

    public func summarize(_ request: SummaryRequest) async throws -> SummaryResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            throw SummaryProviderError.unavailable("Needs macOS 26 or later.")
        }
        if case .unavailable(let reason) = await requirement() {
            throw SummaryProviderError.unavailable(reason)
        }

        let content = try await ChunkedSummarization.run(
            request: request,
            contextCharacterBudget: Self.contextCharacterBudget,
            generator: TextGenerator { system, user in
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(to: user)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw SummaryProviderError.emptyResponse }
                return text
            }
        )

        return SummaryResult(
            content: content,
            providerID: .appleFoundationModels,
            model: "apple-foundation-model",
            templateID: request.template.id
        )
        #else
        throw SummaryProviderError.unavailable("This build wasn’t compiled with Apple Intelligence support.")
        #endif
    }
}
