import Foundation

public enum BeanExplorerScoringError: Error, Equatable, Sendable {
    case invalidProfile
    case insufficientCandidates
}

public struct BeanExplorerScoreCandidate: Equatable, Sendable {
    public let id: String
    public let roaster: String
    public let name: String
    public let origin: String
    public let process: String
    public let descriptors: [String]
    public let isConfirmed: Bool
    public let confirmedFields: Set<String>
    public let fieldProvenance: [String: BeanExplorerFieldProvenance]
    public let unresolvedFields: Set<String>

    public init(
        id: String,
        roaster: String,
        name: String,
        origin: String,
        process: String,
        descriptors: [String],
        isConfirmed: Bool,
        confirmedFields: Set<String> = [],
        fieldProvenance: [String: BeanExplorerFieldProvenance] = [:],
        unresolvedFields: Set<String> = []
    ) {
        self.id = id
        self.roaster = roaster
        self.name = name
        self.origin = origin
        self.process = process
        self.descriptors = descriptors
        self.isConfirmed = isConfirmed
        self.confirmedFields = confirmedFields
        self.fieldProvenance = fieldProvenance
        self.unresolvedFields = unresolvedFields
    }
}

public struct BeanExplorerProfile: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mode: String
    public let datasetGeneratedAt: String
    public let profileId: String
    public let scorerVersion: String
    public let lexiconVersion: String
    public let privacy: Privacy
    public let evidenceBase: EvidenceBase
    public let statistics: Statistics
    public let lexicon: Lexicon
    public let scoring: Scoring

    public struct Privacy: Decodable, Equatable, Sendable {
        public let containsRawObservations: Bool
        public let containsCoffeeIdentities: Bool
        public let containsNotesDatesOrBrewDetails: Bool
        public let historyAdjustmentAvailable: Bool
        public let roasterAffinityAvailable: Bool
    }

    public struct EvidenceBase: Decodable, Equatable, Sendable {
        public let ratedObservations: Int
        public let ratingDistribution: [String: Int]
    }

    public struct Statistics: Decodable, Equatable, Sendable {
        public let categoryStats: [FeatureStat]
        public let originStats: [FeatureStat]
        public let processStats: [FeatureStat]
        public let roasterStats: [FeatureStat]
        public let topTierFamilies: [TopTierFamily]
    }

    public struct FeatureStat: Decodable, Equatable, Sendable {
        public let feature: String
        public let n: Int
        public let weightedRating: Double?
    }

    public struct TopTierFamily: Decodable, Equatable, Sendable {
        public let category: String
        public let topTierCount: Int
    }

    public struct Lexicon: Decodable, Equatable, Sendable {
        public let categoryTerms: [String: [String]]
        public let qualityTerms: [String: [String]]
    }

    public struct Scoring: Decodable, Equatable, Sendable {
        public let ratingScale: RangeConfig
        public let fitWeights: FitWeights
        public let unknownFit: Double
        public let qualityBonus: QualityBonus
        public let topTierBonus: TopTierBonus
        public let roasterBonus: RoasterBonus
        public let novelty: Novelty
        public let frontier: Frontier
        public let nearTieFitDelta: Double
        public let history: History
    }

    public struct RangeConfig: Decodable, Equatable, Sendable {
        public let min: Double
        public let max: Double
    }

    public struct FitWeights: Decodable, Equatable, Sendable {
        public let sensory: Double
        public let origin: Double
        public let process: Double
    }

    public struct QualityBonus: Decodable, Equatable, Sendable {
        public let cap: Double
        public let signals: [String: Double]
    }

    public struct TopTierBonus: Decodable, Equatable, Sendable {
        public let perFamily: Double
        public let cap: Double
    }

    public struct RoasterBonus: Decodable, Equatable, Sendable {
        public let scale: Double
        public let cap: Double
    }

    public struct Novelty: Decodable, Equatable, Sendable {
        public let weights: NoveltyWeights
        public let categoryFullFamiliarityObservations: Double
        public let originFamiliarity: Familiarity
        public let processFamiliarity: Familiarity
    }

    public struct NoveltyWeights: Decodable, Equatable, Sendable {
        public let category: Double
        public let origin: Double
        public let process: Double
    }

    public struct Familiarity: Decodable, Equatable, Sendable {
        public let known: Double
        public let unknown: Double
    }

    public struct Frontier: Decodable, Equatable, Sendable {
        public let minFit: Double
        public let noveltyWeight: Double
        public let fitWeight: Double
        public let minTopTierCount: Int
        public let minCategoryObservations: Int
    }

    public struct History: Decodable, Equatable, Sendable {
        public let mode: String
    }

    public static func decode(_ data: Data) throws -> BeanExplorerProfile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

public struct BeanExplorerExclusion: Equatable, Sendable {
    public let candidateID: String
    public let reason: String
}

public struct BeanExplorerFamiliarBridge: Equatable, Sendable {
    public let familyID: String
    public let familyName: String
    public let lovedCount: Int
    public let observations: Int
}

public struct BeanExplorerScore: Identifiable, Equatable, Sendable {
    public var id: String { candidateID }
    public let candidateID: String
    public let roaster: String
    public let name: String
    public let fit: Double
    public let novelty: Double
    public let matchedFamilies: [String]
    public let familiarBridges: [BeanExplorerFamiliarBridge]
    public let noveltyDimensions: [String]
}

public struct BeanExplorerFitBand: Identifiable, Equatable, Sendable {
    public let id: Int
    public let scores: [BeanExplorerScore]
    public var isSimilarFit: Bool { scores.count > 1 }
}

public struct BeanExplorerComparison: Equatable, Sendable {
    public let profileID: String
    public let scorerVersion: String
    public let datasetGeneratedAt: String
    public let ratedObservations: Int
    public let ranking: [BeanExplorerScore]
    public let fitBands: [BeanExplorerFitBand]
    public let bestSupportedMatch: BeanExplorerScore
    public let frontierPick: BeanExplorerScore?
    public let excluded: [BeanExplorerExclusion]
}

struct BeanExplorerResolvedScores: Equatable, Sendable {
    let ranking: [BeanExplorerScore]
    let fitBands: [BeanExplorerFitBand]
    let bestSupportedMatch: BeanExplorerScore
    let frontierPick: BeanExplorerScore?
}

public struct BeanExplorerScorer: Sendable {
    public let profile: BeanExplorerProfile

    public init(profile: BeanExplorerProfile) throws {
        guard Self.profileIsValid(profile) else {
            throw BeanExplorerScoringError.invalidProfile
        }
        self.profile = profile
    }

    public func compare(_ candidates: [BeanExplorerScoreCandidate]) throws -> BeanExplorerComparison {
        var rows: [BeanExplorerScore] = []
        var excluded: [BeanExplorerExclusion] = []

        for candidate in candidates {
            if let reason = exclusionReason(candidate) {
                excluded.append(.init(candidateID: candidate.id, reason: reason))
            } else {
                rows.append(score(candidate))
            }
        }

        guard !rows.isEmpty else {
            throw BeanExplorerScoringError.insufficientCandidates
        }

        let resolved = Self.resolveScoredRows(rows, profile: profile)

        return BeanExplorerComparison(
            profileID: profile.profileId,
            scorerVersion: profile.scorerVersion,
            datasetGeneratedAt: profile.datasetGeneratedAt,
            ratedObservations: profile.evidenceBase.ratedObservations,
            ranking: resolved.ranking,
            fitBands: resolved.fitBands,
            bestSupportedMatch: resolved.bestSupportedMatch,
            frontierPick: resolved.frontierPick,
            excluded: excluded
        )
    }

    static func resolveScoredRows(
        _ rows: [BeanExplorerScore],
        profile: BeanExplorerProfile
    ) -> BeanExplorerResolvedScores {
        let ranked = rows.sorted {
            if $0.fit != $1.fit { return $0.fit > $1.fit }
            if $0.novelty != $1.novelty { return $0.novelty > $1.novelty }
            return $0.candidateID < $1.candidateID
        }
        precondition(!ranked.isEmpty)
        let best = ranked[0]
        let frontierConfig = profile.scoring.frontier
        let frontier = ranked
            .filter {
                $0.candidateID != best.candidateID &&
                $0.fit >= frontierConfig.minFit &&
                !$0.familiarBridges.isEmpty
            }
            .max {
                let lhsBlend = $0.novelty * frontierConfig.noveltyWeight + $0.fit * frontierConfig.fitWeight
                let rhsBlend = $1.novelty * frontierConfig.noveltyWeight + $1.fit * frontierConfig.fitWeight
                if lhsBlend != rhsBlend { return lhsBlend < rhsBlend }
                if $0.fit != $1.fit { return $0.fit < $1.fit }
                return $0.candidateID > $1.candidateID
            }

        let fitBands = Self.makeFitBands(ranked, threshold: profile.scoring.nearTieFitDelta)
        return BeanExplorerResolvedScores(
            ranking: ranked,
            fitBands: fitBands,
            bestSupportedMatch: best,
            frontierPick: frontier
        )
    }

    public func exclusionReason(_ candidate: BeanExplorerScoreCandidate) -> String? {
        guard candidate.isConfirmed else { return "Confirm this candidate after reviewing the extracted fields." }
        guard candidate.unresolvedFields.isEmpty else { return "Resolve uncertain score inputs before comparison." }
        guard !normalized(candidate.roaster).isEmpty else { return "Roaster is required." }
        guard !normalized(candidate.name).isEmpty else { return "Full coffee name is required." }
        guard !normalized(candidate.origin).isEmpty else { return "Origin is required." }
        guard !normalized(candidate.process).isEmpty else { return "Process is required." }
        guard !matchedKeys(parts: candidate.descriptors, vocabulary: profile.lexicon.categoryTerms).isEmpty else {
            return "Add at least one seller flavor note recognized by the profile."
        }
        let scoreFields: Set<String> = ["roaster", "name", "origin", "process", "flavor_notes"]
        guard scoreFields.isSubset(of: candidate.confirmedFields) else {
            return "Confirm every field used by the scorer."
        }
        guard scoreFields.allSatisfy({ candidate.fieldProvenance[$0] != nil }) else {
            return "Every score input needs visible or user-entered provenance."
        }
        return nil
    }

    private func score(_ candidate: BeanExplorerScoreCandidate) -> BeanExplorerScore {
        let config = profile.scoring
        let categories = matchedKeys(parts: candidate.descriptors, vocabulary: profile.lexicon.categoryTerms)
        let qualitySignals = matchedKeys(parts: candidate.descriptors, vocabulary: profile.lexicon.qualityTerms)
        let categoryStats = statMap(profile.statistics.categoryStats)
        let originStats = statMap(profile.statistics.originStats)
        let processStats = statMap(profile.statistics.processStats)
        let roasterStats = statMap(profile.statistics.roasterStats)

        let familyScores = categories.compactMap { category -> Double? in
            guard let rating = categoryStats[normalized(category)]?.weightedRating else { return nil }
            return normalizedRating(rating)
        }
        let sensoryFit = familyScores.isEmpty ? config.unknownFit : familyScores.reduce(0, +) / Double(familyScores.count)
        let originRow = originStats[normalized(candidate.origin)]
        let processRow = processStats[normalized(candidate.process)]
        let originFit = originRow?.weightedRating.map(normalizedRating) ?? config.unknownFit
        let processFit = processRow?.weightedRating.map(normalizedRating) ?? config.unknownFit
        let baseFit = sensoryFit * config.fitWeights.sensory + originFit * config.fitWeights.origin + processFit * config.fitWeights.process

        let qualityBonus = min(config.qualityBonus.cap, qualitySignals.reduce(0) { $0 + (config.qualityBonus.signals[$1] ?? 0) })
        let topTier = Set(profile.statistics.topTierFamilies.map(\.category))
        let topTierHits = topTier.intersection(categories)
        let topTierBonus = min(config.topTierBonus.cap, config.topTierBonus.perFamily * Double(topTierHits.count))
        var roasterBonus = 0.0
        if let rating = roasterStats[normalized(candidate.roaster)]?.weightedRating {
            let scaled = normalizedRating(rating)
            roasterBonus = max(-config.roasterBonus.cap, min(config.roasterBonus.cap, (scaled - 50) * config.roasterBonus.scale))
        }
        let fit = min(100, baseFit + qualityBonus + topTierBonus + roasterBonus)

        let familyFamiliarity = categories.compactMap { category -> Double? in
            guard let row = categoryStats[normalized(category)] else { return nil }
            return min(1, Double(row.n) / config.novelty.categoryFullFamiliarityObservations) * 100
        }
        let categoryFamiliarity = familyFamiliarity.isEmpty ? 0 : familyFamiliarity.reduce(0, +) / Double(familyFamiliarity.count)
        let originFamiliarity = originRow == nil ? config.novelty.originFamiliarity.unknown : config.novelty.originFamiliarity.known
        let processFamiliarity = processRow == nil ? config.novelty.processFamiliarity.unknown : config.novelty.processFamiliarity.known
        let novelty = max(0, min(100, 100 - (
            categoryFamiliarity * config.novelty.weights.category +
            originFamiliarity * config.novelty.weights.origin +
            processFamiliarity * config.novelty.weights.process
        )))

        let bridges = categories.compactMap { category -> BeanExplorerFamiliarBridge? in
            guard let tier = profile.statistics.topTierFamilies.first(where: { $0.category == category }),
                  let observations = categoryStats[normalized(category)]?.n,
                  Self.bridgeQualifies(
                    topTierCount: tier.topTierCount,
                    observations: observations,
                    profile: profile
                  ) else { return nil }
            return .init(
                familyID: category,
                familyName: Self.familyName(category),
                lovedCount: tier.topTierCount,
                observations: observations
            )
        }
        let noveltyDimensions = [
            originRow == nil ? "an origin absent from this profile snapshot" : nil,
            processRow == nil ? "a process absent from this profile snapshot" : nil,
            categoryFamiliarity < 100 ? "flavor families with sparse snapshot coverage" : nil,
        ].compactMap { $0 }

        return BeanExplorerScore(
            candidateID: candidate.id,
            roaster: candidate.roaster,
            name: candidate.name,
            fit: rounded(fit),
            novelty: rounded(novelty),
            matchedFamilies: categories.map(Self.familyName),
            familiarBridges: bridges,
            noveltyDimensions: noveltyDimensions
        )
    }

    private func normalizedRating(_ value: Double) -> Double {
        let range = profile.scoring.ratingScale
        return max(0, min(100, ((value - range.min) / (range.max - range.min)) * 100))
    }

    private func statMap(_ rows: [BeanExplorerProfile.FeatureStat]) -> [String: BeanExplorerProfile.FeatureStat] {
        Dictionary(uniqueKeysWithValues: rows.map { (normalized($0.feature), $0) })
    }

    private func matchedKeys(parts: [String], vocabulary: [String: [String]]) -> [String] {
        let haystack = parts.map(normalized).joined(separator: " | ")
        return vocabulary.keys.filter { key in
            vocabulary[key, default: []].contains { termMatches(haystack: haystack, term: $0) }
        }.sorted()
    }

    private func termMatches(haystack: String, term: String) -> Bool {
        let needle = normalized(term)
        guard !needle.isEmpty else { return false }
        let requiresBoundary = needle.unicodeScalars.contains { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
        }
        guard requiresBoundary else { return haystack.contains(needle) }

        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex || !isASCIIAlphanumeric(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex || !isASCIIAlphanumeric(haystack[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private func normalized(_ value: String) -> String {
        Self.contractNormalize(value)
    }

    private func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    private func rounded(_ value: Double) -> Double {
        Self.contractRoundTenth(value)
    }

    private static func familyName(_ id: String) -> String {
        [
            "fruit.citrus": "Citrus",
            "fruit.stone": "Stone fruit",
            "fruit.berry": "Berries",
            "fruit.tropical": "Tropical fruit",
            "fruit.dried": "Dried fruit",
            "fruit.melon": "Melon",
            "fruit.grape": "Grape & wine",
            "floral": "Floral",
            "spice_herbal": "Spice & herbs",
            "tea": "Tea",
            "sweet.browning": "Caramel sweetness",
            "fermented_alcoholic": "Fermented & alcoholic",
        ][id] ?? id
    }

    private static func profileIsValid(_ profile: BeanExplorerProfile) -> Bool {
        let fitTotal = profile.scoring.fitWeights.sensory + profile.scoring.fitWeights.origin + profile.scoring.fitWeights.process
        let noveltyTotal = profile.scoring.novelty.weights.category + profile.scoring.novelty.weights.origin + profile.scoring.novelty.weights.process
        let frontierTotal = profile.scoring.frontier.noveltyWeight + profile.scoring.frontier.fitWeight
        let allStats = profile.statistics.categoryStats + profile.statistics.originStats + profile.statistics.processStats
        let normalizedFeatures = allStats.map { contractNormalized($0.feature) }
        return profile.schemaVersion == 1 &&
            profile.mode == "portable_profile" &&
            profile.profileId.count == 64 &&
            profile.scorerVersion.count == 64 &&
            profile.lexiconVersion.count == 64 &&
            abs(fitTotal - 1) < 0.000_001 &&
            abs(noveltyTotal - 1) < 0.000_001 &&
            abs(frontierTotal - 1) < 0.000_001 &&
            profile.scoring.fitWeights.sensory == 0.75 &&
            profile.scoring.fitWeights.origin == 0.15 &&
            profile.scoring.fitWeights.process == 0.10 &&
            profile.scoring.novelty.weights.category == 0.50 &&
            profile.scoring.novelty.weights.origin == 0.25 &&
            profile.scoring.novelty.weights.process == 0.25 &&
            profile.scoring.frontier.minFit == 60.0 &&
            profile.scoring.frontier.noveltyWeight == 0.55 &&
            profile.scoring.frontier.fitWeight == 0.45 &&
            profile.scoring.ratingScale.max > profile.scoring.ratingScale.min &&
            profile.scoring.nearTieFitDelta == 1.5 &&
            profile.scoring.frontier.minTopTierCount == 3 &&
            profile.scoring.frontier.minCategoryObservations == 6 &&
            profile.scoring.history.mode == "unavailable_without_private" &&
            !profile.privacy.containsRawObservations &&
            !profile.privacy.containsCoffeeIdentities &&
            !profile.privacy.containsNotesDatesOrBrewDetails &&
            !profile.privacy.historyAdjustmentAvailable &&
            !profile.privacy.roasterAffinityAvailable &&
            profile.statistics.roasterStats.isEmpty &&
            Set(normalizedFeatures).count == normalizedFeatures.count &&
            !profile.lexicon.categoryTerms.isEmpty
    }

    static func makeFitBands(
        _ rows: [BeanExplorerScore],
        threshold: Double
    ) -> [BeanExplorerFitBand] {
        var grouped: [[BeanExplorerScore]] = []
        var anchorFit: Double?
        for row in rows {
            if anchorFit == nil || (anchorFit! - row.fit) > threshold {
                grouped.append([])
                anchorFit = row.fit
            }
            grouped[grouped.count - 1].append(row)
        }
        return grouped.enumerated().map { .init(id: $0.offset, scores: $0.element) }
    }

    static func bridgeQualifies(
        topTierCount: Int,
        observations: Int,
        profile: BeanExplorerProfile
    ) -> Bool {
        topTierCount >= profile.scoring.frontier.minTopTierCount &&
            observations >= profile.scoring.frontier.minCategoryObservations
    }

    private static func contractNormalized(_ value: String) -> String {
        contractNormalize(value)
    }

    public static func contractNormalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func contractRoundTenth(_ value: Double) -> Double {
        (value * 10).rounded(.toNearestOrAwayFromZero) / 10
    }
}
