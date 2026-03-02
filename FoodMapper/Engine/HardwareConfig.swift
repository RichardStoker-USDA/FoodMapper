import Foundation
import Metal
import MLX

/// Hardware profile based on unified memory capacity
enum HardwareProfile: String, Codable, CaseIterable {
    case base      // 8GB
    case standard  // 16GB
    case pro       // 24-32GB
    case max       // 48-64GB
    case ultra     // 96GB+

    var displayName: String {
        switch self {
        case .base: return "8GB"
        case .standard: return "16GB"
        case .pro: return "24-32GB"
        case .max: return "64GB"
        case .ultra: return "96GB+"
        }
    }
}

/// Hardware configuration with auto-detected optimal settings
struct HardwareConfig: Codable, Equatable {
    let profile: HardwareProfile
    let detectedMemoryGB: Int
    let deviceName: String

    // Computed optimal settings based on hardware profile
    let embeddingBatchSize: Int
    let matchingBatchSize: Int
    let chunkSize: Int
    let cacheLimitMB: Int
    let topKForReranking: Int

    // Soft limits for database size
    let recommendedMaxDatabaseItems: Int
    let absoluteMaxDatabaseItems: Int

    /// Embedding throughput in items/sec, used for time estimates.
    /// Calibrated against M2 Ultra benchmark: 50K items in ~120s with medium food descriptions.
    /// Actual throughput varies with:
    ///   - Text length: short names (~5 tokens) ~2x faster, long (~100+) ~1.5-2x slower
    ///   - Chip generation: M4 ~20-30% faster, M1 ~10-20% slower than these M2 baselines
    /// Profiles are memory-based only; chip gen differences aren't factored into estimates.
    var estimatedThroughput: Int {
        switch profile {
        case .base: return 140
        case .standard: return 210
        case .pro: return 280
        case .max: return 350
        case .ultra: return 420
        }
    }

    /// Whether both Qwen3 models (4B 4-bit embedding + 0.6B FP16 reranker) can stay loaded simultaneously.
    /// At ~2.5 GB embedding + ~1.2 GB reranker (~3.7 GB total), fits 8 GB+ Macs comfortably.
    var canLoadBothQwen3Models: Bool {
        return detectedMemoryGB >= 8
    }

    /// Shortened device name for status bar display
    var shortDeviceName: String {
        // "Apple M2 Pro" -> "M2 Pro"
        // "Apple M1" -> "M1"
        let name = deviceName
            .replacingOccurrences(of: "Apple ", with: "")
            .replacingOccurrences(of: " GPU", with: "")
        return name
    }

    /// Detect hardware and return optimal configuration
    static func detect() -> HardwareConfig {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .fallback
        }

        let memoryBytes = device.recommendedMaxWorkingSetSize
        let memoryGB = Int(memoryBytes / 1_073_741_824)
        let deviceName = device.name

        return HardwareConfig(memoryGB: memoryGB, deviceName: deviceName)
    }

    /// Create config based on detected memory
    init(memoryGB: Int, deviceName: String) {
        self.detectedMemoryGB = memoryGB
        self.deviceName = deviceName

        // Classify profile and set optimal values
        switch memoryGB {
        case 0..<12:
            // Base profile: 8GB Macs (M1/M2 base)
            profile = .base
            embeddingBatchSize = 16
            matchingBatchSize = 128
            chunkSize = 500
            cacheLimitMB = 512
            topKForReranking = 5
            recommendedMaxDatabaseItems = 50_000
            absoluteMaxDatabaseItems = 100_000

        case 12..<20:
            // Standard profile: 16GB Macs (M1/M2/M3 with 16GB)
            profile = .standard
            embeddingBatchSize = 32
            matchingBatchSize = 128
            chunkSize = 500
            cacheLimitMB = 1024
            topKForReranking = 10
            recommendedMaxDatabaseItems = 100_000
            absoluteMaxDatabaseItems = 250_000

        case 20..<48:
            // Pro profile: 24-32GB Macs (M1/M2/M3 Pro/Max configs)
            profile = .pro
            embeddingBatchSize = 32
            matchingBatchSize = 128
            chunkSize = 500
            cacheLimitMB = 2048
            topKForReranking = 20
            recommendedMaxDatabaseItems = 250_000
            absoluteMaxDatabaseItems = 500_000

        case 48..<80:
            // Max profile: 64GB Macs (M1/M2/M3 Max with 64GB)
            profile = .max
            embeddingBatchSize = 32
            matchingBatchSize = 128
            chunkSize = 500
            cacheLimitMB = 4096
            topKForReranking = 20
            recommendedMaxDatabaseItems = 500_000
            absoluteMaxDatabaseItems = 1_000_000

        default:
            // Ultra profile: 96GB+ Macs (M1/M2 Ultra, Studio configs)
            profile = .ultra
            embeddingBatchSize = 32
            matchingBatchSize = 128
            chunkSize = 500
            cacheLimitMB = 8192
            topKForReranking = 20
            recommendedMaxDatabaseItems = 1_000_000
            absoluteMaxDatabaseItems = 2_000_000
        }
    }

    /// Full memberwise initializer for custom/override configs
    init(
        profile: HardwareProfile,
        detectedMemoryGB: Int,
        deviceName: String,
        embeddingBatchSize: Int,
        matchingBatchSize: Int,
        chunkSize: Int,
        cacheLimitMB: Int,
        topKForReranking: Int,
        recommendedMaxDatabaseItems: Int,
        absoluteMaxDatabaseItems: Int
    ) {
        self.profile = profile
        self.detectedMemoryGB = detectedMemoryGB
        self.deviceName = deviceName
        self.embeddingBatchSize = embeddingBatchSize
        self.matchingBatchSize = matchingBatchSize
        self.chunkSize = chunkSize
        self.cacheLimitMB = cacheLimitMB
        self.topKForReranking = topKForReranking
        self.recommendedMaxDatabaseItems = recommendedMaxDatabaseItems
        self.absoluteMaxDatabaseItems = absoluteMaxDatabaseItems
    }

    /// Fallback config when Metal device unavailable
    static let fallback = HardwareConfig(memoryGB: 8, deviceName: "Unknown Device")

    /// Create a config with custom overrides applied
    func withOverrides(
        embeddingBatchSize: Int? = nil,
        matchingBatchSize: Int? = nil,
        chunkSize: Int? = nil,
        topKForReranking: Int? = nil
    ) -> HardwareConfig {
        HardwareConfig(
            profile: profile,
            detectedMemoryGB: detectedMemoryGB,
            deviceName: deviceName,
            embeddingBatchSize: embeddingBatchSize ?? self.embeddingBatchSize,
            matchingBatchSize: matchingBatchSize ?? self.matchingBatchSize,
            chunkSize: chunkSize ?? self.chunkSize,
            cacheLimitMB: cacheLimitMB,
            topKForReranking: topKForReranking ?? self.topKForReranking,
            recommendedMaxDatabaseItems: recommendedMaxDatabaseItems,
            absoluteMaxDatabaseItems: absoluteMaxDatabaseItems
        )
    }

    /// Estimated reranker forward passes per second.
    /// Based on runtime testing: Qwen3-Reranker 0.6B FP16 processes ~5-10 candidates/sec
    /// depending on hardware. Conservative estimates to avoid over-promising.
    var estimatedRerankingPassesPerSecond: Double {
        switch profile {
        case .base: return 4.0
        case .standard: return 6.0
        case .pro: return 8.0
        case .max: return 10.0
        case .ultra: return 12.0
        }
    }

    /// Estimate reranking time for a given workload.
    /// - Parameters:
    ///   - inputCount: Number of input texts to process
    ///   - candidatesPerInput: Number of candidates scored per input (topK for two-stage, full DB for reranker-only)
    func estimateRerankingTime(inputCount: Int, candidatesPerInput: Int) -> TimeInterval {
        let totalPasses = Double(inputCount) * Double(candidatesPerInput)
        return totalPasses / estimatedRerankingPassesPerSecond
    }

    /// Estimate embedding time for a given item count
    /// Factors in text length variation when estimating embedding time
    func estimateEmbeddingTime(itemCount: Int, averageTextLength: Int? = nil) -> TimeInterval {
        // Base throughput adjusted by text length factor
        // Default assumption: average food description is ~50 characters
        let baseCharLength = 50.0
        let textLength = Double(averageTextLength ?? 50)
        let lengthFactor = max(0.5, min(2.0, textLength / baseCharLength))

        // Adjust throughput by length factor (longer text = slower)
        let adjustedThroughput = Double(estimatedThroughput) / lengthFactor

        // Add 10% overhead for memory operations and batching
        let overhead = 1.1
        return (Double(itemCount) / adjustedThroughput) * overhead
    }

    /// Format estimated time as human-readable string
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "~\(Int(seconds)) seconds"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "~\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes == 0 {
                return "~\(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "~\(hours)h \(minutes)m"
        }
    }
}

// MARK: - Validation

extension HardwareConfig {
    /// Valid range for embedding batch size
    static let embeddingBatchSizeRange = 8...128

    /// Valid range for matching batch size
    static let matchingBatchSizeRange = 64...1024

    /// Valid range for chunk size
    static let chunkSizeRange = 250...16000

    /// Available embedding batch size options for picker
    static let embeddingBatchSizeOptions = [8, 16, 24, 32, 48, 64, 96, 128]

    /// Available matching batch size options for picker
    static let matchingBatchSizeOptions = [64, 128, 192, 256, 384, 512, 768, 1024]

    /// Available chunk size options for picker
    static let chunkSizeOptions = [250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Available top-K options for reranking candidates picker
    static let topKOptions = [3, 5, 10, 15, 20, 25, 30]

    /// Check if a batch size exceeds recommended for this hardware
    func isEmbeddingBatchSizeExcessive(_ size: Int) -> Bool {
        size > embeddingBatchSize * 2
    }

    /// Check if a matching batch size exceeds recommended for this hardware
    func isMatchingBatchSizeExcessive(_ size: Int) -> Bool {
        size > matchingBatchSize * 2
    }
}

// MARK: - MLX Cache Management

extension HardwareConfig {
    /// Apply MLX memory cache limit based on hardware profile
    func applyMLXCacheLimit() {
        Memory.cacheLimit = cacheLimitMB * 1024 * 1024
    }
}
