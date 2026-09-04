import CoffeeJournalCore
import XCTest

final class CoffeeJournalCoreTests: XCTestCase {
    func testActiveBagsOrderOldestRoastFirstAndUnknownLast() {
        let coffeeID = UUID()
        let oldest = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: Date(timeIntervalSince1970: 100),
            totalGrams: 250,
            remainingGrams: 250
        )
        let middle = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: Date(timeIntervalSince1970: 200),
            totalGrams: 250,
            remainingGrams: 250
        )
        let newest = CoffeeBag(
            coffeeID: coffeeID,
            roastDate: Date(timeIntervalSince1970: 300),
            totalGrams: 250,
            remainingGrams: 250
        )
        let unknown = CoffeeBag(
            coffeeID: coffeeID,
            totalGrams: 250,
            remainingGrams: 250
        )
        let store = CoffeeJournalStore(bags: [newest, unknown, oldest, middle])

        XCTAssertEqual(store.activeBags.map(\.id), [oldest.id, middle.id, newest.id, unknown.id])
    }

    func testAddNewCoffeeFromScanDraftCreatesActiveBag() {
        let store = CoffeeJournalStore()
        let draft = MockBagScanner().scanSampleBag()

        let bag = store.addCoffee(from: draft)

        XCTAssertEqual(store.coffees.count, 1)
        XCTAssertEqual(store.activeBags.map(\.id), [bag.id])
        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.roaster, "La Cabra")
        XCTAssertNotNil(store.coffee(for: bag.coffeeID)?.addedAt)
        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.artworkJob?.status, .queued)
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

    func testLegacyCoffeeJSONDecodesWithoutLifecycleFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "roaster": "Legacy",
          "name": "Coffee",
          "origin": "Colombia",
          "farm": "",
          "variety": "Gesha",
          "process": "Washed",
          "flavorNotes": ["Citrus"],
          "notes": ""
        }
        """

        let coffee = try JSONDecoder().decode(Coffee.self, from: Data(json.utf8))

        XCTAssertNil(coffee.addedAt)
        XCTAssertNil(coffee.artworkJob)
        XCTAssertNil(coffee.flavorArtwork)
    }

    func testArtworkLifecyclePersistsFailureAndSuccess() {
        let store = CoffeeJournalStore()
        let bag = store.addCoffee(from: MockBagScanner().scanSampleBag())
        let failure = ArtworkJobState(
            status: .failed,
            attemptCount: 3,
            lastAttemptAt: Date(),
            nextRetryAt: Date().addingTimeInterval(300),
            lastError: "Network unavailable"
        )
        store.updateArtworkJob(coffeeID: bag.coffeeID, state: failure)

        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.artworkJob, failure)

        let artwork = FlavorArtwork(
            model: "test-model",
            promptHash: "hash",
            sourcePrompt: "prompt",
            heroFilename: "hero.jpg",
            cardFilename: "card.jpg",
            thumbnailFilename: "thumb.jpg"
        )
        store.updateFlavorArtwork(coffeeID: bag.coffeeID, artwork: artwork)

        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.artworkJob?.status, .succeeded)
        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.artworkJob?.attemptCount, 3)
        XCTAssertEqual(store.coffee(for: bag.coffeeID)?.flavorArtwork?.generationVersion, 3)
    }

    func testArtworkQueueOnlyReturnsMissingWorkWhoseRetryIsDue() {
        let now = Date(timeIntervalSince1970: 1_000)
        let due = Coffee(
            roaster: "Due",
            name: "Queued",
            origin: "Colombia",
            farm: "",
            variety: "Gesha",
            process: "Washed",
            flavorNotes: ["Jasmine"],
            artworkJob: ArtworkJobState(status: .queued)
        )
        let delayed = Coffee(
            roaster: "Delayed",
            name: "Retry later",
            origin: "Ethiopia",
            farm: "",
            variety: "Landrace",
            process: "Natural",
            flavorNotes: ["Blueberry"],
            artworkJob: ArtworkJobState(
                status: .failed,
                nextRetryAt: now.addingTimeInterval(60)
            )
        )
        let existing = Coffee(
            roaster: "Ready",
            name: "Has artwork",
            origin: "Panama",
            farm: "",
            variety: "Gesha",
            process: "Washed",
            flavorNotes: ["Peach"],
            flavorArtwork: FlavorArtwork(
                model: "test-model",
                promptHash: "hash",
                sourcePrompt: "prompt",
                heroFilename: "hero.jpg",
                cardFilename: "card.jpg",
                thumbnailFilename: "thumb.jpg"
            ),
            artworkJob: ArtworkJobState(status: .succeeded)
        )
        let noFlavorNotes = Coffee(
            roaster: "No notes",
            name: "Not eligible",
            origin: "Kenya",
            farm: "",
            variety: "SL28",
            process: "Washed",
            flavorNotes: []
        )
        let store = CoffeeJournalStore(coffees: [due, delayed, existing, noFlavorNotes])

        XCTAssertEqual(
            store.coffeesNeedingArtworkGeneration(at: now).map(\.id),
            [due.id]
        )
    }

    func testLegacyBagAndArtworkJobDecodeWithoutNewLifecycleFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000010",
          "coffeeID": "00000000-0000-0000-0000-000000000011",
          "totalGrams": 250,
          "remainingGrams": 0,
          "status": "finished",
          "brewAdvice": "",
          "artworkJob": null
        }
        """
        let bag = try JSONDecoder().decode(CoffeeBag.self, from: Data(json.utf8))

        XCTAssertNil(bag.finishedAt)

        let jobJSON = """
        {"status":"queued","attemptCount":2}
        """
        let job = try JSONDecoder().decode(ArtworkJobState.self, from: Data(jobJSON.utf8))
        XCTAssertNil(job.requestID)
        XCTAssertEqual(job.deferredFailureCount, 0)
        XCTAssertFalse(job.forceGeneration)
    }

    func testFinishTimestampIsRecordedOnceAndReactivationStartsANewCycle() {
        let coffee = makeCoffee(roaster: "Test", name: "Cycle")
        let bag = CoffeeBag(coffeeID: coffee.id, totalGrams: 250, remainingGrams: 250)
        let store = CoffeeJournalStore(coffees: [coffee], bags: [bag])
        let firstFinish = Date(timeIntervalSince1970: 100)
        let repeatedFinish = Date(timeIntervalSince1970: 200)

        store.finishBag(bag.id, at: firstFinish)
        store.finishBag(bag.id, at: repeatedFinish)
        XCTAssertEqual(store.bag(for: bag.id)?.finishedAt, firstFinish)

        var reopened = try! XCTUnwrap(store.bag(for: bag.id))
        reopened.status = .active
        reopened.remainingGrams = 100
        store.updateBag(reopened, at: Date(timeIntervalSince1970: 300))
        XCTAssertNil(store.bag(for: bag.id)?.finishedAt)

        store.finishBag(bag.id, at: repeatedFinish)
        XCTAssertEqual(store.bag(for: bag.id)?.finishedAt, repeatedFinish)
    }

    func testAutomaticZeroGramCompletionUsesBrewDate() {
        let coffee = makeCoffee(roaster: "Test", name: "Last cup")
        let bag = CoffeeBag(coffeeID: coffee.id, totalGrams: 18, remainingGrams: 18)
        let store = CoffeeJournalStore(coffees: [coffee], bags: [bag])
        let brewDate = Date(timeIntervalSince1970: 500)

        store.logCup(
            coffeeID: coffee.id,
            bagID: bag.id,
            verdict: .loved,
            tastingNote: "Finished",
            gramsUsed: 18,
            date: brewDate
        )

        XCTAssertEqual(store.bag(for: bag.id)?.status, .finished)
        XCTAssertEqual(store.bag(for: bag.id)?.finishedAt, brewDate)
    }

    func testNonpositiveReactivationGetsTruthfulCompletionTime() {
        let coffee = makeCoffee(roaster: "Test", name: "Zero bag")
        let store = CoffeeJournalStore(coffees: [coffee])

        let bag = store.reactivateCoffee(
            coffeeID: coffee.id,
            roastDate: Date(timeIntervalSince1970: 1),
            totalGrams: 0
        )

        XCTAssertEqual(bag.status, .finished)
        XCTAssertEqual(bag.remainingGrams, 0)
        XCTAssertNotNil(bag.finishedAt)
    }

    func testPastBeansPutTimestampedCompletionsBeforeLegacyWriteOrder() {
        let oldLegacy = makeCoffee(roaster: "A", name: "Old legacy")
        let timestamped = makeCoffee(roaster: "B", name: "Timestamped")
        let newLegacy = makeCoffee(roaster: "C", name: "New legacy")
        let bags = [
            CoffeeBag(coffeeID: oldLegacy.id, totalGrams: 250, remainingGrams: 0, status: .finished),
            CoffeeBag(
                coffeeID: timestamped.id,
                totalGrams: 250,
                remainingGrams: 0,
                status: .finished,
                finishedAt: Date(timeIntervalSince1970: 1)
            ),
            CoffeeBag(coffeeID: newLegacy.id, totalGrams: 250, remainingGrams: 0, status: .finished)
        ]
        let store = CoffeeJournalStore(coffees: [oldLegacy, timestamped, newLegacy], bags: bags)

        XCTAssertEqual(
            store.pastCoffees().map { $0.coffee.name },
            ["Timestamped", "New legacy", "Old legacy"]
        )
    }

    func testPastBeansFilterBeforeApplyingFiftyItemLimit() {
        var coffees: [Coffee] = []
        var bags: [CoffeeBag] = []
        for index in 0..<51 {
            let name = index == 50 ? "Needle" : "Coffee \(index)"
            let coffee = makeCoffee(roaster: "R", name: name)
            coffees.append(coffee)
            bags.append(CoffeeBag(
                coffeeID: coffee.id,
                totalGrams: 250,
                remainingGrams: 0,
                status: .finished,
                finishedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            ))
        }
        let store = CoffeeJournalStore(coffees: coffees, bags: bags)

        XCTAssertEqual(store.pastCoffees().count, 50)
        XCTAssertEqual(store.pastCoffees(matching: "Needle").map { $0.coffee.name }, ["Needle"])
    }

    func testRoasterGroupsNormalizeWhitespaceCaseWidthAndDiacritics() {
        let older = makeCoffee(roaster: "cafe x", name: "Older")
        let newer = makeCoffee(roaster: "  CAFÉ   Ｘ  ", name: "Newer")
        let store = CoffeeJournalStore(
            coffees: [older, newer],
            bags: [
                CoffeeBag(
                    coffeeID: older.id,
                    totalGrams: 250,
                    remainingGrams: 0,
                    status: .finished,
                    finishedAt: Date(timeIntervalSince1970: 10)
                ),
                CoffeeBag(
                    coffeeID: newer.id,
                    totalGrams: 250,
                    remainingGrams: 0,
                    status: .finished,
                    finishedAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )

        let group = try! XCTUnwrap(store.pastRoasterGroups().first)
        XCTAssertEqual(store.pastRoasterGroups().count, 1)
        XCTAssertEqual(group.displayName, "CAFÉ Ｘ")
        XCTAssertEqual(group.coffeeCount, 2)
        XCTAssertEqual(group.latestCoffeeName, "Newer")
    }

    func testRoasterGroupsSortByCoffeeCountThenLatestCompletion() {
        let popularOne = makeCoffee(roaster: "Popular", name: "Popular one")
        let popularTwo = makeCoffee(roaster: "Popular", name: "Popular two")
        let recentOne = makeCoffee(roaster: "Recent", name: "Recent one")
        let recentTwo = makeCoffee(roaster: "Recent", name: "Recent two")
        let singleNewest = makeCoffee(roaster: "Single", name: "Single newest")
        let store = CoffeeJournalStore(
            coffees: [popularOne, popularTwo, recentOne, recentTwo, singleNewest],
            bags: [
                finishedBag(for: popularOne, at: 10),
                finishedBag(for: popularTwo, at: 20),
                finishedBag(for: recentOne, at: 30),
                finishedBag(for: recentTwo, at: 40),
                finishedBag(for: singleNewest, at: 100)
            ]
        )

        XCTAssertEqual(
            store.pastRoasterGroups().map(\.displayName),
            ["Recent", "Popular", "Single"]
        )
    }

    func testQueuedReplacementIsEligibleAndStaleResultCannotCommit() {
        var coffee = makeCoffee(roaster: "Test", name: "Replacement")
        coffee.flavorArtwork = FlavorArtwork(
            model: "old",
            promptHash: "old",
            sourcePrompt: "old",
            heroFilename: "old-hero.jpg",
            cardFilename: "old-card.jpg",
            thumbnailFilename: "old-thumb.jpg"
        )
        let currentRequest = UUID()
        coffee.artworkJob = ArtworkJobState(status: .queued, requestID: currentRequest)
        let store = CoffeeJournalStore(coffees: [coffee])

        XCTAssertEqual(store.coffeesNeedingArtworkGeneration().map(\.id), [coffee.id])

        let staleArtwork = FlavorArtwork(
            model: "new",
            promptHash: "new",
            sourcePrompt: "new",
            heroFilename: "new-hero.jpg",
            cardFilename: "new-card.jpg",
            thumbnailFilename: "new-thumb.jpg"
        )
        XCTAssertFalse(store.updateFlavorArtwork(
            coffeeID: coffee.id,
            artwork: staleArtwork,
            matching: UUID()
        ))
        XCTAssertEqual(store.coffee(for: coffee.id)?.flavorArtwork?.promptHash, "old")
    }

    func testReplacementRaceCleansFilesAndSkipsPublication() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coffee-artwork-race-\(UUID().uuidString).tmp")
        var requestIsCurrent = true
        var didCommit = false

        let result = try ArtworkPublicationCoordinator.publishIfCurrent(
            isCurrent: { requestIsCurrent },
            makeArtifacts: {
                try Data("stale".utf8).write(to: fileURL, options: .atomic)
                requestIsCurrent = false
                return fileURL
            },
            commit: { _ in
                didCommit = true
                return true
            },
            cleanup: { url in
                try? FileManager.default.removeItem(at: url)
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(didCommit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeferredArtworkRetryBackoff() {
        XCTAssertEqual(CoffeeJournalStore.artworkRetryDelay(for: 1), 5 * 60)
        XCTAssertEqual(CoffeeJournalStore.artworkRetryDelay(for: 2), 30 * 60)
        XCTAssertEqual(CoffeeJournalStore.artworkRetryDelay(for: 3), 2 * 60 * 60)
        XCTAssertEqual(CoffeeJournalStore.artworkRetryDelay(for: 4), 12 * 60 * 60)
        XCTAssertEqual(CoffeeJournalStore.artworkRetryDelay(for: 20), 12 * 60 * 60)
    }

    private func makeCoffee(roaster: String, name: String) -> Coffee {
        Coffee(
            roaster: roaster,
            name: name,
            origin: "Origin",
            variety: "Variety",
            process: "Process",
            flavorNotes: ["Peach"]
        )
    }

    private func finishedBag(for coffee: Coffee, at timestamp: TimeInterval) -> CoffeeBag {
        CoffeeBag(
            coffeeID: coffee.id,
            totalGrams: 250,
            remainingGrams: 0,
            status: .finished,
            finishedAt: Date(timeIntervalSince1970: timestamp)
        )
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
