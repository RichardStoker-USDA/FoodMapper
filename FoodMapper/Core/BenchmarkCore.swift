import Foundation

struct BenchmarkTarget: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let description: String
}

struct BenchmarkCase: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let input: String
    let expectedTargetID: String
    let context: String?
}

struct BenchmarkFixture: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let revision: Int
    let targets: [BenchmarkTarget]
    let cases: [BenchmarkCase]

    func validate(limits: AdvancedRunLimits = .defaults) throws {
        let checkedLimits = try limits.validated()
        guard !targets.isEmpty, !cases.isEmpty else { throw BenchmarkError.emptyFixture }
        guard cases.count <= checkedLimits.inputRows else {
            throw BenchmarkError.tooManyCases(checkedLimits.inputRows)
        }
        let targetIDs = Set(targets.map(\.id))
        guard targetIDs.count == targets.count else { throw BenchmarkError.duplicateTargetID }
        guard cases.allSatisfy({ targetIDs.contains($0.expectedTargetID) }) else {
            throw BenchmarkError.missingExpectedTarget
        }
        guard targets.allSatisfy({ $0.description.lengthOfBytes(using: .utf8) <= checkedLimits.fieldBytes }),
              cases.allSatisfy({ $0.input.lengthOfBytes(using: .utf8) <= checkedLimits.fieldBytes }) else {
            throw BenchmarkError.fieldTooLong(checkedLimits.fieldBytes)
        }
    }
}

struct BenchmarkRanking: Codable, Equatable, Sendable {
    let caseID: String
    let rankedTargetIDs: [String]
    let latencyMilliseconds: Double
}

struct BenchmarkMetrics: Codable, Equatable, Sendable {
    let caseCount: Int
    let top1Accuracy: Double
    let top5Accuracy: Double
    let top10Accuracy: Double
    let meanReciprocalRank: Double
    let medianLatencyMilliseconds: Double

    static func calculate(fixture: BenchmarkFixture, rankings: [BenchmarkRanking]) throws -> BenchmarkMetrics {
        try fixture.validate(limits: .maximum)
        let rankingCaseIDs = rankings.map(\.caseID)
        guard Set(rankingCaseIDs).count == rankingCaseIDs.count else {
            throw BenchmarkError.incompleteResults
        }
        let rankingByCase = Dictionary(uniqueKeysWithValues: rankings.map { ($0.caseID, $0) })
        guard rankingByCase.count == rankings.count,
              fixture.cases.allSatisfy({ rankingByCase[$0.id] != nil }) else {
            throw BenchmarkError.incompleteResults
        }

        var top1 = 0
        var top5 = 0
        var top10 = 0
        var reciprocalRank = 0.0
        var latencies: [Double] = []
        latencies.reserveCapacity(fixture.cases.count)

        for item in fixture.cases {
            guard let ranking = rankingByCase[item.id] else { throw BenchmarkError.incompleteResults }
            let ids = Array(ranking.rankedTargetIDs.prefix(10))
            if ids.first == item.expectedTargetID { top1 += 1 }
            if ids.prefix(5).contains(item.expectedTargetID) { top5 += 1 }
            if ids.contains(item.expectedTargetID) { top10 += 1 }
            if let index = ids.firstIndex(of: item.expectedTargetID) {
                reciprocalRank += 1.0 / Double(index + 1)
            }
            latencies.append(max(0, ranking.latencyMilliseconds))
        }

        let count = Double(fixture.cases.count)
        let sortedLatencies = latencies.sorted()
        let midpoint = sortedLatencies.count / 2
        let median: Double
        if sortedLatencies.count.isMultiple(of: 2) {
            median = (sortedLatencies[midpoint - 1] + sortedLatencies[midpoint]) / 2
        } else {
            median = sortedLatencies[midpoint]
        }

        return BenchmarkMetrics(
            caseCount: fixture.cases.count,
            top1Accuracy: Double(top1) / count,
            top5Accuracy: Double(top5) / count,
            top10Accuracy: Double(top10) / count,
            meanReciprocalRank: reciprocalRank / count,
            medianLatencyMilliseconds: median
        )
    }
}

struct BenchmarkRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let fixtureID: String
    let fixtureRevision: Int
    let pipelineID: String
    let modelKey: String
    let modelRevision: String
    let metrics: BenchmarkMetrics
    let rankings: [BenchmarkRanking]
}

enum BenchmarkError: LocalizedError, Equatable {
    case emptyFixture
    case duplicateTargetID
    case missingExpectedTarget
    case tooManyCases(Int)
    case fieldTooLong(Int)
    case incompleteResults

    var errorDescription: String? {
        switch self {
        case .emptyFixture: return "The benchmark fixture is empty."
        case .duplicateTargetID: return "The benchmark fixture has duplicate target IDs."
        case .missingExpectedTarget: return "A benchmark case refers to a missing target."
        case let .tooManyCases(maximum): return "The benchmark is limited to \(maximum) cases."
        case let .fieldTooLong(maximum): return "A benchmark field exceeds \(maximum) bytes."
        case .incompleteResults: return "The benchmark results do not cover every case exactly once."
        }
    }
}

enum FoodMatchingBenchmark {
    static let regression = BenchmarkFixture(
        id: "food-matching-regression",
        name: "Food matching regression",
        revision: 1,
        targets: [
            .init(id: "t01", description: "Broccoli, raw"),
            .init(id: "t02", description: "Broccoli, cooked, boiled, drained, without salt"),
            .init(id: "t03", description: "Soup, broccoli cheese, canned, condensed"),
            .init(id: "t04", description: "Soup, broccoli cheese, prepared with milk"),
            .init(id: "t05", description: "Cheese, cheddar"),
            .init(id: "t06", description: "Cheese substitute, plant-based, cheddar style"),
            .init(id: "t07", description: "Yogurt, plain, whole milk"),
            .init(id: "t08", description: "Yogurt, soy, plain"),
            .init(id: "t09", description: "Cabbage, fermented, sauerkraut"),
            .init(id: "t10", description: "Cabbage, cooked, boiled, drained"),
            .init(id: "t11", description: "Chicken breast, roasted, skinless"),
            .init(id: "t12", description: "Chicken breast, breaded and fried"),
            .init(id: "t13", description: "Beverage, almond milk, unsweetened"),
            .init(id: "t14", description: "Milk, whole, 3.25% milkfat"),
            .init(id: "t15", description: "Potato soup, instant, prepared from dry mix"),
            .init(id: "t16", description: "Pudding, chocolate, prepared from dry mix, milk added"),
            .init(id: "t17", description: "Pudding, chocolate, ready-to-eat"),
            .init(id: "t18", description: "Beans, black, canned, drained and rinsed"),
            .init(id: "t19", description: "Beans, black, cooked from dry"),
            .init(id: "t20", description: "Tofu, firm, prepared with calcium"),
            .init(id: "t21", description: "Tempeh, cooked"),
            .init(id: "t22", description: "Bread, wheat, commercially prepared"),
            .init(id: "t23", description: "Bread, gluten-free, commercially prepared"),
            .init(id: "t24", description: "Salmon, Atlantic, farmed, baked"),
            .init(id: "t25", description: "Salmon, canned, drained solids"),
            .init(id: "t26", description: "Coffee, brewed from grounds"),
            .init(id: "t27", description: "Coffee beverage, instant, prepared with water"),
            .init(id: "t28", description: "Rice, brown, long-grain, cooked"),
            .init(id: "t29", description: "Rice, white, long-grain, cooked"),
            .init(id: "t30", description: "Sweet potato, baked, flesh and skin")
        ],
        cases: [
            .init(id: "c01", input: "broccoli cheddar soup", expectedTargetID: "t04", context: "Prepared soup"),
            .init(id: "c02", input: "raw broccoli florets", expectedTargetID: "t01", context: "Preparation matters"),
            .init(id: "c03", input: "boiled broccoli no salt", expectedTargetID: "t02", context: "Preparation matters"),
            .init(id: "c04", input: "vegan cheddar slices", expectedTargetID: "t06", context: "Non-dairy alternative"),
            .init(id: "c05", input: "plain soy yogurt", expectedTargetID: "t08", context: "Non-dairy alternative"),
            .init(id: "c06", input: "fermented cabbage", expectedTargetID: "t09", context: "Fermented food"),
            .init(id: "c07", input: "skinless roast chicken breast", expectedTargetID: "t11", context: "Preparation matters"),
            .init(id: "c08", input: "fried breaded chicken breast", expectedTargetID: "t12", context: "Preparation matters"),
            .init(id: "c09", input: "unsweetened almond beverage", expectedTargetID: "t13", context: "Non-dairy beverage"),
            .init(id: "c10", input: "instant potato soup from packet", expectedTargetID: "t15", context: "Dry mix"),
            .init(id: "c11", input: "chocolate pudding mix prepared with milk", expectedTargetID: "t16", context: "Dry mix"),
            .init(id: "c12", input: "canned black beans rinsed", expectedTargetID: "t18", context: "Preparation matters"),
            .init(id: "c13", input: "black beans cooked from dried beans", expectedTargetID: "t19", context: "Preparation matters"),
            .init(id: "c14", input: "firm calcium-set tofu", expectedTargetID: "t20", context: "Calcium source"),
            .init(id: "c15", input: "cooked fermented soy cake", expectedTargetID: "t21", context: "Fermented food"),
            .init(id: "c16", input: "store-bought gluten free bread", expectedTargetID: "t23", context: "Gluten-free product"),
            .init(id: "c17", input: "baked farmed Atlantic salmon", expectedTargetID: "t24", context: "Preparation matters"),
            .init(id: "c18", input: "drained canned salmon", expectedTargetID: "t25", context: "Canned food"),
            .init(id: "c19", input: "instant coffee made with water", expectedTargetID: "t27", context: "Preparation matters"),
            .init(id: "c20", input: "baked sweet potato with skin", expectedTargetID: "t30", context: "Preparation matters")
        ]
    )
}
