import CoffeeJournalCore
import Foundation

@main
struct CoffeeJournalCoreChecks {
    static func main() {
        addNewCoffeeFromScanDraftCreatesActiveBag()
        knownCoffeeReactivatesWithNewBagRatherThanDuplicateCoffee()
        logCupConsumesBagAndKeepsQuickPathSmall()
        finishBagMovesItOutOfActiveWithoutDeletingHistory()
        tasteInsightsBecomeExplainableAfterEnoughLogs()
        manualFallbackDraftKeepsAppUsefulWhenScanFails()
        print("CoffeeJournalCoreChecks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    private static func addNewCoffeeFromScanDraftCreatesActiveBag() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()

        let bag = store.addCoffee(from: draft)

        expect(store.coffees.count == 1, "expected one coffee")
        expect(store.activeBags.map(\.id) == [bag.id], "expected scanned bag to be active")
        expect(store.coffee(for: bag.coffeeID)?.roaster == "La Cabra", "expected scanned roaster")
        expect(bag.remainingGrams == draft.totalGrams, "expected full remaining grams")
    }

    private static func knownCoffeeReactivatesWithNewBagRatherThanDuplicateCoffee() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()
        let firstBag = store.addCoffee(from: draft)
        store.finishBag(firstBag.id)

        let secondBag = store.addCoffee(from: draft)

        expect(store.coffees.count == 1, "expected no duplicate coffee")
        expect(store.activeBags.map(\.id) == [secondBag.id], "expected second bag active")
        expect(store.finishedBags.map(\.id) == [firstBag.id], "expected first bag finished")
    }

    private static func logCupConsumesBagAndKeepsQuickPathSmall() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())

        let log = store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .liked,
            tastingNote: "Sweet and clean.",
            gramsUsed: 18
        )

        expect(store.brewLogs.map(\.id) == [log.id], "expected one log")
        expect(store.bag(for: bag.id)?.remainingGrams == 232, "expected grams consumed")
        expect(log.details == nil, "expected brew details optional")
    }

    private static func finishBagMovesItOutOfActiveWithoutDeletingHistory() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())

        store.logCup(
            coffeeID: bag.coffeeID,
            bagID: bag.id,
            verdict: .loved,
            tastingNote: "Great after rest."
        )
        store.finishBag(bag.id)

        expect(store.activeBags.isEmpty, "expected no active bags")
        expect(store.finishedBags.map(\.id) == [bag.id], "expected finished bag")
        expect(store.logs(for: bag.coffeeID).count == 1, "expected history preserved")
        expect(store.coffees.count == 1, "expected coffee preserved")
    }

    private static func tasteInsightsBecomeExplainableAfterEnoughLogs() {
        let store = CoffeeJournalSampleData.store()

        let summary = TasteAnalyzer.summarize(coffees: store.coffees, logs: store.brewLogs)

        expect(summary.likedTokens.contains("Washed"), "expected process token")
        expect(!summary.mostLovedCoffeeIDs.isEmpty, "expected loved coffees")
        expect(summary.insights.count >= 2, "expected explainable insights")
    }

    private static func manualFallbackDraftKeepsAppUsefulWhenScanFails() {
        let draft = MockBagScanner().manualFallbackDraft()

        expect(draft.coffee.roaster == "", "expected blank manual roaster")
        expect(draft.totalGrams == 250, "expected default grams")
        expect(draft.brewAdvice.isEmpty, "expected blank advice")
    }
}
