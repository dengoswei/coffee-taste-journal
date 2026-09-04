import CoffeeJournalCore
import Foundation
import SwiftUI
#if canImport(UIKit)
import PhotosUI
import UIKit
#endif

struct BeansView: View {
    let store: CoffeeJournalStore
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var pastMode: PastBeansMode = .recent
    @State private var recentSearchText = ""
    @State private var roasterSearchText = ""
    @State private var isAddingBean = false

    var body: some View {
        List {
            Section("Currently Drinking") {
                if filteredActiveBags.isEmpty {
                    Text(activeEmptyText)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredActiveBags) { bag in
                        NavigationLink {
                            BeanDetailView(store: store, coffeeID: bag.coffeeID)
                        } label: {
                            ActiveBeanRow(store: store, bag: bag)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                store.finishBag(bag.id)
                            } label: {
                                Label("Finished", systemImage: "checkmark.circle.fill")
                            }
                            .tint(CoffeeTheme.accent)
                        }
                    }
                }
            }

            Section("Past Beans") {
                Picker("Past Beans view", selection: $pastMode) {
                    ForEach(PastBeansMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Past Beans view")

                switch pastMode {
                case .recent:
                    if filteredPastCoffees.isEmpty {
                        Text(pastEmptyText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredPastCoffees) { record in
                            NavigationLink {
                                BeanDetailView(store: store, coffeeID: record.coffee.id)
                            } label: {
                                BeanSummaryRow(store: store, coffee: record.coffee)
                            }
                        }
                    }
                case .roasters:
                    if filteredRoasterGroups.isEmpty {
                        Text(roasterEmptyText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredRoasterGroups) { group in
                            NavigationLink {
                                RoasterPastBeansView(store: store, group: group)
                            } label: {
                                PastRoasterRow(group: group)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CoffeeTheme.background.ignoresSafeArea())
        .navigationTitle("Beans")
        .searchable(text: searchBinding, prompt: searchPrompt)
        .onChange(of: pastMode) { _, _ in
            dismissSearch()
        }
        .toolbar {
            Button {
                isAddingBean = true
            } label: {
                Label("Add Bean", systemImage: "plus.circle.fill")
            }
        }
        .addBeanPresentation(isPresented: $isAddingBean) {
            AddBeanSheet(store: store)
        }
    }

    private var filteredActiveBags: [CoffeeBag] {
        store.activeBags.filter { bag in
            guard let coffee = store.coffee(for: bag.coffeeID) else { return false }
            return matchesSearch(coffee, query: recentSearchText)
        }
    }

    private var filteredPastCoffees: [PastCoffeeRecord] {
        store.pastCoffees(matching: recentSearchText, limit: 50)
    }

    private var filteredRoasterGroups: [PastRoasterGroup] {
        store.pastRoasterGroups(matching: roasterSearchText)
    }

    private var activeEmptyText: String {
        if searchBinding.wrappedValue.trimmedForSearch.isEmpty {
            return "No active beans yet. Add a bean to start logging cups."
        }
        return "No active beans match this search."
    }

    private var pastEmptyText: String {
        if recentSearchText.trimmedForSearch.isEmpty {
            return "Finished beans will stay here for memory."
        }
        return "No past beans match this search."
    }

    private var roasterEmptyText: String {
        if roasterSearchText.trimmedForSearch.isEmpty {
            return "Finished beans will stay here for memory."
        }
        return "No roasters match this search."
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { pastMode == .recent ? recentSearchText : roasterSearchText },
            set: { newValue in
                if pastMode == .recent {
                    recentSearchText = newValue
                } else {
                    roasterSearchText = newValue
                }
            }
        )
    }

    private var searchPrompt: String {
        pastMode == .recent ? "Search roaster, origin, process" : "Search roasters"
    }

    private func matchesSearch(_ coffee: Coffee, query rawQuery: String) -> Bool {
        let query = rawQuery.trimmedForSearch
        guard !query.isEmpty else { return true }
        let searchableFields = [
            coffee.roaster,
            coffee.name,
            coffee.origin,
            coffee.farm,
            coffee.variety,
            coffee.process,
            coffee.notes
        ] + coffee.flavorNotes
        return searchableFields
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }

}

private enum PastBeansMode: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case roasters = "Roasters"

    var id: Self { self }
}

struct PastRoasterRow: View {
    let group: PastRoasterGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Text(latestCoffeeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("\(group.coffeeCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(group.coffeeCount) completed coffees")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens completed coffees from this roaster")
    }

    private var latestCoffeeText: String {
        let name = group.latestCoffeeName.nonEmpty ?? "Unnamed coffee"
        guard let date = group.latestFinishedAt else { return "Latest: \(name)" }
        return "Latest: \(name) · \(date.shortCoffeeDate)"
    }

    private var accessibilityValue: String {
        let count = group.coffeeCount == 1
            ? "1 completed coffee"
            : "\(group.coffeeCount) completed coffees"
        let latest = group.latestCoffeeName.nonEmpty ?? "Unnamed coffee"
        return "\(count). Latest coffee: \(latest)"
    }
}

struct RoasterPastBeansView: View {
    let store: CoffeeJournalStore
    let group: PastRoasterGroup
    @State private var searchText = ""

    var body: some View {
        List {
            if group.coffeeCount > 50, searchText.trimmedForSearch.isEmpty {
                Text("Showing the newest 50 of \(group.coffeeCount). Search to find older beans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let records = store.pastCoffees(
                matching: searchText,
                roasterKey: group.key,
                limit: 50
            )
            if records.isEmpty {
                Text("No past beans for this roaster.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    NavigationLink {
                        BeanDetailView(store: store, coffeeID: record.coffee.id)
                    } label: {
                        BeanSummaryRow(store: store, coffee: record.coffee)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CoffeeTheme.background.ignoresSafeArea())
        .navigationTitle(group.displayName)
        .searchable(text: $searchText, prompt: "Search this roaster")
    }
}

struct ActiveBeanRow: View {
    let store: CoffeeJournalStore
    let bag: CoffeeBag

    var body: some View {
        let coffee = store.coffee(for: bag.coffeeID)
        HStack(spacing: 12) {
            FlavorArtworkImage(filename: coffee?.flavorArtwork?.thumbnailFilename, cornerRadius: 10)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coffee?.roaster.nonEmpty ?? "Unknown roaster")
                            .font(.headline)
                        Text(activeBeanSubtitle(for: coffee))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(bag.remainingGrams.gramsText + " left")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.accent)
                }
                ProgressView(value: bag.remainingRatio)
                    .tint(CoffeeTheme.accent)
                Text(bag.roastDate.map { "Roasted \($0.shortCoffeeDate)" } ?? "Roast date unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func activeBeanSubtitle(for coffee: Coffee?) -> String {
        let parts = [
            coffee?.origin.nonEmpty,
            coffee?.process.nonEmpty
        ].compactMap(\.self)
        return parts.isEmpty ? "Origin unknown" : parts.joined(separator: " · ")
    }
}

struct BeanSummaryRow: View {
    let store: CoffeeJournalStore
    let coffee: Coffee

    var body: some View {
        HStack(spacing: 12) {
            FlavorArtworkImage(filename: coffee.flavorArtwork?.thumbnailFilename, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(coffee.roaster.nonEmpty ?? "Unknown roaster")
                        .font(.headline)
                    Spacer()
                    if let verdict = coffee.verdict {
                        Text(verdict.rawValue)
                            .font(.caption)
                            .foregroundStyle(CoffeeTheme.accent)
                    }
                }
                Text([coffee.origin, coffee.process].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(coffee.flavorNotes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct BeanDetailView: View {
    let store: CoffeeJournalStore
    let coffeeID: UUID
    @State private var isEditing = false
    @State private var isRegeneratingArtwork = false

    var body: some View {
        if let coffee = store.coffee(for: coffeeID) {
            List {
                if let heroFilename = coffee.flavorArtwork?.heroFilename {
                    Section {
                        FlavorArtworkImage(filename: heroFilename, cornerRadius: 18)
                            .frame(height: 220)
                            .clipped()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } else if let photoAssetIdentifier = displayPhotoAssetIdentifier(for: coffee.id) {
                    Section {
                        BagPhotoHero(assetIdentifier: photoAssetIdentifier)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(coffee.roaster)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(displayName(for: coffee))
                            .font(.title)
                            .fontWeight(.bold)
                            .fixedSize(horizontal: false, vertical: true)

                        if let summary = beanSummary(for: coffee) {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !coffee.flavorNotes.isEmpty {
                            FlowTags(tags: coffee.flavorNotes)
                        }

                        if let verdict = coffee.verdict {
                            Label(verdict.rawValue, systemImage: "heart")
                                .font(.caption)
                                .foregroundStyle(CoffeeTheme.accent)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Bags") {
                    ForEach(store.bags.filter { $0.coffeeID == coffee.id }) { bag in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bagRoastLabel(bag))
                                Text("\(bag.remainingGrams.gramsText) / \(bag.totalGrams.gramsText) left")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bag.status.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(bag.status == .active ? CoffeeTheme.accent : .secondary)
                        }
                    }
                }

                Section("Taste Memory") {
                    ForEach(store.logs(for: coffee.id)) { log in
                        BrewLogRow(store: store, log: log)
                    }
                }

                Section("Artwork") {
                    if let addedAt = coffee.addedAt {
                        LabeledContent("Added", value: addedAt.shortCoffeeDate)
                    }

                    if let job = coffee.artworkJob {
                        LabeledContent("Image status", value: artworkStatusText(job))
                        if let lastError = job.lastError, job.status == .failed {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        isRegeneratingArtwork = true
                        enqueueFlavorArtworkGeneration(
                            for: coffee.id,
                            in: store,
                            source: "manual-regenerate",
                            force: true
                        )
                        isRegeneratingArtwork = false
                    } label: {
                        Label(
                            isRegeneratingArtwork ? "Regenerating…" : "Regenerate flavor image",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(
                        isRegeneratingArtwork ||
                        coffee.flavorNotes.isEmpty ||
                        coffee.artworkJob?.status == .queued ||
                        coffee.artworkJob?.status == .generating
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(CoffeeTheme.background.ignoresSafeArea())
            .navigationTitle("")
            .coffeeNavigationInlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        isEditing = true
                    }
                }
            }
            .sheet(isPresented: $isEditing) {
                EditBeanSheet(store: store, coffee: coffee)
            }
        } else {
            ContentUnavailableView("Coffee not found", systemImage: "questionmark.circle")
        }
    }

    private func displayName(for coffee: Coffee) -> String {
        coffee.name.nonEmpty
            ?? [coffee.origin, coffee.variety].filter { !$0.isEmpty }.joined(separator: " ").nonEmpty
            ?? coffee.roaster.nonEmpty
            ?? "Coffee"
    }

    private func displayPhotoAssetIdentifier(for coffeeID: UUID) -> String? {
        if let activeIdentifier = store.activeBag(for: coffeeID)?.photoAssetIdentifier {
            return activeIdentifier
        }

        return store.bags
            .filter { $0.coffeeID == coffeeID }
            .sorted { ($0.roastDate ?? .distantPast) > ($1.roastDate ?? .distantPast) }
            .compactMap(\.photoAssetIdentifier)
            .first
    }

    private func beanSummary(for coffee: Coffee) -> String? {
        [coffee.origin, coffee.farm, coffee.variety, coffee.process]
            .compactMap(\.nonEmpty)
            .joined(separator: " · ")
            .nonEmpty
    }

    private func artworkStatusText(_ job: ArtworkJobState) -> String {
        switch job.status {
        case .queued: job.attemptCount == 0 ? "Waiting" : "Waiting to retry"
        case .generating: "Generating"
        case .failed: "Couldn’t generate image"
        case .succeeded: "Ready"
        }
    }
}

struct EditBeanSheet: View {
    let store: CoffeeJournalStore
    let coffee: Coffee
    @Environment(\.dismiss) private var dismiss

    @State private var roaster: String
    @State private var name: String
    @State private var origin: String
    @State private var farm: String
    @State private var variety: String
    @State private var process: String
    @State private var flavorText: String
    @State private var notes: String
    @State private var selectedBagID: UUID?
    @State private var hasRoastDate: Bool
    @State private var roastDate: Date
    @State private var totalGrams: Double
    @State private var remainingGrams: Double
    @State private var brewAdvice: String

    init(store: CoffeeJournalStore, coffee: Coffee) {
        self.store = store
        self.coffee = coffee
        let bag = Self.defaultBag(for: coffee, in: store)
        _roaster = State(initialValue: coffee.roaster)
        _name = State(initialValue: coffee.name)
        _origin = State(initialValue: coffee.origin)
        _farm = State(initialValue: coffee.farm)
        _variety = State(initialValue: coffee.variety)
        _process = State(initialValue: coffee.process)
        _flavorText = State(initialValue: coffee.flavorNotes.joined(separator: ", "))
        _notes = State(initialValue: coffee.notes)
        _selectedBagID = State(initialValue: bag?.id)
        _hasRoastDate = State(initialValue: bag?.roastDate != nil)
        _roastDate = State(initialValue: bag?.roastDate ?? Date())
        _totalGrams = State(initialValue: bag?.totalGrams ?? 250)
        _remainingGrams = State(initialValue: bag?.remainingGrams ?? bag?.totalGrams ?? 250)
        _brewAdvice = State(initialValue: bag?.brewAdvice ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Coffee") {
                    LabeledContent("Roaster") {
                        TextField("Required", text: $roaster)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Name") {
                        TextField("Optional", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Origin") {
                        TextField("Country", text: $origin)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Farm") {
                        TextField("Farm or producer", text: $farm)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Variety") {
                        TextField("Cultivar", text: $variety)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Process") {
                        TextField("Washed, natural, etc.", text: $process)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Flavor notes") {
                        TextField("Comma separated", text: $flavorText)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if !coffeeBags.isEmpty {
                    Section("Bag") {
                        if coffeeBags.count > 1 {
                            Picker("Bag", selection: $selectedBagID) {
                                ForEach(coffeeBags) { bag in
                                    Text(bagLabel(for: bag))
                                        .tag(Optional(bag.id))
                                }
                            }
                        }

                        Toggle("Known roast date", isOn: $hasRoastDate)
                        if hasRoastDate {
                            DatePicker("Roast date", selection: $roastDate, displayedComponents: .date)
                        }

                        LabeledContent("Total grams") {
                            TextField("Total", value: $totalGrams, format: .number)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Remaining grams") {
                            TextField("Remaining", value: $remainingGrams, format: .number)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Brew advice", text: $brewAdvice, axis: .vertical)
                    }
                }
            }
            .navigationTitle("Edit Bean")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(roaster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: selectedBagID) { _, newValue in
                guard let bag = store.bag(for: newValue) else { return }
                load(bag)
            }
        }
    }

    private var coffeeBags: [CoffeeBag] {
        store.bags
            .filter { $0.coffeeID == coffee.id }
            .sorted { ($0.roastDate ?? .distantPast) > ($1.roastDate ?? .distantPast) }
    }

    private static func defaultBag(for coffee: Coffee, in store: CoffeeJournalStore) -> CoffeeBag? {
        store.activeBag(for: coffee.id)
            ?? store.bags
                .filter { $0.coffeeID == coffee.id }
                .sorted { ($0.roastDate ?? .distantPast) > ($1.roastDate ?? .distantPast) }
                .first
    }

    private func load(_ bag: CoffeeBag) {
        hasRoastDate = bag.roastDate != nil
        roastDate = bag.roastDate ?? Date()
        totalGrams = bag.totalGrams
        remainingGrams = bag.remainingGrams
        brewAdvice = bag.brewAdvice
    }

    private func save() {
        let updatedCoffee = Coffee(
            id: coffee.id,
            addedAt: coffee.addedAt,
            roaster: roaster.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines),
            farm: farm.trimmingCharacters(in: .whitespacesAndNewlines),
            variety: variety.trimmingCharacters(in: .whitespacesAndNewlines),
            process: process.trimmingCharacters(in: .whitespacesAndNewlines),
            flavorNotes: flavorText.coffeeFlavorNotes,
            verdict: coffee.verdict,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            flavorArtwork: coffee.flavorArtwork,
            artworkJob: coffee.artworkJob
        )
        store.updateCoffee(updatedCoffee)

        if var bag = store.bag(for: selectedBagID) {
            bag.roastDate = hasRoastDate ? roastDate : nil
            bag.totalGrams = max(0, totalGrams)
            bag.remainingGrams = max(0, min(remainingGrams, bag.totalGrams))
            bag.brewAdvice = brewAdvice.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateBag(bag)
        }

        if coffee.artworkInputSignature != updatedCoffee.artworkInputSignature,
           updatedCoffee.artworkInputSignature != nil {
            enqueueFlavorArtworkGeneration(
                for: coffee.id,
                in: store,
                source: "edit-bean-save"
            )
        }
        dismiss()
    }

    private func bagLabel(for bag: CoffeeBag) -> String {
        let date = bag.roastDate?.shortCoffeeDate ?? "unknown roast"
        return "\(bag.status.rawValue.capitalized) · \(date)"
    }
}

private func bagRoastLabel(_ bag: CoffeeBag) -> String {
    guard let roastDate = bag.roastDate else { return "Roast date unknown" }
    return "Roasted \(roastDate.shortCoffeeDate)"
}

struct AddBeanSheet: View {
    let store: CoffeeJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MockBagScanner().manualFallbackDraft()
    @State private var flavorText = ""
    @State private var mode: AddBeanMode = .camera
    @State private var isShowingEditor = false
    @State private var cameraCaptureTrigger = 0
#if canImport(UIKit)
    @State private var selectedPhotoItem: PhotosPickerItem?
#endif
    @State private var scanStatus: BagScanStatus = .idle

    var body: some View {
#if canImport(UIKit)
        Group {
            if mode == .camera, UIImagePickerController.isSourceTypeAvailable(.camera) {
                cameraView
            } else {
                NavigationStack {
                    Group {
                        if isShowingEditor || mode == .scanning {
                            editorForm
                        } else {
                            scannerStartView
                        }
                    }
                    .navigationTitle(isShowingEditor || mode == .scanning ? "Add Bean" : "Scan Bag")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        if isShowingEditor {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") { saveDraft() }
                                    .disabled(draft.coffee.roaster.isEmpty || draft.totalGrams == nil)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            loadPhotoItem(newItem)
        }
#else
        NavigationStack {
            scannerStartView
                .navigationTitle("Scan Bag")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
#endif
    }

#if canImport(UIKit)
    private var cameraView: some View {
        ZStack {
            BagCameraView(onCancel: {
                dismiss()
            }, onCapture: { image in
                mode = .scanning
                scanStatus = .scanning(attempt: 1)
                handleCapturedImage(image)
            }, captureTrigger: cameraCaptureTrigger)
            .ignoresSafeArea()

            VStack {
                Spacer()
                HStack(alignment: .center) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .medium))
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: Circle())
                    }

                    Spacer()

                    Button {
                        cameraCaptureTrigger += 1
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 76, height: 76)
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.45), lineWidth: 8)
                            }
                    }

                    Spacer()

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 24, weight: .medium))
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: Circle())
                            .accessibilityLabel("Photo Library")
                    }
                }
                .padding(.horizontal, 46)
                .padding(.bottom, 40)
            }
        }
    }
#endif

    private var scannerStartView: some View {
        Form {
            Section {
                ScanStatusView(status: scanStatus) {
                    retryFailedScan()
                }

#if canImport(UIKit)
                Button {
                    openCamera()
                } label: {
                    Label("Take bag photo", systemImage: "camera.viewfinder")
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose from Photo Library", systemImage: "photo.on.rectangle")
                }
#endif

                Button {
                    startManualEntry()
                } label: {
                    Label("Manual Entry", systemImage: "square.and.pencil")
                }

                Text("Photo scanning uses AI extraction to fill an editable draft. If extraction is weak, keep editing manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editorForm: some View {
        Form {
            if mode == .scanning || scanStatus.isFailure {
                Section {
                    ScanStatusView(status: scanStatus) {
                        retryFailedScan()
                    }
                }
            }

            if draft.photoAssetIdentifier != nil {
                Section {
                    Label("Bag photo linked from Photo Library", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Coffee") {
                LabeledContent("Roaster") {
                    TextField("Required", text: $draft.coffee.roaster)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Name") {
                    TextField("Optional", text: $draft.coffee.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Origin") {
                    TextField("Country", text: $draft.coffee.origin)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Farm") {
                    TextField("Farm or producer", text: $draft.coffee.farm)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Variety") {
                    TextField("Cultivar", text: $draft.coffee.variety)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Process") {
                    TextField("Washed, natural, etc.", text: $draft.coffee.process)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Flavor notes") {
                    TextField("Comma separated", text: $flavorText)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Bag") {
                LabeledContent("Roast date") {
                    if draft.roastDate == nil {
                        Button("Unknown") {
                            draft.roastDate = Date()
                        }
                    } else {
                        DatePicker(
                            "Roast date",
                            selection: Binding(
                                get: { draft.roastDate ?? Date() },
                                set: { draft.roastDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }
                }
                LabeledContent("Total grams") {
                    TextField("Unknown", value: $draft.totalGrams, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Brew advice", text: $draft.brewAdvice, axis: .vertical)
            }
        }
    }

    private func startManualEntry() {
        scanStatus = .idle
        mode = .editor
        isShowingEditor = true
    }

    private func saveDraft() {
        guard let totalGrams = draft.totalGrams else { return }
        draft.totalGrams = totalGrams
        draft.coffee.flavorNotes = flavorText.coffeeFlavorNotes
        let bag = store.addCoffee(from: draft)
        if store.coffee(for: bag.coffeeID)?.artworkJob?.status == .queued {
            enqueueFlavorArtworkGeneration(
                for: bag.coffeeID,
                in: store,
                source: "add-bean-save"
            )
        }
        dismiss()
    }

#if canImport(UIKit)
    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            mode = .camera
            isShowingEditor = false
        } else {
            mode = .scanning
            isShowingEditor = true
            scanStatus = .failure(
                message: "Camera is not available on this device. Choose a photo from the library instead.",
                retry: nil
            )
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        guard let data = compressedCameraJPEGData(from: image) else {
            scanStatus = .failure(
                message: "Captured image could not be read. Try again or choose from the library.",
                retry: nil
            )
            return
        }

        scanImageData(data, source: "Camera photo", photoAssetIdentifier: nil)
    }

    private func compressedCameraJPEGData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 1800
        let sourceSize = image.size
        let longestSide = max(sourceSize.width, sourceSize.height)
        let ratio = longestSide > 0 ? min(1, maxSide / longestSide) : 1
        let targetSize = CGSize(width: sourceSize.width * ratio, height: sourceSize.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let scaledImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaledImage.jpegData(compressionQuality: 0.8)
    }

    private func loadPhotoItem(_ item: PhotosPickerItem) {
        mode = .scanning
        isShowingEditor = true
        scanStatus = .scanning(attempt: 1)
        let assetIdentifier = item.itemIdentifier
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        scanStatus = .failure(message: "Photo library returned no image data. Try another photo.", retry: nil)
                        isShowingEditor = true
                        selectedPhotoItem = nil
                    }
                    return
                }
                await MainActor.run {
                    selectedPhotoItem = nil
                    scanImageData(data, source: "Library photo", photoAssetIdentifier: assetIdentifier)
                }
            } catch {
                await MainActor.run {
                    scanStatus = .failure(message: "Could not load the selected photo: \(error.localizedDescription)", retry: nil)
                    isShowingEditor = true
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private func scanImageData(
        _ data: Data,
        source: String,
        photoAssetIdentifier: String?,
        attempt: Int = 1
    ) {
        scanStatus = .scanning(attempt: attempt)
        Task {
            do {
                let result = try await BagPhotoScanner().scan(imageData: data)
                await MainActor.run {
                    applyScanResult(
                        result,
                        source: source,
                        photoAssetIdentifier: photoAssetIdentifier,
                        originalData: data,
                        attempt: attempt
                    )
                }
            } catch {
                await MainActor.run {
                    if attempt < 3, isRetryableScanError(error) {
                        scanImageData(
                            data,
                            source: source,
                            photoAssetIdentifier: photoAssetIdentifier,
                            attempt: attempt + 1
                        )
                    } else {
                        scanStatus = .failure(
                            message: "\(source): \(error.localizedDescription)",
                            retry: manualRetryPayload(
                                for: error,
                                imageData: data,
                                source: source,
                                photoAssetIdentifier: photoAssetIdentifier
                            )
                        )
                        isShowingEditor = true
                    }
                }
            }
        }
    }

    private func applyScanResult(
        _ result: BagPhotoScanResult,
        source: String,
        photoAssetIdentifier: String?,
        originalData: Data,
        attempt: Int
    ) {
        guard result.hasRecognizedText else {
            if attempt < 3 {
                scanImageData(
                    originalData,
                    source: source,
                    photoAssetIdentifier: photoAssetIdentifier,
                    attempt: attempt + 1
                )
            } else {
                scanStatus = .failure(
                    message: "\(source): AI extraction returned no usable coffee fields.",
                    retry: .init(imageData: originalData, source: source, photoAssetIdentifier: photoAssetIdentifier)
                )
                isShowingEditor = true
            }
            return
        }

        draft = result.draft
        draft.photoAssetIdentifier = photoAssetIdentifier
        flavorText = result.draft.coffee.flavorNotes.joined(separator: ", ")
        scanStatus = .idle
        mode = .editor
        isShowingEditor = true
    }

    private func isRetryableScanError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }

        guard case BagPhotoScannerError.requestFailed(let statusCode) = error else {
            return false
        }
        return statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode)
    }

    private func manualRetryPayload(
        for error: Error,
        imageData: Data,
        source: String,
        photoAssetIdentifier: String?
    ) -> FailedBagScan? {
        if let scannerError = error as? BagPhotoScannerError {
            switch scannerError {
            case .missingAPIKey, .invalidImage:
                return nil
            case .requestFailed(let statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return nil
                }
            case .invalidResponse, .invalidJSON:
                break
            }
        }

        return FailedBagScan(
            imageData: imageData,
            source: source,
            photoAssetIdentifier: photoAssetIdentifier
        )
    }
#endif

    private func retryFailedScan() {
#if canImport(UIKit)
        guard case .failure(_, let retry?) = scanStatus else { return }
        scanImageData(
            retry.imageData,
            source: retry.source,
            photoAssetIdentifier: retry.photoAssetIdentifier
        )
#endif
    }
}

private enum AddBeanMode: Equatable {
    case camera
    case scanning
    case editor
}

private enum BagScanStatus: Equatable {
    case idle
    case scanning(attempt: Int)
    case failure(message: String, retry: FailedBagScan?)

    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}

private struct FailedBagScan: Equatable {
    var imageData: Data
    var source: String
    var photoAssetIdentifier: String?
}

private struct ScanStatusView: View {
    let status: BagScanStatus
    let onRetry: () -> Void

    var body: some View {
        switch status {
        case .idle:
            Text("Take a bag photo or choose one from Photo Library.")
                .foregroundStyle(.secondary)
        case .scanning(let attempt):
            HStack(spacing: 10) {
                ProgressView()
                Text(attempt == 1 ? "Extracting bag details..." : "Retrying extraction (\(attempt)/3)...")
                    .foregroundStyle(.secondary)
            }
        case .failure(let message, let retry):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                HStack {
                    if retry != nil {
                        Button("Retry") { onRetry() }
                    }
                }
            }
        }
    }
}

#if canImport(UIKit)
struct BagCameraView: UIViewControllerRepresentable {
    let onCancel: () -> Void
    let onCapture: (UIImage) -> Void
    let captureTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel, onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.showsCameraControls = false
        picker.delegate = context.coordinator
        context.coordinator.captureTrigger = captureTrigger
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        guard context.coordinator.captureTrigger != captureTrigger else { return }
        context.coordinator.captureTrigger = captureTrigger
        uiViewController.takePicture()
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCancel: () -> Void
        let onCapture: (UIImage) -> Void
        var captureTrigger = 0

        init(onCancel: @escaping () -> Void, onCapture: @escaping (UIImage) -> Void) {
            self.onCancel = onCancel
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif

struct ReactivateBeanSheet: View {
    let store: CoffeeJournalStore
    let coffee: Coffee
    @Environment(\.dismiss) private var dismiss
    @State private var roastDate = Date()
    @State private var totalGrams = 250.0

    var body: some View {
        NavigationStack {
            Form {
                Section(coffee.name) {
                    DatePicker("Roast date", selection: $roastDate, displayedComponents: .date)
                    TextField("Total grams", value: $totalGrams, format: .number)
                }
            }
            .navigationTitle("New Bag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.reactivateCoffee(
                            coffeeID: coffee.id,
                            roastDate: roastDate,
                            totalGrams: totalGrams
                        )
                        dismiss()
                    }
                    .disabled(totalGrams <= 0)
                }
            }
        }
    }
}

#if canImport(UIKit)
struct BagPhotoHero: View {
    let assetIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(CoffeeTheme.card)
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .frame(height: 220)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: assetIdentifier) {
            image = await BagPhotoLibrary.image(
                for: assetIdentifier,
                targetSize: CGSize(width: 900, height: 520)
            )
        }
    }
}
#else
struct BagPhotoHero: View {
    let assetIdentifier: String

    var body: some View {
        EmptyView()
    }
}
#endif

struct FlowTags: View {
    let tags: [String]

    var body: some View {
        WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(CoffeeTheme.background))
            }
        }
    }
}

@MainActor
func generateFlavorArtwork(
    for coffeeID: UUID,
    requestID: UUID,
    in store: CoffeeJournalStore,
    source: String = "manual",
    force: Bool = false
) async {
#if canImport(UIKit)
    let startedAt = Date()
    guard let coffee = store.coffee(for: coffeeID),
          coffee.artworkInputSignature != nil,
          coffee.artworkJob?.requestID == requestID else {
        FlavorArtworkDiagnostics.record(
            "skipped-no-flavor-notes",
            source: source,
            coffee: store.coffee(for: coffeeID),
            fields: flavorArtworkDiagnosticFields(startedAt: startedAt)
        )
        return
    }

    let generator = FlavorArtworkGenerator()
    let identity: FlavorArtworkGenerationIdentity
    do {
        identity = try generator.identity(for: coffee)
    } catch {
        let previous = coffee.artworkJob
        _ = store.updateArtworkJob(
            coffeeID: coffeeID,
            state: ArtworkJobState(
                status: .failed,
                requestID: requestID,
                forceGeneration: previous?.forceGeneration ?? force,
                attemptCount: previous?.attemptCount ?? 0,
                deferredFailureCount: previous?.deferredFailureCount ?? 0,
                lastAttemptAt: Date(),
                lastError: error.localizedDescription
            ),
            matching: requestID
        )
        FlavorArtworkDiagnostics.record(
            "failed",
            source: source,
            coffee: coffee,
            message: error.localizedDescription,
            fields: flavorArtworkDiagnosticFields(startedAt: startedAt, error: error)
        )
        return
    }

    let requestKey = "\(coffeeID.uuidString)|\(requestID.uuidString)"
    guard await FlavorArtworkInFlightRegistry.shared.begin(requestKey) else {
        FlavorArtworkDiagnostics.record(
            "skipped-in-flight",
            source: source,
            coffee: coffee,
            fields: flavorArtworkDiagnosticFields(identity: identity, startedAt: startedAt)
        )
        return
    }
    defer {
        Task {
            await FlavorArtworkInFlightRegistry.shared.finish(requestKey)
        }
    }

    let maximumAttempts = 3
    let previousAttemptCount = coffee.artworkJob?.attemptCount ?? 0
    let previousDeferredFailureCount = coffee.artworkJob?.deferredFailureCount ?? 0
    let shouldForce = coffee.artworkJob?.forceGeneration ?? force

    for attempt in 1...maximumAttempts {
        guard !Task.isCancelled else { return }
        guard let latestCoffee = store.coffee(for: coffeeID),
              latestCoffee.artworkJob?.requestID == requestID else { return }
        let attemptCount = previousAttemptCount + attempt
        guard store.updateArtworkJob(
            coffeeID: coffeeID,
            state: ArtworkJobState(
                status: .generating,
                requestID: requestID,
                forceGeneration: shouldForce,
                attemptCount: attemptCount,
                deferredFailureCount: previousDeferredFailureCount,
                lastAttemptAt: Date()
            ),
            matching: requestID
        ) else { return }

        FlavorArtworkDiagnostics.record(
            "start",
            source: source,
            coffee: latestCoffee,
            fields: flavorArtworkDiagnosticFields(
                identity: identity,
                startedAt: startedAt,
                attempt: attempt
            )
        )

        do {
            let result = try await generator.generateIfNeeded(
                for: latestCoffee,
                force: shouldForce,
                publicationID: requestID,
                isCurrent: {
                    store.coffee(for: coffeeID)?.artworkJob?.requestID == requestID
                },
                commit: { artwork in
                    store.updateFlavorArtwork(
                        coffeeID: coffeeID,
                        artwork: artwork,
                        matching: requestID
                    )
                }
            )
            guard store.coffee(for: coffeeID)?.artworkJob?.requestID == requestID else { return }
            if let artwork = result.artwork {
                guard store.updateFlavorArtwork(
                    coffeeID: coffeeID,
                    artwork: artwork,
                    matching: requestID
                ) else { return }
            } else {
                guard store.updateArtworkJob(
                    coffeeID: coffeeID,
                    state: ArtworkJobState(
                        status: .succeeded,
                        requestID: requestID,
                        attemptCount: attemptCount,
                        deferredFailureCount: 0,
                        lastAttemptAt: Date()
                    ),
                    matching: requestID
                ) else { return }
            }
            FlavorArtworkDiagnostics.record(
                result.status.rawValue,
                source: source,
                coffee: store.coffee(for: coffeeID),
                message: result.artwork?.cardFilename ?? "",
                fields: flavorArtworkDiagnosticFields(
                    identity: result.identity,
                    artwork: result.artwork,
                    startedAt: startedAt,
                    attempt: attempt
                )
            )
            return
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            let retryable = flavorArtworkErrorIsRetryable(error)
            if retryable, attempt < maximumAttempts {
                let delaySeconds = attempt == 1 ? 2.0 : 5.0
                let nextRetryAt = Date().addingTimeInterval(delaySeconds)
                guard store.updateArtworkJob(
                    coffeeID: coffeeID,
                    state: ArtworkJobState(
                        status: .queued,
                        requestID: requestID,
                        forceGeneration: shouldForce,
                        attemptCount: attemptCount,
                        deferredFailureCount: previousDeferredFailureCount,
                        lastAttemptAt: Date(),
                        nextRetryAt: nextRetryAt,
                        lastError: error.localizedDescription
                    ),
                    matching: requestID
                ) else { return }
                FlavorArtworkDiagnostics.record(
                    "retry-scheduled",
                    source: source,
                    coffee: store.coffee(for: coffeeID),
                    message: error.localizedDescription,
                    fields: flavorArtworkDiagnosticFields(
                        identity: identity,
                        startedAt: startedAt,
                        error: error,
                        attempt: attempt
                    )
                )
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }
                continue
            }

            let deferredFailureCount = retryable ? previousDeferredFailureCount + 1 : previousDeferredFailureCount
            let nextRetryAt = retryable
                ? Date().addingTimeInterval(CoffeeJournalStore.artworkRetryDelay(for: deferredFailureCount))
                : nil
            _ = store.updateArtworkJob(
                coffeeID: coffeeID,
                state: ArtworkJobState(
                    status: retryable ? .queued : .failed,
                    requestID: requestID,
                    forceGeneration: shouldForce,
                    attemptCount: attemptCount,
                    deferredFailureCount: deferredFailureCount,
                    lastAttemptAt: Date(),
                    nextRetryAt: nextRetryAt,
                    lastError: error.localizedDescription
                ),
                matching: requestID
            )
            FlavorArtworkDiagnostics.record(
                "failed",
                source: source,
                coffee: store.coffee(for: coffeeID),
                message: error.localizedDescription,
                fields: flavorArtworkDiagnosticFields(
                    identity: identity,
                    startedAt: startedAt,
                    error: error,
                    attempt: attempt
                )
            )
            #if DEBUG
            let failedCoffee = store.coffee(for: coffeeID)
            print("[FlavorArtwork] generation failed coffeeID=\(coffeeID) roaster=\(failedCoffee?.roaster ?? "unknown") notes=\((failedCoffee?.flavorNotes ?? []).joined(separator: "|")) error=\(error.localizedDescription)")
            #endif
            return
        }
    }
#endif
}

#if canImport(UIKit)
private func flavorArtworkDiagnosticFields(
    identity: FlavorArtworkGenerationIdentity? = nil,
    artwork: FlavorArtwork? = nil,
    startedAt: Date,
    error: Error? = nil,
    attempt: Int? = nil
) -> [String: Any] {
    var fields: [String: Any] = [
        "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
    ]
    if let identity {
        fields["model"] = identity.model
        fields["promptHash"] = identity.promptHash
        fields["flavorKey"] = identity.flavorKey
    }
    if let artwork {
        fields["heroFilename"] = artwork.heroFilename
        fields["cardFilename"] = artwork.cardFilename
        fields["thumbnailFilename"] = artwork.thumbnailFilename
    }
    if let error {
        fields["error"] = error.localizedDescription
    }
    if let attempt {
        fields["attempt"] = attempt
    }
    return fields
}

private func flavorArtworkErrorIsRetryable(_ error: Error) -> Bool {
    if error is URLError {
        return true
    }
    return (error as? FlavorArtworkError)?.isRetryable ?? false
}
#endif

private extension String {
    var coffeeFlavorNotes: [String] {
        components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: subviews, in: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, in: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, in availableWidth: CGFloat) -> [Row] {
        let maxWidth = availableWidth.isFinite ? max(0, availableWidth) : .greatestFiniteMagnitude
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = current.items.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width

            if proposedWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }

            current.append(Item(subview: subview, size: size), spacing: horizontalSpacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Item {
        var subview: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: Item, spacing: CGFloat) {
            if !items.isEmpty {
                width += spacing
            }
            items.append(item)
            width += item.size.width
            height = max(height, item.size.height)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmedForSearch: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension View {
    @ViewBuilder
    func coffeeNavigationInlineTitle() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func addBeanPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
#if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
#else
        sheet(isPresented: isPresented, content: content)
#endif
    }
}
