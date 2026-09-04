import Foundation
import Observation

public struct CoffeeJournalSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var coffees: [Coffee]
    public var bags: [CoffeeBag]
    public var brewLogs: [BrewLog]

    public init(
        schemaVersion: Int = 1,
        coffees: [Coffee],
        bags: [CoffeeBag],
        brewLogs: [BrewLog]
    ) {
        self.schemaVersion = schemaVersion
        self.coffees = coffees
        self.bags = bags
        self.brewLogs = brewLogs
    }
}

public struct PastCoffeeRecord: Identifiable, Equatable, Sendable {
    public var id: UUID { coffee.id }
    public let coffee: Coffee
    public let latestFinishedAt: Date?
    public let legacyOrder: Int
    public let coffeeOrder: Int
    public let roasterKey: String
    public let displayRoaster: String
    public let finishedBagCount: Int
}

public struct PastRoasterGroup: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let displayName: String
    public let coffeeCount: Int
    public let latestCoffeeName: String
    public let latestFinishedAt: Date?
}

@Observable
public final class CoffeeJournalStore {
    public private(set) var coffees: [Coffee]
    public private(set) var bags: [CoffeeBag]
    public private(set) var brewLogs: [BrewLog]
    @ObservationIgnored public var onChange: ((CoffeeJournalSnapshot) -> Void)?

    public init(
        coffees: [Coffee] = [],
        bags: [CoffeeBag] = [],
        brewLogs: [BrewLog] = []
    ) {
        self.coffees = coffees
        self.bags = bags
        self.brewLogs = brewLogs
    }

    public convenience init(snapshot: CoffeeJournalSnapshot) {
        self.init(
            coffees: snapshot.coffees,
            bags: snapshot.bags,
            brewLogs: snapshot.brewLogs
        )
    }

    public var snapshot: CoffeeJournalSnapshot {
        CoffeeJournalSnapshot(
            coffees: coffees,
            bags: bags,
            brewLogs: brewLogs
        )
    }

    public var activeBags: [CoffeeBag] {
        bags
            .enumerated()
            .filter { $0.element.status == .active && $0.element.remainingGrams > 0 }
            .sorted { lhs, rhs in
                switch (lhs.element.roastDate, rhs.element.roastDate) {
                case let (leftDate?, rightDate?):
                    return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate < rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    public var finishedBags: [CoffeeBag] {
        bags
            .enumerated()
            .filter { $0.element.isFinished }
            .sorted { lhs, rhs in
                switch (lhs.element.finishedAt, rhs.element.finishedAt) {
                case let (left?, right?):
                    return left == right ? lhs.offset > rhs.offset : left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset > rhs.offset
                }
            }
            .map(\.element)
    }

    public var recentLogs: [BrewLog] {
        brewLogs.sorted { $0.date > $1.date }
    }

    public func coffeesNeedingArtworkGeneration(at date: Date = Date()) -> [Coffee] {
        coffees.filter { coffee in
            guard coffee.artworkInputSignature != nil,
                  coffee.artworkJob?.status == .queued else {
                return false
            }
            guard let nextRetryAt = coffee.artworkJob?.nextRetryAt else {
                return true
            }
            return nextRetryAt <= date
        }
    }

    @discardableResult
    public func addCoffee(from draft: BagScanDraft) -> CoffeeBag {
        let matchedCoffee = matchingCoffee(for: draft.coffee)
        let coffeeID = matchedCoffee?.id ?? draft.coffee.id
        if matchedCoffee == nil {
            var newCoffee = draft.coffee
            if newCoffee.addedAt == nil {
                newCoffee.addedAt = Date()
            }
            if newCoffee.artworkInputSignature != nil, newCoffee.flavorArtwork == nil {
                newCoffee.artworkJob = ArtworkJobState(status: .queued, requestID: UUID())
            }
            coffees.append(newCoffee)
        }
        let totalGrams = draft.totalGrams ?? 0
        let isInitiallyFinished = totalGrams <= 0

        let bag = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: draft.roastDate,
            totalGrams: totalGrams,
            remainingGrams: totalGrams,
            status: isInitiallyFinished ? .finished : .active,
            finishedAt: isInitiallyFinished ? Date() : nil,
            restDays: draft.restDays,
            brewAdvice: draft.brewAdvice,
            photoAssetIdentifier: draft.photoAssetIdentifier
        )
        bags.append(bag)
        persist()
        return bag
    }

    @discardableResult
    public func reactivateCoffee(
        coffeeID: UUID,
        roastDate: Date,
        totalGrams: Double,
        restDays: Int? = nil,
        brewAdvice: String = "",
        photoAssetIdentifier: String? = nil
    ) -> CoffeeBag {
        let normalizedTotalGrams = max(0, totalGrams)
        let isInitiallyFinished = normalizedTotalGrams <= 0
        let bag = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: roastDate,
            totalGrams: normalizedTotalGrams,
            remainingGrams: normalizedTotalGrams,
            status: isInitiallyFinished ? .finished : .active,
            finishedAt: isInitiallyFinished ? Date() : nil,
            restDays: restDays,
            brewAdvice: brewAdvice,
            photoAssetIdentifier: photoAssetIdentifier
        )
        bags.append(bag)
        persist()
        return bag
    }

    @discardableResult
    public func logCup(
        coffeeID: UUID,
        bagID: UUID?,
        verdict: Verdict,
        tastingNote: String,
        gramsUsed: Double? = nil,
        details: BrewDetails? = nil,
        date: Date = Date()
    ) -> BrewLog {
        let log = BrewLog(
            coffeeID: coffeeID,
            bagID: bagID,
            date: date,
            verdict: verdict,
            tastingNote: tastingNote,
            gramsUsed: gramsUsed,
            details: details
        )
        brewLogs.append(log)

        if let bagID, let gramsUsed {
            reduceRemainingGrams(on: bagID, by: gramsUsed, at: date)
        }

        if let coffeeIndex = coffees.firstIndex(where: { $0.id == coffeeID }) {
            coffees[coffeeIndex].verdict = mergedVerdict(existing: coffees[coffeeIndex].verdict, new: verdict)
        }

        persist()
        return log
    }

    public func finishBag(_ bagID: UUID, at date: Date = Date()) {
        guard let index = bags.firstIndex(where: { $0.id == bagID }) else { return }
        let wasFinished = bags[index].isFinished
        bags[index].remainingGrams = 0
        bags[index].status = .finished
        if !wasFinished, bags[index].finishedAt == nil {
            bags[index].finishedAt = date
        }
        persist()
    }

    public func updateCoffee(_ coffee: Coffee) {
        guard let index = coffees.firstIndex(where: { $0.id == coffee.id }) else { return }
        let previous = coffees[index]
        var updated = coffee
        if previous.artworkInputSignature != updated.artworkInputSignature {
            if updated.artworkInputSignature != nil {
                updated.artworkJob = ArtworkJobState(
                    status: .queued,
                    requestID: UUID(),
                    attemptCount: previous.artworkJob?.attemptCount ?? 0,
                    deferredFailureCount: previous.artworkJob?.deferredFailureCount ?? 0
                )
            } else {
                updated.artworkJob = nil
            }
        }
        coffees[index] = updated
        persist()
    }

    @discardableResult
    public func updateFlavorArtwork(
        coffeeID: UUID,
        artwork: FlavorArtwork,
        matching requestID: UUID? = nil
    ) -> Bool {
        guard let index = coffees.firstIndex(where: { $0.id == coffeeID }) else { return false }
        if let requestID, coffees[index].artworkJob?.requestID != requestID {
            return false
        }
        coffees[index].flavorArtwork = artwork
        let attempts = coffees[index].artworkJob?.attemptCount ?? 1
        coffees[index].artworkJob = ArtworkJobState(
            status: .succeeded,
            requestID: requestID ?? coffees[index].artworkJob?.requestID,
            attemptCount: attempts,
            deferredFailureCount: 0,
            lastAttemptAt: Date()
        )
        persist()
        return true
    }

    @discardableResult
    public func updateArtworkJob(
        coffeeID: UUID,
        state: ArtworkJobState,
        matching requestID: UUID? = nil
    ) -> Bool {
        guard let index = coffees.firstIndex(where: { $0.id == coffeeID }) else { return false }
        if let requestID, coffees[index].artworkJob?.requestID != requestID {
            return false
        }
        coffees[index].artworkJob = state
        persist()
        return true
    }

    @discardableResult
    public func queueArtworkGeneration(
        coffeeID: UUID,
        replacingCurrentRequest: Bool = false,
        resetDeferredFailures: Bool = false,
        forceGeneration: Bool = false
    ) -> UUID? {
        guard let index = coffees.firstIndex(where: { $0.id == coffeeID }) else { return nil }
        guard coffees[index].artworkInputSignature != nil else {
            coffees[index].artworkJob = nil
            persist()
            return nil
        }
        if !replacingCurrentRequest,
           coffees[index].flavorArtwork != nil,
           coffees[index].artworkJob?.status == .succeeded {
            return nil
        }
        if !replacingCurrentRequest,
           let state = coffees[index].artworkJob,
           (state.status == .queued || state.status == .generating),
           let requestID = state.requestID {
            return requestID
        }
        let previous = coffees[index].artworkJob
        let requestID = UUID()
        coffees[index].artworkJob = ArtworkJobState(
            status: .queued,
            requestID: requestID,
            forceGeneration: forceGeneration,
            attemptCount: previous?.attemptCount ?? 0,
            deferredFailureCount: resetDeferredFailures ? 0 : previous?.deferredFailureCount ?? 0
        )
        persist()
        return requestID
    }

    @discardableResult
    public func requeueArtworkRequest(
        coffeeID: UUID,
        requestID: UUID,
        reason: String,
        at date: Date = Date()
    ) -> Bool {
        guard let index = coffees.firstIndex(where: { $0.id == coffeeID }),
              var state = coffees[index].artworkJob,
              state.requestID == requestID else {
            return false
        }
        state.status = .queued
        state.deferredFailureCount += 1
        state.nextRetryAt = date.addingTimeInterval(Self.artworkRetryDelay(for: state.deferredFailureCount))
        state.lastError = reason
        coffees[index].artworkJob = state
        persist()
        return true
    }

    public func earliestArtworkWakeDate(at date: Date = Date()) -> Date? {
        coffees.compactMap { coffee -> Date? in
            guard coffee.artworkInputSignature != nil,
                  coffee.artworkJob?.status == .queued else { return nil }
            return coffee.artworkJob?.nextRetryAt ?? date
        }.min()
    }

    public static func artworkRetryDelay(for deferredFailureCount: Int) -> TimeInterval {
        switch deferredFailureCount {
        case ...1: 5 * 60
        case 2: 30 * 60
        case 3: 2 * 60 * 60
        default: 12 * 60 * 60
        }
    }

    public func recoverArtworkJobs() {
        var changed = false
        for index in coffees.indices {
            guard coffees[index].artworkInputSignature != nil else {
                if coffees[index].artworkJob?.status == .queued || coffees[index].artworkJob?.status == .generating {
                    coffees[index].artworkJob = nil
                    changed = true
                }
                continue
            }

            if coffees[index].artworkJob?.status == .generating {
                var state = coffees[index].artworkJob ?? ArtworkJobState(status: .queued)
                state.status = .queued
                state.requestID = state.requestID ?? UUID()
                state.nextRetryAt = nil
                state.lastError = "Artwork generation was interrupted."
                coffees[index].artworkJob = state
                changed = true
            } else if coffees[index].artworkJob?.status == .queued,
                      coffees[index].artworkJob?.requestID == nil {
                coffees[index].artworkJob?.requestID = UUID()
                changed = true
            } else if coffees[index].flavorArtwork == nil,
                      coffees[index].artworkJob == nil {
                coffees[index].artworkJob = ArtworkJobState(status: .queued, requestID: UUID())
                changed = true
            }
        }
        if changed { persist() }
    }

    public func deleteBrewLog(_ logID: UUID) {
        guard let index = brewLogs.firstIndex(where: { $0.id == logID }) else { return }
        brewLogs.remove(at: index)
        persist()
    }

    public func updateBag(_ bag: CoffeeBag, at date: Date = Date()) {
        guard let index = bags.firstIndex(where: { $0.id == bag.id }) else { return }
        let wasFinished = bags[index].isFinished
        var updatedBag = bag
        updatedBag.remainingGrams = max(0, min(updatedBag.remainingGrams, updatedBag.totalGrams))
        if updatedBag.remainingGrams <= 0 {
            updatedBag.status = .finished
        }
        let isFinished = updatedBag.isFinished
        if !wasFinished, isFinished, updatedBag.finishedAt == nil {
            updatedBag.finishedAt = date
        } else if wasFinished, !isFinished {
            updatedBag.finishedAt = nil
        }
        bags[index] = updatedBag
        persist()
    }

    public func pastCoffees(
        matching query: String = "",
        roasterKey: String? = nil,
        limit: Int = 50
    ) -> [PastCoffeeRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allPastCoffeeRecords()
            .filter { record in
                if let roasterKey, record.roasterKey != roasterKey { return false }
                guard !normalizedQuery.isEmpty else { return true }
                return searchableText(for: record.coffee)
                    .localizedCaseInsensitiveContains(normalizedQuery)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func pastRoasterGroups(matching query: String = "") -> [PastRoasterGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Dictionary(grouping: allPastCoffeeRecords(), by: \.roasterKey)
        return groups.compactMap { key, records -> (PastRoasterGroup, PastCoffeeRecord)? in
            guard let latest = records.first else { return nil }
            let group = PastRoasterGroup(
                key: key,
                displayName: latest.displayRoaster,
                coffeeCount: records.count,
                latestCoffeeName: latest.coffee.name,
                latestFinishedAt: latest.latestFinishedAt
            )
            guard normalizedQuery.isEmpty || group.displayName.localizedCaseInsensitiveContains(normalizedQuery) else {
                return nil
            }
            return (group, latest)
        }
        .sorted { lhs, rhs in
            if lhs.0.coffeeCount != rhs.0.coffeeCount {
                return lhs.0.coffeeCount > rhs.0.coffeeCount
            }
            if isPastRecord(lhs.1, newerThan: rhs.1) { return true }
            if isPastRecord(rhs.1, newerThan: lhs.1) { return false }
            return lhs.0.displayName.localizedStandardCompare(rhs.0.displayName) == .orderedAscending
        }
        .map(\.0)
    }

    public func coffee(for id: UUID) -> Coffee? {
        coffees.first { $0.id == id }
    }

    public func bag(for id: UUID?) -> CoffeeBag? {
        guard let id else { return nil }
        return bags.first { $0.id == id }
    }

    public func logs(for coffeeID: UUID) -> [BrewLog] {
        brewLogs
            .filter { $0.coffeeID == coffeeID }
            .sorted { $0.date > $1.date }
    }

    public func activeBag(for coffeeID: UUID) -> CoffeeBag? {
        activeBags.first { $0.coffeeID == coffeeID }
    }

    private func reduceRemainingGrams(on bagID: UUID, by gramsUsed: Double, at date: Date) {
        guard let index = bags.firstIndex(where: { $0.id == bagID }) else { return }
        let wasFinished = bags[index].isFinished
        bags[index].remainingGrams = max(0, bags[index].remainingGrams - gramsUsed)
        if bags[index].remainingGrams == 0 {
            bags[index].status = .finished
            if !wasFinished, bags[index].finishedAt == nil {
                bags[index].finishedAt = date
            }
        }
    }

    private func allPastCoffeeRecords() -> [PastCoffeeRecord] {
        let bagIndicesByCoffee = Dictionary(grouping: bags.enumerated(), by: { $0.element.coffeeID })
        let activeCoffeeIDs = Set(activeBags.map(\.coffeeID))
        return coffees.enumerated().compactMap { coffeeOrder, coffee in
            guard !activeCoffeeIDs.contains(coffee.id) else { return nil }
            let finished = (bagIndicesByCoffee[coffee.id] ?? []).filter { $0.element.isFinished }
            guard !finished.isEmpty else { return nil }
            let latestFinishedAt = finished.compactMap { $0.element.finishedAt }.max()
            let legacyOrder = finished.map(\.offset).max() ?? -1
            return PastCoffeeRecord(
                coffee: coffee,
                latestFinishedAt: latestFinishedAt,
                legacyOrder: legacyOrder,
                coffeeOrder: coffeeOrder,
                roasterKey: Self.normalizedRoasterKey(coffee.roaster),
                displayRoaster: Self.displayRoaster(coffee.roaster),
                finishedBagCount: finished.count
            )
        }
        .sorted { isPastRecord($0, newerThan: $1) }
    }

    private func isPastRecord(_ lhs: PastCoffeeRecord, newerThan rhs: PastCoffeeRecord) -> Bool {
        switch (lhs.latestFinishedAt, rhs.latestFinishedAt) {
        case let (left?, right?):
            if left != right { return left > right }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if lhs.legacyOrder != rhs.legacyOrder { return lhs.legacyOrder > rhs.legacyOrder }
        }
        return lhs.coffeeOrder > rhs.coffeeOrder
    }

    private func searchableText(for coffee: Coffee) -> String {
        ([
            coffee.roaster,
            coffee.name,
            coffee.origin,
            coffee.farm,
            coffee.variety,
            coffee.process,
            coffee.notes
        ] + coffee.flavorNotes).joined(separator: " ")
    }

    private static func normalizedRoasterKey(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "__unknown__" }
        let locale = Locale(identifier: "en_US_POSIX")
        return collapsed
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func displayRoaster(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? "Unknown Roaster" : collapsed
    }

    private func matchingCoffee(for candidate: Coffee) -> Coffee? {
        coffees.first {
            coffeeMatchComponent($0.roaster) == coffeeMatchComponent(candidate.roaster) &&
            coffeeMatchComponent($0.origin) == coffeeMatchComponent(candidate.origin) &&
            coffeeMatchComponent($0.process) == coffeeMatchComponent(candidate.process) &&
            coffeeMatchComponent($0.variety) == coffeeMatchComponent(candidate.variety)
        }
    }

    private func coffeeMatchComponent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func mergedVerdict(existing: Verdict?, new: Verdict) -> Verdict {
        guard let existing else { return new }
        let rank: [Verdict: Int] = [.disliked: 0, .ok: 1, .liked: 2, .loved: 3]
        return (rank[new, default: 0] >= rank[existing, default: 0]) ? new : existing
    }

    private func persist() {
        onChange?(snapshot)
    }
}

public struct MockBagScanner: Sendable {
    public init() {}

    public func scanSampleBag() -> BagScanDraft {
        BagScanDraft(
            coffee: Coffee(
                roaster: "La Cabra",
                name: "Colombia Huila",
                origin: "Huila, Colombia",
                variety: "Caturra",
                process: "Washed",
                flavorNotes: ["red apple", "brown sugar", "jasmine"],
                verdict: nil,
                notes: "Prefilled from bag photo. Please review before saving."
            ),
            roastDate: Calendar.current.date(byAdding: .day, value: -8, to: Date()),
            totalGrams: 250,
            restDays: 10,
            brewAdvice: "Start around 1:16, medium-fine grind, and revisit after day 10."
        )
    }

    public func manualFallbackDraft() -> BagScanDraft {
        BagScanDraft(
            coffee: Coffee(
                roaster: "",
                name: "",
                origin: "",
                variety: "",
                process: "",
                flavorNotes: [],
                verdict: nil,
                notes: ""
            ),
            totalGrams: 250
        )
    }
}
