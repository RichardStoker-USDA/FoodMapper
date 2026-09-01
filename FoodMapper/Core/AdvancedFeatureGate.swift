import Foundation

struct AdvancedFeatureLease: Equatable, Sendable {
    fileprivate let generation: UInt64
}

struct AdvancedRunLimits: Equatable, Sendable {
    static let defaults = AdvancedRunLimits(
        inputRows: 1_000,
        inputBytes: 8 * 1_024 * 1_024,
        candidateCount: 5,
        resultRecords: 1_000,
        fieldBytes: 4 * 1_024
    )

    static let maximum = AdvancedRunLimits(
        inputRows: 10_000,
        inputBytes: 64 * 1_024 * 1_024,
        candidateCount: 10,
        resultRecords: 10_000,
        fieldBytes: 16 * 1_024
    )

    let inputRows: Int
    let inputBytes: Int
    let candidateCount: Int
    let resultRecords: Int
    let fieldBytes: Int

    func validated() throws -> AdvancedRunLimits {
        guard inputRows > 0, inputRows <= Self.maximum.inputRows else {
            throw AdvancedFeatureError.limitExceeded("Input rows", Self.maximum.inputRows)
        }
        guard inputBytes > 0, inputBytes <= Self.maximum.inputBytes else {
            throw AdvancedFeatureError.limitExceeded("Input bytes", Self.maximum.inputBytes)
        }
        guard candidateCount > 0, candidateCount <= Self.maximum.candidateCount else {
            throw AdvancedFeatureError.limitExceeded("Candidates per input", Self.maximum.candidateCount)
        }
        guard resultRecords > 0, resultRecords <= Self.maximum.resultRecords else {
            throw AdvancedFeatureError.limitExceeded("Result records", Self.maximum.resultRecords)
        }
        guard fieldBytes > 0, fieldBytes <= Self.maximum.fieldBytes else {
            throw AdvancedFeatureError.limitExceeded("Field bytes", Self.maximum.fieldBytes)
        }
        return self
    }
}

enum AdvancedFeatureError: LocalizedError, Equatable {
    case disabled
    case expiredLease
    case limitExceeded(String, Int)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Advanced mode is off."
        case .expiredLease:
            return "Advanced mode changed while this operation was running."
        case let .limitExceeded(name, maximum):
            return "\(name) exceeds the limit of \(maximum)."
        }
    }
}

/// A synchronous authorization boundary for optional model, provider, and benchmark work.
/// Turning Advanced mode off invalidates every lease already issued.
final class AdvancedFeatureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0

    func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled != value {
            generation &+= 1
        }
        enabled = value
    }

    func issueLease() throws -> AdvancedFeatureLease {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { throw AdvancedFeatureError.disabled }
        return AdvancedFeatureLease(generation: generation)
    }

    func validate(_ lease: AdvancedFeatureLease) throws {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { throw AdvancedFeatureError.disabled }
        guard lease.generation == generation else { throw AdvancedFeatureError.expiredLease }
    }
}
