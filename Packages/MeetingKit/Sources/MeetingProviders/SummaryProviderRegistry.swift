import Foundation

/// Enumerates the summarization backends, tracks which one is the user's
/// default, and resolves the one to use for a given run (E2.1).
///
/// Switching providers requires no restart: nothing is cached here, and every
/// lookup re-probes availability.
public struct SummaryProviderRegistry: Sendable {
    public static let shared = SummaryProviderRegistry()

    private static let defaultKey = "summaryProviderDefault"

    public let providers: [any SummaryProvider]

    public init(providers: [any SummaryProvider] = [
        AppleFoundationModelsProvider(),
        AnthropicProvider(),
        OpenAIProvider(),
        LocalServerProvider()
    ]) {
        self.providers = providers
    }

    public func provider(for id: SummaryProviderID) -> (any SummaryProvider)? {
        providers.first { $0.id == id }
    }

    /// The user's explicit choice, if they made one.
    public var preferredID: SummaryProviderID? {
        get {
            UserDefaults.standard.string(forKey: Self.defaultKey)
                .flatMap(SummaryProviderID.init(rawValue:))
        }
        nonmutating set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultKey)
            }
        }
    }

    /// The provider a pipeline run should use: the user's pick when it's ready,
    /// otherwise the first ready provider in preference order (on-device first).
    /// `nil` means nothing is configured — the pipeline finishes transcript-only
    /// rather than failing (E1.6).
    public func resolveActive() async -> (any SummaryProvider)? {
        if let preferredID, let preferred = provider(for: preferredID), await preferred.isReady() {
            return preferred
        }
        for candidate in providers where await candidate.isReady() {
            return candidate
        }
        return nil
    }

    public struct Status: Identifiable, Sendable {
        public let id: SummaryProviderID
        public let displayName: String
        public let privacyLabel: SummaryPrivacyLabel
        public let requirement: SummaryProviderRequirement

        public var isReady: Bool { requirement == .none }
    }

    /// Snapshot for Settings — one row per backend with its current blocker.
    public func statuses() async -> [Status] {
        var result: [Status] = []
        for provider in providers {
            result.append(
                Status(
                    id: provider.id,
                    displayName: provider.displayName,
                    privacyLabel: provider.privacyLabel,
                    requirement: await provider.requirement()
                )
            )
        }
        return result
    }
}
