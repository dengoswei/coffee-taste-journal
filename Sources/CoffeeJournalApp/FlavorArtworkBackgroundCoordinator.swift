import CoffeeJournalCore
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
import BackgroundTasks
#endif

@MainActor
func enqueueFlavorArtworkGeneration(
    for coffeeID: UUID,
    in store: CoffeeJournalStore,
    source: String,
    force: Bool = false
) {
    guard let requestID = store.queueArtworkGeneration(
        coffeeID: coffeeID,
        replacingCurrentRequest: force,
        resetDeferredFailures: force,
        forceGeneration: force
    ) else { return }

#if os(iOS)
    FlavorArtworkBackgroundCoordinator.shared.startForegroundAttempt(
        coffeeID: coffeeID,
        requestID: requestID,
        store: store,
        source: source
    )
#else
    Task { @MainActor in
        await generateFlavorArtwork(
            for: coffeeID,
            requestID: requestID,
            in: store,
            source: source,
            force: force
        )
    }
#endif
}

#if os(iOS)
@MainActor
final class FlavorArtworkBackgroundCoordinator {
    static let shared = FlavorArtworkBackgroundCoordinator()
    nonisolated static let processingIdentifier = "com.dengos.CoffeeJournal.flavor-artwork.processing"

    private weak var store: CoffeeJournalStore?
    private var isRegistered = false
    private var foregroundWorkers: [UUID: Task<Void, Never>] = [:]
    private var backgroundAssertions: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var processingWorker: Task<Void, Never>?
    private var processingRequest: (coffeeID: UUID, requestID: UUID)?

    func register(store: CoffeeJournalStore) {
        self.store = store
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: .main
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.run(processingTask)
        }
    }

    func startForegroundAttempt(
        coffeeID: UUID,
        requestID: UUID,
        store: CoffeeJournalStore,
        source: String
    ) {
        register(store: store)
        guard foregroundWorkers[requestID] == nil else { return }

        let assertion = UIApplication.shared.beginBackgroundTask(
            withName: "Generate coffee artwork"
        ) { [weak self] in
            Task { @MainActor in
                self?.expireForegroundAttempt(
                    coffeeID: coffeeID,
                    requestID: requestID,
                    store: store
                )
            }
        }
        backgroundAssertions[requestID] = assertion

        let worker = Task { @MainActor [weak self] in
            let force = store.coffee(for: coffeeID)?.artworkJob?.forceGeneration ?? false
            await generateFlavorArtwork(
                for: coffeeID,
                requestID: requestID,
                in: store,
                source: source,
                force: force
            )
            self?.finishForegroundAttempt(requestID: requestID, store: store)
        }
        foregroundWorkers[requestID] = worker
    }

    func startDueForegroundWork(store: CoffeeJournalStore, source: String) {
        register(store: store)
        for coffee in store.coffeesNeedingArtworkGeneration() {
            guard let requestID = coffee.artworkJob?.requestID else { continue }
            startForegroundAttempt(
                coffeeID: coffee.id,
                requestID: requestID,
                store: store,
                source: source
            )
        }
        scheduleDeferredWork(store: store)
    }

    func scheduleDeferredWork(store: CoffeeJournalStore, noEarlierThan minimumDate: Date? = nil) {
        register(store: store)
        guard let queuedDate = store.earliestArtworkWakeDate() else { return }
        let desiredDate = max(queuedDate, minimumDate ?? .distantPast)

        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let matchingDates = requests.compactMap { request -> Date? in
                guard request.identifier == Self.processingIdentifier,
                      request is BGProcessingTaskRequest else { return nil }
                return request.earliestBeginDate ?? .distantPast
            }
            Task { @MainActor in
                if matchingDates.contains(where: { $0 <= desiredDate }) {
                    return
                }

                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
                let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
                request.requiresNetworkConnectivity = true
                request.requiresExternalPower = false
                request.earliestBeginDate = desiredDate
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    FlavorArtworkDiagnostics.record(
                        "processing-submit-failed",
                        source: "scheduler",
                        coffee: nil,
                        message: error.localizedDescription,
                        fields: ["taskIdentifier": Self.processingIdentifier]
                    )
                }
            }
        }
    }

    private func finishForegroundAttempt(requestID: UUID, store: CoffeeJournalStore) {
        foregroundWorkers.removeValue(forKey: requestID)
        endAssertion(for: requestID)
        scheduleDeferredWork(store: store)
    }

    private func expireForegroundAttempt(
        coffeeID: UUID,
        requestID: UUID,
        store: CoffeeJournalStore
    ) {
        foregroundWorkers.removeValue(forKey: requestID)?.cancel()
        _ = store.requeueArtworkRequest(
            coffeeID: coffeeID,
            requestID: requestID,
            reason: "Background execution expired."
        )
        scheduleDeferredWork(store: store)
        endAssertion(for: requestID)
    }

    private func endAssertion(for requestID: UUID) {
        guard let assertion = backgroundAssertions.removeValue(forKey: requestID),
              assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
    }

    private func run(_ task: BGProcessingTask) {
        guard let store else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expireProcessingTask(task, store: store)
            }
        }

        processingWorker = Task { @MainActor [weak self] in
            var completed = true
            for coffee in store.coffeesNeedingArtworkGeneration() {
                guard !Task.isCancelled else {
                    completed = false
                    break
                }
                guard let requestID = coffee.artworkJob?.requestID else { continue }
                self?.processingRequest = (coffee.id, requestID)
                await generateFlavorArtwork(
                    for: coffee.id,
                    requestID: requestID,
                    in: store,
                    source: "bg-processing",
                    force: coffee.artworkJob?.forceGeneration ?? false
                )
                self?.processingRequest = nil
            }

            guard !Task.isCancelled else { return }
            self?.processingWorker = nil
            task.setTaskCompleted(success: completed)
            self?.scheduleDeferredWork(store: store)
        }
    }

    private func expireProcessingTask(_ task: BGProcessingTask, store: CoffeeJournalStore) {
        processingWorker?.cancel()
        processingWorker = nil
        if let current = processingRequest {
            _ = store.requeueArtworkRequest(
                coffeeID: current.coffeeID,
                requestID: current.requestID,
                reason: "Deferred background execution expired."
            )
        }
        processingRequest = nil
        task.setTaskCompleted(success: false)
        scheduleDeferredWork(store: store)
    }
}
#endif
