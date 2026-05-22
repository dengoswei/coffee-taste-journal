import CoffeeJournalCore
import SwiftUI

struct JournalView: View {
    let store: CoffeeJournalStore
    @State private var isLoggingCup = false
    @State private var selectedQuickLogBagID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                quickLogCard
                timeline
            }
            .padding(20)
        }
        .background(CoffeeTheme.background.ignoresSafeArea())
        .navigationTitle("Journal")
        .sheet(isPresented: $isLoggingCup) {
            QuickLogSheet(store: store, initialBagID: selectedQuickLogBagID)
        }
        .onAppear {
            ensureQuickLogSelection()
        }
        .onChange(of: store.activeBags.map(\.id)) { _, _ in
            ensureQuickLogSelection()
        }
    }

    private var quickLogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quick Log")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(CoffeeTheme.subtle)
                    .textCase(.uppercase)

                Spacer()

                if store.activeBags.count > 1 {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.subtle)
                }
            }

            if !store.activeBags.isEmpty {
                PeekBeanCarousel(
                    items: store.activeBags,
                    selectedID: $selectedQuickLogBagID,
                    height: 238,
                    cardWidthRatio: 0.80
                ) { bag in
                    QuickLogBeanCard(store: store, bag: bag)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .onTapGesture {
                            selectedQuickLogBagID = bag.id
                            isLoggingCup = true
                        }
                }

                Text("\(quickLogSelectionIndex + 1) of \(store.activeBags.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "cup.and.saucer")
                        .font(.title2)
                        .foregroundStyle(CoffeeTheme.accent)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(CoffeeTheme.background))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("No active beans")
                            .font(.headline)
                        Text("Add or reactivate a bean before logging a cup.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .coffeeCard()
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Taste Memory")
                .font(.title3)
                .fontWeight(.semibold)

            if store.recentLogs.isEmpty {
                Text("Logged cups will appear here, newest first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .coffeeCard()
            } else {
                ForEach(store.recentLogs) { log in
                    SwipeToDeleteLogRow(store: store, log: log) {
                        withAnimation(.snappy) {
                            store.deleteBrewLog(log.id)
                        }
                    }
                }
            }
        }
    }

    private var selectedQuickLogBag: CoffeeBag? {
        store.activeBags.first { $0.id == selectedQuickLogBagID } ?? store.activeBags.first
    }

    private var quickLogSelectionIndex: Int {
        guard let selectedQuickLogBag else { return 0 }
        return store.activeBags.firstIndex(where: { $0.id == selectedQuickLogBag.id }) ?? 0
    }

    private func ensureQuickLogSelection() {
        guard !store.activeBags.isEmpty else {
            selectedQuickLogBagID = nil
            return
        }
        if selectedQuickLogBagID == nil || !store.activeBags.contains(where: { $0.id == selectedQuickLogBagID }) {
            selectedQuickLogBagID = store.activeBags.first?.id
        }
    }

}

private struct QuickLogBeanCard: View {
    let store: CoffeeJournalStore
    let bag: CoffeeBag

    var body: some View {
        let coffee = store.coffee(for: bag.coffeeID)
        ZStack(alignment: .bottomLeading) {
            FlavorArtworkImage(filename: coffee?.flavorArtwork?.cardFilename, cornerRadius: 20)

            LinearGradient(
                colors: [.black.opacity(0.06), .black.opacity(0.66)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 9) {
                Text(coffee?.roaster.nonEmpty ?? "Unknown roaster")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(beanSubtitle(for: coffee))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                if let notes = flavorNotes(for: coffee) {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    ProgressView(value: bag.remainingRatio)
                        .tint(.white)
                    Text(bag.remainingGrams.gramsText + " left")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 14, x: 0, y: 8)
        .padding(.vertical, 4)
    }

    private func beanSubtitle(for coffee: Coffee?) -> String {
        guard let coffee else { return "Ready to log" }
        let details = [coffee.origin, coffee.process]
            .compactMap(\.nonEmpty)
            .joined(separator: " · ")
        return details.isEmpty ? "Ready to log" : details
    }

    private func flavorNotes(for coffee: Coffee?) -> String? {
        guard let coffee else { return nil }
        let notes = coffee.flavorNotes.prefix(4).joined(separator: ", ")
        return notes.isEmpty ? nil : notes
    }
}

private struct PeekBeanCarousel<Item: Identifiable, Card: View>: View where Item.ID == UUID {
    let items: [Item]
    @Binding var selectedID: UUID?
    var height: CGFloat
    var cardWidthRatio: CGFloat
    var spacing: CGFloat = 12
    var showsEdgeHints = true
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let cardWidth = min(width * cardWidthRatio, width - 34)
            let sideInset = max(CGFloat.zero, (width - cardWidth) / 2)

            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { item in
                        card(item)
                            .frame(width: cardWidth, height: height)
                            .id(item.id)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                    .opacity(phase.isIdentity ? 1 : 0.58)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedID)
            .overlay(alignment: .leading) {
                CarouselEdgeHint(edge: .leading, isVisible: showsEdgeHints && canScrollPrevious)
            }
            .overlay(alignment: .trailing) {
                CarouselEdgeHint(edge: .trailing, isVisible: showsEdgeHints && canScrollNext)
            }
            .animation(.snappy, value: selectedID)
        }
        .frame(height: height)
    }

    private var selectedIndex: Int {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return 0 }
        return index
    }

    private var canScrollPrevious: Bool {
        items.count > 1 && selectedIndex > 0
    }

    private var canScrollNext: Bool {
        items.count > 1 && selectedIndex + 1 < items.count
    }
}

private struct CarouselEdgeHint: View {
    var edge: HorizontalEdge
    var isVisible: Bool

    var body: some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            LinearGradient(
                colors: edge == .leading
                    ? [CoffeeTheme.background.opacity(0.82), CoffeeTheme.background.opacity(0)]
                    : [CoffeeTheme.background.opacity(0), CoffeeTheme.background.opacity(0.82)],
                startPoint: .leading,
                endPoint: .trailing
            )

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(CoffeeTheme.accent.opacity(0.32))
                .frame(width: 4, height: 74)
                .padding(edge == .leading ? .leading : .trailing, 3)
        }
        .frame(width: 34)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private struct SwipeToDeleteLogRow: View {
    let store: CoffeeJournalStore
    let log: BrewLog
    let onDelete: () -> Void
    @State private var offsetX: CGFloat = 0
    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    withAnimation(.snappy) {
                        offsetX = 0
                    }
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.red.opacity(0.86)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete taste memory")
            }
            .padding(.trailing, 16)

            BrewLogRow(store: store, log: log)
                .padding(14)
                .background(CoffeeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoffeeTheme.divider, lineWidth: 1)
                )
                .offset(x: offsetX)
                .onTapGesture {
                    if offsetX < 0 {
                        withAnimation(.snappy) {
                            offsetX = 0
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            offsetX = min(0, max(-revealWidth, value.translation.width))
                        }
                        .onEnded { value in
                            if value.translation.width < -44 {
                                withAnimation(.snappy) {
                                    offsetX = -revealWidth
                                }
                            } else {
                                withAnimation(.snappy) {
                                    offsetX = 0
                                }
                            }
                        }
                )
        }
    }
}

struct BrewLogRow: View {
    let store: CoffeeJournalStore
    let log: BrewLog

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(CoffeeTheme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(CoffeeTheme.background))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(log.date.shortCoffeeDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(log.verdict.rawValue) · \(log.tastingNote)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let grams = log.gramsUsed {
                        Label(grams.gramsText, systemImage: "scalemass")
                    }
                    if let details = log.details {
                        Label(details.method.rawValue, systemImage: "slider.horizontal.3")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var displayName: String {
        guard let coffee = store.coffee(for: log.coffeeID) else { return "Unknown coffee" }
        return coffee.name.nonEmpty ?? coffee.roaster.nonEmpty ?? "Unknown coffee"
    }

    private var iconName: String {
        switch log.details?.method {
        case .e1Prima: "cup.and.saucer.fill"
        case .aeropress: "circle.hexagongrid"
        case .oreaV4, .none: "triangle"
        }
    }
}

struct QuickLogSheet: View {
    let store: CoffeeJournalStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBagID: UUID?
    @State private var verdict: Verdict = .ok
    @State private var tastingNote = ""
    @State private var method: BrewMethod = .oreaV4
    @State private var doseGrams = 15
    @State private var waterGrams = 225
    @State private var waterTemperature = 90
    @State private var grindSetting = ""
    @State private var showBrewDetails = false

    init(store: CoffeeJournalStore, initialBagID: UUID? = nil) {
        self.store = store
        _selectedBagID = State(initialValue: initialBagID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CoffeeTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        beanSelector
                        tasteSection
                        brewDetailsSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Log Cup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(selectedBagID == nil)
                }
            }
            .onAppear {
                configureInitialSelection()
                applyDefaults(for: method)
            }
            .onChange(of: store.activeBags.map(\.id)) { _, _ in
                configureInitialSelection()
            }
            .onChange(of: method) { _, newMethod in
                applyDefaults(for: newMethod)
            }
        }
    }

    private var beanSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Bean")

            if store.activeBags.isEmpty {
                Text("Add an active bean before logging a cup.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .coffeeCard()
            } else {
                PeekBeanCarousel(
                    items: store.activeBags,
                    selectedID: $selectedBagID,
                    height: 178,
                    cardWidthRatio: 0.88,
                    showsEdgeHints: false
                ) { bag in
                    LogCupBeanCard(store: store, bag: bag)
                }
            }
        }
    }

    private var tasteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Taste")

            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Verdict.allCases) { option in
                        Button {
                            verdict = option
                        } label: {
                            Text(option.rawValue)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(verdict == option ? CoffeeTheme.accent : CoffeeTheme.background)
                                .foregroundStyle(verdict == option ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Taste Memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $tastingNote)
                        .frame(minHeight: 132)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(CoffeeTheme.background.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if tastingNote.isEmpty {
                                Text("What did you notice?")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .coffeeCard()
        }
    }

    private var brewDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    showBrewDetails.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionTitle("Brew Details")
                        Text("\(method.rawValue) · \(doseGrams)g / \(waterGrams)g · \(waterTemperature)C")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: showBrewDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.subtle)
                }
                .coffeeCard()
            }
            .buttonStyle(.plain)

            if showBrewDetails {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Method")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Method", selection: $method) {
                            ForEach(BrewMethod.allCases) { method in
                                Text(method.rawValue).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    wheelPicker(title: "Dose", value: $doseGrams, choices: Array(10...25), suffix: "g")
                    wheelPicker(title: "Water", value: $waterGrams, choices: Array(stride(from: 30, through: 320, by: 5)), suffix: "g")
                    wheelPicker(title: "Temperature", value: $waterTemperature, choices: Array(80...98), suffix: "C")

                    HStack {
                        Label("Ratio \(ratioText)", systemImage: "drop")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    TextField("Grind", text: $grindSetting)
                        .textFieldStyle(.roundedBorder)
                }
                .coffeeCard()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(CoffeeTheme.subtle)
            .textCase(.uppercase)
    }

    private func wheelPicker(title: String, value: Binding<Int>, choices: [Int], suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(CoffeeTheme.accent)
            }
#if os(iOS)
            Picker(title, selection: value) {
                ForEach(choices, id: \.self) { choice in
                    Text("\(choice)\(suffix)").tag(choice)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 86)
            .clipped()
#else
            Picker(title, selection: value) {
                ForEach(choices, id: \.self) { choice in
                    Text("\(choice)\(suffix)").tag(choice)
                }
            }
            .pickerStyle(.menu)
#endif
        }
    }

    private var selectedBag: CoffeeBag? {
        store.activeBags.first { $0.id == selectedBagID } ?? store.activeBags.first
    }

    private var selectedCoffee: Coffee? {
        selectedBag.flatMap { store.coffee(for: $0.coffeeID) }
    }

    private var ratioText: String {
        guard doseGrams > 0 else { return "1:0" }
        let ratio = Double(waterGrams) / Double(doseGrams)
        if ratio.rounded() == ratio {
            return "1:\(Int(ratio))"
        }
        return "1:\(String(format: "%.1f", ratio))"
    }

    private func configureInitialSelection() {
        guard !store.activeBags.isEmpty else {
            selectedBagID = nil
            return
        }
        if selectedBagID == nil || !store.activeBags.contains(where: { $0.id == selectedBagID }) {
            selectedBagID = store.activeBags.first?.id
        }
    }

    private func applyDefaults(for method: BrewMethod) {
        switch method {
        case .oreaV4:
            doseGrams = 15
            waterGrams = 225
            waterTemperature = 90
        case .e1Prima:
            doseGrams = 18
            waterGrams = 36
            waterTemperature = 90
        case .aeropress:
            doseGrams = 15
            waterGrams = 210
            waterTemperature = 90
        }
        grindSetting = ""
    }

    private func save() {
        guard let selectedBag else { return }
        let details = BrewDetails(
            method: method,
            doseGrams: Double(doseGrams),
            doseWaterRatio: ratioText,
            waterTemperatureCelsius: Double(waterTemperature),
            grindSetting: grindSetting
        )

        store.logCup(
            coffeeID: selectedBag.coffeeID,
            bagID: selectedBag.id,
            verdict: verdict,
            tastingNote: tastingNote.trimmedForLog.nonEmpty ?? "Fresh cup, note later.",
            gramsUsed: Double(doseGrams),
            details: details
        )
        dismiss()
    }
}

private struct LogCupBeanCard: View {
    let store: CoffeeJournalStore
    let bag: CoffeeBag

    var body: some View {
        let coffee = store.coffee(for: bag.coffeeID)
        ZStack(alignment: .bottomLeading) {
            FlavorArtworkImage(filename: coffee?.flavorArtwork?.cardFilename, cornerRadius: 20)

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(coffee?.roaster.nonEmpty ?? "Unknown roaster")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(bag.remainingGrams.gramsText + " left")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text(beanSubtitle(for: coffee))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                if let notes = flavorNotes(for: coffee) {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }

                ProgressView(value: bag.remainingRatio)
                    .tint(.white)
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 5)
    }

    private func beanSubtitle(for coffee: Coffee?) -> String {
        guard let coffee else { return "Ready to log" }
        let details = [coffee.origin, coffee.process]
            .compactMap(\.nonEmpty)
            .joined(separator: " · ")
        return details.isEmpty ? "Ready to log" : details
    }

    private func flavorNotes(for coffee: Coffee?) -> String? {
        guard let coffee else { return nil }
        let notes = coffee.flavorNotes.prefix(4).joined(separator: ", ")
        return notes.isEmpty ? nil : notes
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmedForLog: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
