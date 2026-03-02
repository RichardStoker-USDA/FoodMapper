import Foundation

/// Persisted application settings
struct AppSettings: Codable {
    var defaultThreshold: Double
    var appearance: String
    var advancedSettings: AdvancedSettings

    // Legacy fields for backwards compatibility when decoding old settings
    var defaultBatchSize: Int?
    var pageSize: Int?

    static var `default`: AppSettings {
        AppSettings(
            defaultThreshold: 0.85,
            appearance: "system",
            advancedSettings: .default
        )
    }

    // Custom decoder to handle missing advancedSettings in old saved data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultThreshold = try container.decode(Double.self, forKey: .defaultThreshold)
        appearance = try container.decode(String.self, forKey: .appearance)
        advancedSettings = try container.decodeIfPresent(AdvancedSettings.self, forKey: .advancedSettings) ?? .default
        defaultBatchSize = try container.decodeIfPresent(Int.self, forKey: .defaultBatchSize)
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize)
    }

    init(defaultThreshold: Double, appearance: String, advancedSettings: AdvancedSettings = .default) {
        self.defaultThreshold = defaultThreshold
        self.appearance = appearance
        self.advancedSettings = advancedSettings
    }
}

/// Advanced settings for power users - allows overriding hardware-detected defaults
struct AdvancedSettings: Codable, Equatable {
    /// Custom embedding batch size (nil = use hardware-detected default)
    var customEmbeddingBatchSize: Int?

    /// Custom matching batch size (nil = use hardware-detected default)
    var customMatchingBatchSize: Int?

    /// Custom chunk size for memory management (nil = use hardware-detected default)
    var customChunkSize: Int?

    /// Custom top-K candidates for reranking (nil = use default of 5)
    var customTopKForReranking: Int?

    /// Override recommended database size limits
    var allowLargeDatabases: Bool

    /// Show debug information in status bar
    var showDebugInfo: Bool

    /// Log performance metrics to console
    var logPerformanceMetrics: Bool

    /// Onboarding tracking
    var hasCompletedOnboarding: Bool
    var onboardingVersion: Int

    /// API tier override for Haiku pipeline concurrency (nil = auto-detect from response headers)
    var apiTierOverride: Int?

    init(
        customEmbeddingBatchSize: Int? = nil,
        customMatchingBatchSize: Int? = nil,
        customChunkSize: Int? = nil,
        customTopKForReranking: Int? = nil,
        allowLargeDatabases: Bool = false,
        showDebugInfo: Bool = false,
        logPerformanceMetrics: Bool = false,
        hasCompletedOnboarding: Bool = false,
        onboardingVersion: Int = 1,
        apiTierOverride: Int? = nil
    ) {
        self.customEmbeddingBatchSize = customEmbeddingBatchSize
        self.customMatchingBatchSize = customMatchingBatchSize
        self.customChunkSize = customChunkSize
        self.customTopKForReranking = customTopKForReranking
        self.allowLargeDatabases = allowLargeDatabases
        self.showDebugInfo = showDebugInfo
        self.logPerformanceMetrics = logPerformanceMetrics
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.onboardingVersion = onboardingVersion
        self.apiTierOverride = apiTierOverride
    }

    static var `default`: AdvancedSettings {
        AdvancedSettings()
    }

    // Custom decoder for backward compatibility with older saved settings
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customEmbeddingBatchSize = try container.decodeIfPresent(Int.self, forKey: .customEmbeddingBatchSize)
        customMatchingBatchSize = try container.decodeIfPresent(Int.self, forKey: .customMatchingBatchSize)
        customChunkSize = try container.decodeIfPresent(Int.self, forKey: .customChunkSize)
        customTopKForReranking = try container.decodeIfPresent(Int.self, forKey: .customTopKForReranking)
        allowLargeDatabases = try container.decodeIfPresent(Bool.self, forKey: .allowLargeDatabases) ?? false
        showDebugInfo = try container.decodeIfPresent(Bool.self, forKey: .showDebugInfo) ?? false
        logPerformanceMetrics = try container.decodeIfPresent(Bool.self, forKey: .logPerformanceMetrics) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        onboardingVersion = try container.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? 1
        apiTierOverride = try container.decodeIfPresent(Int.self, forKey: .apiTierOverride)
    }

    /// Get effective embedding batch size (custom or hardware default)
    func effectiveEmbeddingBatchSize(hardwareDefault: Int) -> Int {
        customEmbeddingBatchSize ?? hardwareDefault
    }

    /// Get effective matching batch size (custom or hardware default)
    func effectiveMatchingBatchSize(hardwareDefault: Int) -> Int {
        customMatchingBatchSize ?? hardwareDefault
    }

    /// Get effective chunk size (custom or hardware default)
    func effectiveChunkSize(hardwareDefault: Int) -> Int {
        customChunkSize ?? hardwareDefault
    }

    /// Get effective top-K for reranking (custom or default)
    func effectiveTopK(hardwareDefault: Int) -> Int {
        customTopKForReranking ?? hardwareDefault
    }

    /// Check if any custom overrides are set
    var hasCustomOverrides: Bool {
        customEmbeddingBatchSize != nil ||
        customMatchingBatchSize != nil ||
        customChunkSize != nil ||
        customTopKForReranking != nil
    }

    /// Reset all performance overrides to defaults
    mutating func resetPerformanceOverrides() {
        customEmbeddingBatchSize = nil
        customMatchingBatchSize = nil
        customChunkSize = nil
        customTopKForReranking = nil
    }
}

/// Per-pipeline performance overrides. nil values use the pipeline+model defaults.
struct PipelinePerformanceConfig: Codable, Equatable {
    var embeddingBatchSize: Int?
    var matchingBatchSize: Int?
    var chunkSize: Int?
    var topK: Int?

    /// True if any override is set
    var hasOverrides: Bool {
        embeddingBatchSize != nil || matchingBatchSize != nil || chunkSize != nil || topK != nil
    }

    /// Clear all overrides back to nil (use defaults)
    mutating func reset() {
        embeddingBatchSize = nil
        matchingBatchSize = nil
        chunkSize = nil
        topK = nil
    }
}
