import CoffeeJournalCore
import SwiftUI

#if canImport(UIKit)
import PhotosUI
import UIKit

struct BeanExplorerView: View {
    private struct CollectedImage: Identifiable {
        let id: UUID
        let image: UIImage
        let data: Data
    }

    @Environment(\.dismiss) private var dismiss
    @State private var session = BeanExplorerSession()
    @State private var images: [CollectedImage] = []
    @State private var didRestoreCache = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingCamera = false
    @State private var cameraCaptureTrigger = 0
    @State private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @State private var errorMessage: String?
    @State private var comparison: BeanExplorerComparison?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introContent
                    sourceContent
                    if isScanning {
                        scanningContent
                    }
                    if comparison != nil {
                        exploreContent
                    } else if !isScanning && !session.activeCandidates.isEmpty {
                        comparisonUnavailableContent
                    }
                }
                .padding(20)
            }
            .background(CoffeeTheme.background.ignoresSafeArea())
            .navigationTitle("Find Next Coffee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        persistCache()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !session.activeSources.isEmpty || !images.isEmpty {
                        Button("Clear comparison", role: .destructive) {
                            clearComparison(persist: true)
                        }
                    }
                }
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onAppear {
            restoreCacheIfNeeded()
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotoItems = []
            Task { await loadPhotoItems(items) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            cameraCapture
        }
        .onDisappear {
            scanTasks.values.forEach { $0.cancel() }
            scanTasks.removeAll()
            persistCache()
        }
    }

    private var introContent: some View {
        Text("Find your next coffee")
            .font(.title2.bold())
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: max(0, BeanExplorerSession.maximumImageSources - images.count),
                    matching: .images
                ) {
                    Label(images.isEmpty ? "Choose photos" : "Add photos", systemImage: "photo.on.rectangle.angled")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(CoffeeTheme.accent)
                .disabled(images.count >= BeanExplorerSession.maximumImageSources)

                Button {
                    isShowingCamera = true
                } label: {
                    Image(systemName: "camera")
                        .font(.headline)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(CoffeeTheme.accent)
                .accessibilityLabel("Take a photo")
                .disabled(
                    !UIImagePickerController.isSourceTypeAvailable(.camera) ||
                    session.activeImageSourceCount >= BeanExplorerSession.maximumImageSources
                )
            }

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { imageThumbnail($0) }
                    }
                }
            }
        }
    }

    private var scanningContent: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading coffee packages…")
                    .font(.subheadline.weight(.semibold))
                Text("This usually takes a moment. Results appear automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coffeeCard()
    }


    private var comparisonUnavailableContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(scorableCandidateCount < 2 ? "Add more coffees to compare" : "Comparison in progress")
                .font(.subheadline.weight(.semibold))
            Text("Add photos of coffee packages. The recommendation will appear when at least two coffees can be scored.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .coffeeCard()
    }

    @ViewBuilder
    private var exploreContent: some View {
        if let comparison {
            VStack(alignment: .leading, spacing: 16) {
                recommendationCard(
                    title: "Best match",
                    symbol: "checkmark.seal.fill",
                    score: comparison.bestSupportedMatch,
                    explanation: "The strongest supported match in this group. Fit ranks these options; it is not a purchase guarantee.",
                    prominent: true
                )

                if shouldShowFrontierPick(comparison) {
                    if let frontier = comparison.frontierPick {
                        recommendationCard(
                            title: "Worth exploring",
                            symbol: "sparkles",
                            score: frontier,
                            explanation: frontierExplanation(frontier),
                            prominent: false
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Ranking")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text("Fit · Novelty")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(rankingEntries(from: comparison).enumerated()), id: \.element.score.id) { index, entry in
                        if index > 0 {
                            Divider()
                        }
                        rankingRow(rank: entry.rank, score: entry.score, showSimilarFit: entry.showSimilarFit)
                    }
                    
                    if !comparison.excluded.isEmpty {
                        Divider()
                        ForEach(comparison.excluded, id: \.candidateID) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                                    .frame(width: 28, alignment: .leading)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidateName(item.candidateID))
                                        .font(.subheadline.weight(.semibold))
                                    Text("缺信息 · \(item.reason)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer(minLength: 8)
                            }
                        }
                    }
                }
                .coffeeCard()

                Text("Profile snapshot: \(profileDate(comparison.datasetGeneratedAt)) · \(comparison.ratedObservations) ratings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            }
        } else {
            ProgressView()
        }
    }

    private func recommendationCard(
        title: String,
        symbol: String,
        score: BeanExplorerScore,
        explanation: String,
        prominent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(prominent ? CoffeeTheme.accent : .primary)
            Text(score.roaster)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(score.name)
                .font(.title3.bold())
            HStack(spacing: 18) {
                scoreMetric("Fit", value: score.fit)
                scoreMetric("Novelty", value: score.novelty)
            }
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .coffeeCard()
    }

    private func scoreMetric(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.title3.monospacedDigit().bold())
        }
    }

    private struct RankingEntry: Identifiable {
        var id: String { score.id }
        let rank: Int
        let score: BeanExplorerScore
        let showSimilarFit: Bool
    }

    private func rankingEntries(from comparison: BeanExplorerComparison) -> [RankingEntry] {
        var entries: [RankingEntry] = []
        var rank = 1
        for band in comparison.fitBands {
            var isFirstInBand = true
            for score in band.scores {
                entries.append(
                    RankingEntry(
                        rank: rank,
                        score: score,
                        showSimilarFit: band.isSimilarFit && isFirstInBand
                    )
                )
                isFirstInBand = false
                rank += 1
            }
        }
        return entries
    }

    private func rankingRow(rank: Int, score: BeanExplorerScore, showSimilarFit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showSimilarFit {
                Text("Similar Fit")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CoffeeTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CoffeeTheme.accent.opacity(0.12), in: Capsule())
            }

            HStack(alignment: .top, spacing: 12) {
                Text("#\(rank)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(CoffeeTheme.accent)
                    .frame(width: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(score.roaster)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(score.name)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    let rawNotes = session.activeCandidates.first(where: { $0.id == score.id })?.draft.flavorNotes ?? []
                    if !rawNotes.isEmpty {
                        Text(rawNotes.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !score.matchedFamilies.isEmpty {
                        Text(score.matchedFamilies.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    rankingScoreChip(label: "Fit", value: score.fit)
                    rankingScoreChip(label: "Novelty", value: score.novelty)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rankingScoreChip(label: String, value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(minWidth: 64, alignment: .trailing)
    }

    private func imageThumbnail(_ item: CollectedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: item.image)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 92)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Selected coffee package image")

            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    removeImage(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Color.red.opacity(0.9))
                }
                .accessibilityLabel("Remove photo")
                .padding(6)

                sourceStatus(item.id)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(5)
        }
        .contextMenu {
            if sourceCanScan(item.id) {
                Button {
                    startScan(sourceID: item.id)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                removeImage(item)
            } label: {
                Label("Remove photo", systemImage: "trash")
            }
        }
    }

    private var cameraCapture: some View {
        ZStack {
            BagCameraView(
                onCancel: { isShowingCamera = false },
                onCapture: { image in
                    isShowingCamera = false
                    addImage(image)
                },
                captureTrigger: cameraCaptureTrigger
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        isShowingCamera = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.semibold))
                            .frame(width: 50, height: 50)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Close camera")
                    Spacer()
                }
                .padding()

                Spacer()

                Button {
                    cameraCaptureTrigger += 1
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 76, height: 76)
                        .overlay {
                            Circle().stroke(.white.opacity(0.45), lineWidth: 8)
                        }
                }
                .accessibilityLabel("Take photo")
                .padding(.bottom, 38)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func loadPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = "The selected photo could not be read."
                    continue
                }
                addImage(image)
            } catch {
                errorMessage = "Could not load a selected photo: \(error.localizedDescription)"
            }
        }
        persistCache()
    }

    @MainActor
    private func addImage(_ image: UIImage) {
        do {
            let prepared = try preparedImage(image)
            let source = try session.addImageSource()
            images.append(.init(id: source.id, image: prepared.image, data: prepared.data))
            comparison = nil
            persistCache()
            startScan(sourceID: source.id)
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func preparedImage(_ image: UIImage) throws -> (image: UIImage, data: Data) {
        let maxSide: CGFloat = 2048
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { throw BeanExplorerImageError.invalidImage }
        let ratio = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8), data.count <= 4_000_000 else {
            throw BeanExplorerImageError.imageTooLarge
        }
        return (resized, data)
    }

    private func removeImage(_ image: CollectedImage) {
        scanTasks[image.id]?.cancel()
        scanTasks[image.id] = nil
        try? session.cancelRequest(sourceID: image.id)
        try? session.removeSource(sourceID: image.id)
        images.removeAll { $0.id == image.id }
        refreshComparison()
        persistCache()
    }

    @MainActor
    private func startScan(sourceID: UUID) {
        guard let image = images.first(where: { $0.id == sourceID }),
              scanTasks[sourceID] == nil else { return }
        let remainingCapacity = BeanExplorerSession.maximumCandidates - session.activeCandidates.count
        guard remainingCapacity > 0 else {
            errorMessage = "This comparison already has \(BeanExplorerSession.maximumCandidates) coffees."
            return
        }

        let request: BeanExplorerExtractionRequest
        do {
            request = try session.beginExtraction(
                sourceID: sourceID,
                promptContractHash: BeanExplorerPhotoScanner.promptContractHash
            )
        } catch {
            errorMessage = message(for: error)
            return
        }

        scanTasks[sourceID] = Task {
            do {
                let result = try await BeanExplorerPhotoScanner().scan(
                    imageData: image.data,
                    remainingCapacity: remainingCapacity
                )
                try Task.checkCancellation()
                let committed = try session.commitExtraction(
                    request: request,
                    drafts: result.candidates,
                    rejectedCount: result.rejectedCount
                )
                if committed {
                    for candidate in session.activeCandidates where candidate.sourceID == sourceID {
                        trustCandidateIfPossible(candidate.id)
                    }
                    refreshComparison()
                }
            } catch is CancellationError {
                try? session.cancelRequest(sourceID: sourceID)
            } catch {
                _ = session.failExtraction(request: request)
                if case BagPhotoScannerError.missingAPIKey = error {
                    errorMessage = error.localizedDescription
                } else if case BeanExplorerSessionError.candidateLimitReached = error {
                    errorMessage = "This comparison already has \(BeanExplorerSession.maximumCandidates) coffees."
                } else {
                    errorMessage = "The image could not be read. Touch and hold the photo to try again."
                }
                refreshComparison()
            }
            scanTasks[sourceID] = nil
        }
    }

    @ViewBuilder
    private func sourceStatus(_ sourceID: UUID) -> some View {
        switch session.activeSource(id: sourceID)?.requestState {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Scanning packages")
        case .succeeded(let count):
            Label("\(count)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Found \(count) candidates")
        case .partialSuccess(let validCount, let rejectedCount):
            Label("\(validCount)/\(validCount + rejectedCount)", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Found \(validCount) candidates; rejected \(rejectedCount) unclear regions")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Scan failed")
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Scan cancelled")
        case .idle, .none:
            EmptyView()
        }
    }

    private func sourceCanScan(_ sourceID: UUID) -> Bool {
        switch session.activeSource(id: sourceID)?.requestState {
        case .idle, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    private var scoreCandidates: [BeanExplorerScoreCandidate] {
        session.activeCandidates.map { candidate in
            BeanExplorerScoreCandidate(
                id: candidate.id,
                roaster: candidate.draft.roaster,
                name: candidate.draft.name,
                origin: candidate.draft.origin,
                process: candidate.draft.process,
                descriptors: candidate.draft.flavorNotes,
                isConfirmed: candidate.isConfirmed,
                confirmedFields: candidate.confirmedFields,
                fieldProvenance: candidate.fieldProvenance,
                unresolvedFields: candidate.draft.uncertainFields
            )
        }
    }

    private var scorableCandidateCount: Int {
        guard let profile = try? BeanExplorerProfileResource.load(),
              let scorer = try? BeanExplorerScorer(profile: profile) else { return 0 }
        return scoreCandidates.filter { scorer.exclusionReason($0) == nil }.count
    }

    private func scoringIssue(_ candidate: BeanExplorerCandidate) -> String? {
        guard let profile = try? BeanExplorerProfileResource.load(),
              let scorer = try? BeanExplorerScorer(profile: profile) else {
            return "The bundled taste profile failed its integrity check."
        }
        return scorer.exclusionReason(
            BeanExplorerScoreCandidate(
                id: candidate.id,
                roaster: candidate.draft.roaster,
                name: candidate.draft.name,
                origin: candidate.draft.origin,
                process: candidate.draft.process,
                descriptors: candidate.draft.flavorNotes,
                isConfirmed: candidate.isConfirmed,
                confirmedFields: candidate.confirmedFields,
                fieldProvenance: candidate.fieldProvenance,
                unresolvedFields: candidate.draft.uncertainFields
            )
        )
    }

    private var isScanning: Bool {
        session.activeSources.contains { source in
            if case .uploading = source.requestState { return true }
            return false
        }
    }

    private func trustCandidateIfPossible(_ candidateID: String) {
        try? session.confirmCandidate(id: candidateID)
    }

    private func refreshComparison() {
        guard !isScanning, scorableCandidateCount >= 2 else {
            comparison = nil
            persistCache()
            return
        }
        
        Task {
            do {
                let profile = try BeanExplorerProfileResource.load()
                let scorer = try BeanExplorerScorer(profile: profile)
                
                // Normalize candidates before scoring
                var normalizedCandidates: [BeanExplorerScoreCandidate] = []
                for candidate in scoreCandidates {
                    let normalized = try await normalizeCandidate(candidate, profile: profile)
                    normalizedCandidates.append(normalized)
                }
                
                let result = try scorer.compare(normalizedCandidates)
                guard result.ranking.count >= 2 else {
                    throw BeanExplorerScoringError.insufficientCandidates
                }
                
                await MainActor.run {
                    comparison = result
                    persistCache()
                }
            } catch {
                await MainActor.run {
                    comparison = nil
                    let errorMsg: String
                    if let normError = error as? CoffeeDescriptorNormalizerError {
                        errorMsg = "Flavor note normalization failed: \(normError.localizedDescription)"
                    } else {
                        errorMsg = "The taste profile could not be verified."
                    }
                    errorMessage = errorMsg
                    persistCache()
                }
            }
        }
    }
    
    @MainActor
    private func normalizeCandidate(
        _ candidate: BeanExplorerScoreCandidate,
        profile: BeanExplorerProfile
    ) async throws -> BeanExplorerScoreCandidate {
        // Skip normalize only if pre-matched families already set (from prior normalize or test)
        guard candidate.preMatchedFamilies == nil else {
            return candidate
        }
        
        // Normalize by default: map descriptors/origin/process to canonical schema
        // Try normalize with retry; on failure → surface error, do NOT fall back to lexicon
        let normalizer = CoffeeDescriptorNormalizer(profile: profile)
        let normalized = try await normalizer.normalize(
            descriptors: candidate.descriptors,
            origin: candidate.origin,
            process: candidate.process
        )
        
        // Return candidate with normalized families and canonical origin/process
        return BeanExplorerScoreCandidate(
            id: candidate.id,
            roaster: candidate.roaster,
            name: candidate.name,
            origin: normalized.origin ?? candidate.origin,
            process: normalized.process ?? candidate.process,
            descriptors: normalized.descriptorTermsKeptForDisplay,
            isConfirmed: candidate.isConfirmed,
            confirmedFields: candidate.confirmedFields,
            fieldProvenance: candidate.fieldProvenance,
            unresolvedFields: candidate.unresolvedFields,
            preMatchedFamilies: normalized.flavorFamilies
        )
    }
    
    private func needsNormalize(_ candidate: BeanExplorerScoreCandidate) -> Bool {
        // Normalize by default unless pre-matched families already set
        return candidate.preMatchedFamilies == nil
    }

    private func restoreCacheIfNeeded() {
        guard !didRestoreCache else { return }
        didRestoreCache = true
        guard let restored = BeanExplorerPersistence.load() else { return }
        session = restored.session
        images = restored.images.map { CollectedImage(id: $0.id, image: $0.image, data: $0.data) }
        let imageIDs = Set(images.map(\.id))
        for source in session.activeSources where source.kind == .image && !imageIDs.contains(source.id) {
            try? session.removeSource(sourceID: source.id)
        }
        // Drop in-flight uploading markers from a previous process.
        for source in session.activeSources {
            if case .uploading = source.requestState {
                try? session.cancelRequest(sourceID: source.id)
            }
        }
        refreshComparison()
    }

    private func persistCache() {
        BeanExplorerPersistence.save(
            session: session,
            images: images.map { ($0.id, $0.data) }
        )
    }

    private func clearComparison(persist: Bool) {
        scanTasks.values.forEach { $0.cancel() }
        scanTasks.removeAll()
        session.clear()
        images = []
        comparison = nil
        if persist {
            BeanExplorerPersistence.clear()
        }
    }

    private func frontierExplanation(_ score: BeanExplorerScore) -> String {
        let bridge = score.familiarBridges.first.map {
            "Familiar bridge: \($0.familyName), seen in \($0.lovedCount) Loved coffees across \($0.observations) rated examples."
        } ?? ""
        let novelty = score.noveltyDimensions.isEmpty
            ? "Its exploration value comes from the balance of this shortlist."
            : "It adds \(score.noveltyDimensions.joined(separator: ", "))."
        return "\(bridge) \(novelty) Risk: these are seller claims, and direct-history adjustment is unavailable."
    }

    private func profileDate(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: timestamp) else { return timestamp }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    
    private func shouldShowFrontierPick(_ comparison: BeanExplorerComparison) -> Bool {
        guard comparison.frontierPick != nil else { return false }
        
        // Check if novelty scores are meaningfully different
        let allNovelties = comparison.ranking.map { $0.novelty }
        guard !allNovelties.isEmpty else { return false }
        
        let maxNovelty = allNovelties.max() ?? 0
        let minNovelty = allNovelties.min() ?? 0
        
        // Show only if there's meaningful novelty differentiation (> 0.05 spread)
        return maxNovelty - minNovelty > 0.05
    }
    
    private func candidateName(_ candidateID: String) -> String {
        guard let candidate = session.activeCandidates.first(where: { $0.id == candidateID }) else {
            return candidateID
        }
        
        let roaster = candidate.draft.roaster.isEmpty ? "Unknown roaster" : candidate.draft.roaster
        let name = candidate.draft.name.isEmpty ? "Unknown coffee" : candidate.draft.name
        return "\(roaster) — \(name)"
    }

    private func message(for error: Error) -> String {
        switch error {
        case BeanExplorerSessionError.imageSourceLimitReached:
            return "This comparison already has \(BeanExplorerSession.maximumImageSources) photos."
        case BeanExplorerSessionError.candidateLimitReached:
            return "This comparison already has \(BeanExplorerSession.maximumCandidates) coffees."
        case BeanExplorerSessionError.candidateNotFound:
            return "The candidate is no longer available."
        case BeanExplorerImageError.imageTooLarge:
            return "The photo could not be reduced below the 4 MB session limit."
        default:
            return "The source could not be added."
        }
    }
}

private enum BeanExplorerImageError: Error {
    case invalidImage
    case imageTooLarge
}

private extension String {
    var explorerFlavorNotes: [String] {
        components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#else

struct BeanExplorerView: View {
    var body: some View {
        Text("Bean comparison is available on iPhone.")
    }
}

#endif
