import CoffeeJournalCore
import SwiftUI

struct TasteView: View {
    let store: CoffeeJournalStore
    @State private var isShowingBeanExplorer = false

    private var summary: TasteSummary {
        TasteAnalyzer.summarize(coffees: store.coffees, logs: store.brewLogs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHero
                explorerEntry
                snapshotNotice
                flavorFingerprint
                evidenceBase
                mostLoved
                unknowns
            }
            .padding(20)
        }
        .background(CoffeeTheme.background.ignoresSafeArea())
        .navigationTitle("Taste")
        .beanExplorerPresentation(isPresented: $isShowingBeanExplorer)
    }

    private var explorerEntry: some View {
        Button {
            isShowingBeanExplorer = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.metering.multispot")
                    .font(.title2.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.white)
                    .background(CoffeeTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Discover")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Match bags to your taste profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CoffeeTheme.subtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .coffeeCard()
        .accessibilityHint("Opens a temporary coffee comparison")
    }

    private var profileHero: some View {
        ZStack(alignment: .bottomLeading) {
            Image("TasteProfileHero")
                .resizable()
                .scaledToFill()
                .frame(height: 260)
                .clipped()

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.68)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR FLAVOR FINGERPRINT")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.82))
                Text(PersonalTasteProfile.headline)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
    }

    private var snapshotNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Profile snapshot", systemImage: "camera.aperture")
                    .font(.headline)
                Spacer()
                Text(PersonalTasteProfile.snapshotDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(PersonalTasteProfile.narrative)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This frozen snapshot can lag new tastings until the journal profile is refreshed.")
                .font(.caption)
                .foregroundStyle(CoffeeTheme.accent)
        }
        .coffeeCard()
    }

    private var flavorFingerprint: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Loved-tier concentration", subtitle: "The strongest ordering signal in your rated history")

            ForEach(PersonalTasteProfile.families) { family in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(family.color)
                            .frame(width: 9, height: 9)
                        Text(family.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(family.lovedCount) of 7 Loved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(family.color.opacity(0.14))
                            Capsule()
                                .fill(family.color)
                                .frame(width: geometry.size.width * CGFloat(family.lovedCount) / 4)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(family.isStable ? "Reliable signal" : "Thin signal")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(family.isStable ? CoffeeTheme.accent : .secondary)
                        Spacer()
                        if family.ratedCount > 0 {
                            Text("n=\(family.ratedCount) · weighted \(family.weightedRating, format: .number.precision(.fractionLength(3)))/3")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .coffeeCard()
    }

    private var evidenceBase: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Evidence base", subtitle: "Ratings are evidence; written notes are context only")

            ratingDistribution

            HStack(spacing: 10) {
                evidenceMetric(value: "\(PersonalTasteProfile.ratedObservations)", label: "ratings")
                evidenceMetric(value: "\(PersonalTasteProfile.substantiveNotes)", label: "first-person notes")
                evidenceMetric(value: "\(store.brewLogs.count)", label: "cups in app")
            }

            Label(
                "Self-selected sample: 0 Disliked ratings. Strong for comparing beans you would buy, weak at locating your lower bound.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .coffeeCard()
    }

    private var ratingDistribution: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(PersonalTasteProfile.ratingTiers.filter { $0.count > 0 }) { tier in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tier.color)
                            .frame(width: geometry.size.width * CGFloat(tier.count) / CGFloat(PersonalTasteProfile.ratedObservations))
                    }
                }
            }
            .frame(height: 14)

            HStack(spacing: 14) {
                ForEach(PersonalTasteProfile.ratingTiers) { tier in
                    HStack(spacing: 4) {
                        Circle().fill(tier.color).frame(width: 7, height: 7)
                        Text("\(tier.name) \(tier.count)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var mostLoved: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Most Loved in this app", subtitle: "Live journal entries, separate from the frozen profile")

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
    }

    private var unknowns: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Still unknown", subtitle: "The next useful gaps to fill")

            ForEach(PersonalTasteProfile.unknowns, id: \.self) { unknown in
                Label(unknown, systemImage: "circle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .coffeeCard()
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func evidenceMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(CoffeeTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .coffeeCard()
    }
}

private extension View {
    @ViewBuilder
    func beanExplorerPresentation(isPresented: Binding<Bool>) -> some View {
#if canImport(UIKit)
        fullScreenCover(isPresented: isPresented) {
            BeanExplorerView()
        }
#else
        sheet(isPresented: isPresented) {
            BeanExplorerView()
        }
#endif
    }
}
