import CoffeeJournalCore
import XCTest

final class CoffeeJournalCoreTests: XCTestCase {
    func testAddNewCoffeeFromScanDraftCreatesActiveBag() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()

        let bag = store.addCoffee(from: draft)

        XCTAssertEqual(store.coffees.count, 1)
        XCTAssertEqual(store.activeBags.map(\.id), [bag.id])
        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.roaster, "La Cabra")
        XCTAssertEqual(bag.remainingGrams, draft.totalGrams)
    }

    func testKnownCoffeeReactivatesWithNewBagRatherThanDuplicateCoffee() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()
        let firstBag = store.addCoffee(from: draft)
        store.finishBag(firstBag.id)

        let secondBag = store.addCoffee(from: draft)

        XCTAssertEqual(store.coffees.count, 1)
        XCTAssertEqual(store.activeBags.map(\.id), [secondBag.id])
        XCTAssertEqual(store.finishedBags.map(\.id), [firstBag.id])
    }

    func testCoffeeMatchingIgnoresUnstableName() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()
        let firstBag = store.addCoffee(from: draft)
        var renamedDraft = draft
        renamedDraft.coffee = copyCoffee(draft.coffee, name: "Different bag label")

        let secondBag = store.addCoffee(from: renamedDraft)

        XCTAssertEqual(store.coffees.count, 1)
        XCTAssertEqual(secondBag.coffeeID, firstBag.coffeeID)
    }

    func testCoffeeMatchingSeparatesDifferentVariety() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()
        let firstBag = store.addCoffee(from: draft)
        var differentVarietyDraft = draft
        differentVarietyDraft.coffee = copyCoffee(draft.coffee, variety: "Gesha")

        let secondBag = store.addCoffee(from: differentVarietyDraft)

        XCTAssertEqual(store.coffees.count, 2)
        XCTAssertNotEqual(secondBag.coffeeID, firstBag.coffeeID)
    }

    func testLogCupConsumesBagAndKeepsQuickPathSmall() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())

        let log = store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .liked,
            tastingNote: "Sweet and clean.",
            gramsUsed: 18
        )

        XCTAssertEqual(store.brewLogs.map(\.id), [log.id])
        XCTAssertEqual(store.bag(for: bag.id)?.remainingGrams, 232)
        XCTAssertNil(log.details)
    }

    func testFinishBagMovesItOutOfActiveWithoutDeletingHistory() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())

        store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .loved,
            tastingNote: "Great after rest."
        )
        store.finishBag(bag.id)

        XCTAssertTrue(store.activeBags.isEmpty)
        XCTAssertEqual(store.finishedBags.map(\.id), [bag.id])
        XCTAssertEqual(store.logs(for: bag.coffeeID).count, 1)
        XCTAssertEqual(store.coffees.count, 1)
    }

    func testDeleteBrewLogRemovesTasteMemoryEntry() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())
        let log = store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .liked,
            tastingNote: "Clean cup.",
            gramsUsed: 15
        )

        store.deleteBrewLog(log.id)

        XCTAssertTrue(store.brewLogs.isEmpty)
        XCTAssertTrue(store.logs(for: bag.coffeeID).isEmpty)
    }

    func testTasteInsightsBecomeExplainableAfterEnoughLogs() {
        let store = CoffeeJournalSampleData.store()

        let summary = TasteAnalyzer.summarize(coffees: store.coffees, logs: store.brewLogs)

        XCTAssertTrue(summary.likedTokens.contains("Washed"))
        XCTAssertFalse(summary.mostLovedCoffeeIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(summary.insights.count, 2)
    }

    func testMostLovedRequiresLovedVerdict() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())
        store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .ok,
            tastingNote: "Fine but not loved.",
            gramsUsed: 15
        )

        let summary = TasteAnalyzer.summarize(coffees: store.coffees, logs: store.brewLogs)

        XCTAssertTrue(summary.mostLovedCoffeeIDs.isEmpty)
    }

    func testManualFallbackDraftKeepsAppUsefulWhenScanFails() {
        let draft = MockBagScanner().manualFallbackDraft()

        XCTAssertEqual(draft.coffee.roaster, "")
        XCTAssertEqual(draft.totalGrams, 250)
        XCTAssertTrue(draft.brewAdvice.isEmpty)
    }

    func testSnapshotRestoresStoreData() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())
        let log = store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .liked,
            tastingNote: "Saved cup.",
            gramsUsed: 15
        )

        let restored = CoffeeJournalStore(snapshot: store.snapshot)

        XCTAssertEqual(restored.coffees, store.coffees)
        XCTAssertEqual(restored.bags, store.bags)
        XCTAssertEqual(restored.brewLogs, store.brewLogs)
        XCTAssertEqual(restored.brewLogs.first?.id, log.id)
    }

    func testMutationsPublishPersistableSnapshots() {
        let store = CoffeeJournalStore()
        var snapshots: [CoffeeJournalSnapshot] = []
        store.onChange = { snapshots.append($0) }

        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())
        store.finishBag(bag.id)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.bags.first?.status, .finished)
    }

    private func copyCoffee(
        _ coffee: Coffee,
        name: String? = nil,
        variety: String? = nil
    ) -> Coffee {
        Coffee(
            roaster: coffee.roaster,
            name: name ?? coffee.name,
            origin: coffee.origin,
            farm: coffee.farm,
            variety: variety ?? coffee.variety,
            process: coffee.process,
            flavorNotes: coffee.flavorNotes,
            verdict: coffee.verdict,
            notes: coffee.notes,
            flavorArtwork: coffee.flavorArtwork
        )
    }
}
