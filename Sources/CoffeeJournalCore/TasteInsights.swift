import Foundation

public struct TasteInsight: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var tokens: [String]

    public init(id: UUID = UUID(), title: String, detail: String, tokens: [String]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tokens = tokens
    }
}

public struct TasteSummary: Equatable, Sendable {
    public var likedTokens: [String]
    public var skippedTokens: [String]
    public var mostLovedCoffeeIDs: [UUID]
    public var insights: [TasteInsight]

    public init(
        likedTokens: [String],
        skippedTokens: [String],
        mostLovedCoffeeIDs: [UUID],
        insights: [TasteInsight]
    ) {
        self.likedTokens = likedTokens
        self.skippedTokens = skippedTokens
        self.mostLovedCoffeeIDs = mostLovedCoffeeIDs
        self.insights = insights
    }
}

public enum TasteAnalyzer {
    public static func summarize(coffees: [Coffee], logs: [BrewLog]) -> TasteSummary {
        let coffeeByID = Dictionary(uniqueKeysWithValues: coffees.map { ($0.id, $0) })
        let lovedLogs = logs.filter { $0.verdict == .loved || $0.verdict == .liked }
        let dislikedLogs = logs.filter { $0.verdict == .disliked || $0.verdict == .ok }

        let likedTokens = topTokens(from: lovedLogs, coffeeByID: coffeeByID)
        let skippedTokens = topTokens(from: dislikedLogs, coffeeByID: coffeeByID)
        let mostLoved = mostLovedCoffeeIDs(from: logs)

        var insights: [TasteInsight] = []
        if likedTokens.contains(where: { $0.localizedCaseInsensitiveContains("washed") }) {
            insights.append(
                TasteInsight(
                    title: "Washed coffees keep scoring well",
                    detail: "Your higher-rated notes often come from washed coffees. Keep testing floral and tea-like lots.",
                    tokens: likedTokens
                )
            )
        }

        if likedTokens.count >= 3 {
            insights.append(
                TasteInsight(
                    title: "Your taste memory is getting specific",
                    detail: "The strongest repeated signals are \(likedTokens.prefix(3).joined(separator: ", ")).",
                    tokens: Array(likedTokens.prefix(3))
                )
            )
        }

        if logs.count >= 4 {
            insights.append(
                TasteInsight(
                    title: "Enough logs for lightweight patterns",
                    detail: "You have enough entries for rebuy candidates and disliked-pattern checks.",
                    tokens: []
                )
            )
        }

        return TasteSummary(
            likedTokens: likedTokens,
            skippedTokens: skippedTokens,
            mostLovedCoffeeIDs: mostLoved,
            insights: insights
        )
    }

    private static func topTokens(from logs: [BrewLog], coffeeByID: [UUID: Coffee]) -> [String] {
        var counts: [String: Int] = [:]
        for log in logs {
            guard let coffee = coffeeByID[log.coffeeID] else { continue }
            ([coffee.origin, coffee.process] + coffee.flavorNotes).forEach { token in
                let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return }
                counts[normalized, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private static func mostLovedCoffeeIDs(from logs: [BrewLog]) -> [UUID] {
        var scores: [UUID: Int] = [:]
        for log in logs {
            guard log.verdict == .loved else {
                continue
            }
            scores[log.coffeeID, default: 0] += 1
        }
        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key.uuidString < rhs.key.uuidString }
                return lhs.value > rhs.value
            }
            .prefix(3)
            .map(\.key)
    }
}
