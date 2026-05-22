import CoffeeJournalCore
import SwiftUI

@main
struct CoffeeJournalApp: App {
    @State private var store: CoffeeJournalStore

    init() {
        let loadedStore = CoffeeJournalPersistence.loadStore()
        loadedStore.onChange = { snapshot in
            CoffeeJournalPersistence.save(snapshot)
        }
        _store = State(initialValue: loadedStore)
    }

    var body: some Scene {
        WindowGroup {
            CoffeeJournalRootView(store: store)
        }
    }
}

struct CoffeeJournalRootView: View {
    let store: CoffeeJournalStore
    @State private var didRequestFlavorArtwork = false

    var body: some View {
        TabView {
            NavigationStack {
                JournalView(store: store)
            }
            .tabItem {
                Label("Journal", systemImage: "book.pages")
            }

            NavigationStack {
                BeansView(store: store)
            }
            .tabItem {
                Label("Beans", systemImage: "leaf")
            }

            NavigationStack {
                TasteView(store: store)
            }
            .tabItem {
                Label("Taste", systemImage: "chart.xyaxis.line")
            }
        }
        .tint(CoffeeTheme.accent)
        .task {
            guard !didRequestFlavorArtwork else { return }
            didRequestFlavorArtwork = true
            await requestMissingFlavorArtwork()
        }
    }

    @MainActor
    private func requestMissingFlavorArtwork() async {
        for coffee in store.coffees where !coffee.flavorNotes.isEmpty {
            await generateFlavorArtwork(for: coffee.id, in: store, source: "app-start-scan")
        }
    }
}

enum CoffeeJournalPersistence {
    private static let folderName = "CoffeeJournal"
    private static let fileName = "store.json"

    static func loadStore() -> CoffeeJournalStore {
        do {
            let data = try Data(contentsOf: storeURL())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CoffeeJournalSnapshot.self, from: data)
            return CoffeeJournalStore(snapshot: snapshot)
        } catch {
            debugLog("Starting with an empty store: \(error.localizedDescription)")
            return CoffeeJournalStore()
        }
    }

    static func save(_ snapshot: CoffeeJournalSnapshot) {
        do {
            let url = try storeURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            debugLog("Failed to save store: \(error.localizedDescription)")
        }
    }

    private static func storeURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[CoffeeJournalPersistence] \(message)")
        #endif
    }
}

enum CoffeeTheme {
    static let background = Color(red: 0.98, green: 0.96, blue: 0.92)
    static let card = Color(red: 1.0, green: 0.99, blue: 0.96)
    static let accent = Color(red: 0.47, green: 0.24, blue: 0.10)
    static let subtle = Color(red: 0.57, green: 0.50, blue: 0.43)
    static let divider = Color(red: 0.87, green: 0.82, blue: 0.75)
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(CoffeeTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.divider, lineWidth: 1)
            )
    }
}

extension View {
    func coffeeCard() -> some View {
        modifier(CardBackground())
    }
}

extension Date {
    var shortCoffeeDate: String {
        formatted(.dateTime.month(.abbreviated).day())
    }
}

extension Double {
    var gramsText: String {
        "\(Int(self.rounded()))g"
    }
}
