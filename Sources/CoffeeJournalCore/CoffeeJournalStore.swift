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
            .filter { $0.status == .active && $0.remainingGrams > 0 }
            .sorted { ($0.roastDate ?? .distantPast) > ($1.roastDate ?? .distantPast) }
    }

    public var finishedBags: [CoffeeBag] {
        bags
            .filter { $0.status == .finished || $0.remainingGrams <= 0 }
            .sorted { ($0.roastDate ?? .distantPast) > ($1.roastDate ?? .distantPast) }
    }

    public var recentLogs: [BrewLog] {
        brewLogs.sorted { $0.date > $1.date }
    }

    @discardableResult
    public func addCoffee(from draft: BagScanDraft) -> CoffeeBag {
        let matchedCoffee = matchingCoffee(for: draft.coffee)
        let coffeeID = matchedCoffee?.id ?? draft.coffee.id
        if matchedCoffee == nil {
            coffees.append(draft.coffee)
        }
        let totalGrams = draft.totalGrams ?? 0

        let bag = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: draft.roastDate,
            totalGrams: totalGrams,
            remainingGrams: totalGrams,
            status: .active,
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
        let bag = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: roastDate,
            totalGrams: totalGrams,
            remainingGrams: totalGrams,
            status: .active,
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
            reduceRemainingGrams(on: bagID, by: gramsUsed)
        }

        if let coffeeIndex = coffees.firstIndex(where: { $0.id == coffeeID }) {
            coffees[coffeeIndex].verdict = mergedVerdict(existing: coffees[coffeeIndex].verdict, new: verdict)
        }

        persist()
        return log
    }

    public func finishBag(_ bagID: UUID) {
        guard let index = bags.firstIndex(where: { $0.id == bagID }) else { return }
        bags[index].remainingGrams = 0
        bags[index].status = .finished
        persist()
    }

    public func updateCoffee(_ coffee: Coffee) {
        guard let index = coffees.firstIndex(where: { $0.id == coffee.id }) else { return }
        coffees[index] = coffee
        persist()
    }

    public func updateFlavorArtwork(coffeeID: UUID, artwork: FlavorArtwork) {
        guard let index = coffees.firstIndex(where: { $0.id == coffeeID }) else { return }
        coffees[index].flavorArtwork = artwork
        persist()
    }

    public func deleteBrewLog(_ logID: UUID) {
        guard let index = brewLogs.firstIndex(where: { $0.id == logID }) else { return }
        brewLogs.remove(at: index)
        persist()
    }

    public func updateBag(_ bag: CoffeeBag) {
        guard let index = bags.firstIndex(where: { $0.id == bag.id }) else { return }
        var updatedBag = bag
        updatedBag.remainingGrams = max(0, min(updatedBag.remainingGrams, updatedBag.totalGrams))
        if updatedBag.remainingGrams <= 0 {
            updatedBag.status = .finished
        }
        bags[index] = updatedBag
        persist()
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

    private func reduceRemainingGrams(on bagID: UUID, by gramsUsed: Double) {
        guard let index = bags.firstIndex(where: { $0.id == bagID }) else { return }
        bags[index].remainingGrams = max(0, bags[index].remainingGrams - gramsUsed)
        if bags[index].remainingGrams == 0 {
            bags[index].status = .finished
        }
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
