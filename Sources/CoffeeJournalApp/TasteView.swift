import CoffeeJournalCore
import SwiftUI

struct TasteView: View {
    let store: CoffeeJournalStore
    @State private var showingCompareBeans = false

    private var summary: TasteSummary {
        TasteAnalyzer.summarize(coffees: store.coffees, logs: store.brewLogs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tasteMemory

                exploreSection

                VStack(alignment: .leading, spacing: 12) {
                    Text("Most Loved")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if summary.mostLovedCoffeeIDs.isEmpty {
                        emptyText("Loved coffees will appear after you log enough cups.")
                    } else {
                        ForEach(summary.mostLovedCoffeeIDs, id: \.self) { coffeeID in
                            if let coffee = store.coffee(for: coffeeID) {
                                BeanSummaryRow(store: store, coffee: coffee)
                                    .coffeeCard()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Patterns")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if summary.insights.isEmpty {
                        emptyText("Preference patterns need several logged cups.")
                    } else {
                        ForEach(summary.insights) { insight in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(insight.title)
                                    .font(.headline)
                                Text(insight.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .coffeeCard()
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(CoffeeTheme.background.ignoresSafeArea())
        .navigationTitle("Taste")
        .sheet(isPresented: $showingCompareBeans) {
            CompareBeansView(store: store)
        }
    }

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explore")
                .font(.title3)
                .fontWeight(.semibold)

            Button {
                showingCompareBeans = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Compare Beans")
                            .font(.headline)
                            .foregroundStyle(CoffeeTheme.accent)
                        Text("Scan bags you're choosing between and see which fits your taste")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(CoffeeTheme.accent)
                }
                .padding(16)
            }
            .background(CoffeeTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.divider, lineWidth: 1)
            )
        }
    }

    private var tasteMemory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Taste Memory")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(CoffeeTheme.subtle)
                .textCase(.uppercase)

            if store.brewLogs.isEmpty {
                Text("No taste memory yet.")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Log cups from active beans and this page will summarize your long-term preferences.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(heroText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(store.brewLogs.count) logged cups")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .coffeeCard()
    }

    private var heroText: String {
        if summary.likedTokens.isEmpty {
            return "Log a few cups and this page will start explaining what you like."
        }
        return "You keep enjoying \(summary.likedTokens.prefix(2).joined(separator: " and "))."
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .coffeeCard()
    }
}
