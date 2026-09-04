import CoffeeJournalCore
import SwiftUI
#if canImport(UIKit)
import PhotosUI
import UIKit
#endif

struct CompareBeansView: View {
    @Environment(\.dismiss) private var dismiss
    let store: CoffeeJournalStore
    @State private var session = ComparisonSession()
    @State private var currentTab: ComparisonTab = .collect
    @State private var showingResults = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker

                TabView(selection: $currentTab) {
                    collectTab
                        .tag(ComparisonTab.collect)

                    reviewTab
                        .tag(ComparisonTab.review)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Compare Beans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingResults) {
                ComparisonResultsView(candidates: session.candidates) {
                    showingResults = false
                    dismiss()
                }
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 12) {
            TabButton(title: "Collect", isSelected: currentTab == .collect) {
                currentTab = .collect
            }
            TabButton(title: "Review", isSelected: currentTab == .review) {
                currentTab = .review
            }
        }
        .padding(20)
        .background(CoffeeTheme.background)
    }

    private var collectTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add the bags you are choosing between")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Use up to 5 photos. Nothing is added to Beans, and closing this screen discards the session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                photoUploadButtons

                ForEach(session.sourceImages) { source in
                    sourceImageCard(source)
                }

                if !session.sourceImages.isEmpty {
                    Button {
                        currentTab = .review
                    } label: {
                        Text("Review Candidates")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(CoffeeTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(CoffeeTheme.background)
    }

    private var reviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.candidates.isEmpty && session.sourceImages.isEmpty {
                    emptyReviewState
                } else if session.isScanning {
                    scanningState
                } else if session.candidates.isEmpty {
                    noResultsState
                } else {
                    candidatesList
                    comparisonButton
                }
            }
            .padding(20)
        }
        .background(CoffeeTheme.background)
    }

    private var emptyReviewState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No candidates yet")
                .font(.headline)
            Text("Add bag photos in the Collect tab to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .coffeeCard()
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Extracting candidates from photos...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .coffeeCard()
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("No candidates found")
                .font(.headline)
            Text("The AI couldn't extract coffee information from your photos. Try taking clearer photos of the bag labels.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .coffeeCard()
    }

    private var candidatesList: some View {
        ForEach(session.candidates) { candidate in
            CandidateCard(
                candidate: candidate,
                onEdit: { editCandidate(candidate) },
                onRemove: { removeCandidate(candidate) }
            )
        }
    }

    private var comparisonButton: some View {
        Button {
            showComparison()
        } label: {
            Text("See Comparison")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(session.candidates.count >= 2 ? CoffeeTheme.accent : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(session.candidates.count < 2)
        .padding(.top, 8)
    }

#if canImport(UIKit)
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCamera = false

    private var photoUploadButtons: some View {
        HStack(spacing: 12) {
            Button {
                showCamera = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "camera")
                        .font(.system(size: 32))
                    Text("Camera")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(CoffeeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(CoffeeTheme.divider, lineWidth: 1)
                )
            }
            .foregroundStyle(CoffeeTheme.accent)
            .disabled(session.sourceImages.count >= 5)

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                    Text("Photos")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(CoffeeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(CoffeeTheme.divider, lineWidth: 1)
                )
            }
            .foregroundStyle(CoffeeTheme.accent)
            .disabled(session.sourceImages.count >= 5)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                loadPhotoItem(newItem)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CompareBeansCameraView { image in
                showCamera = false
                handleCapturedImage(image)
            } onCancel: {
                showCamera = false
            }
        }
    }

    private func loadPhotoItem(_ item: PhotosPickerItem) {
        let sourceID = UUID()
        session.addSource(id: sourceID, status: .loading)

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    await MainActor.run {
                        session.updateSourceStatus(id: sourceID, status: .failed("Could not load photo"))
                        selectedPhotoItem = nil
                    }
                    return
                }

                await MainActor.run {
                    selectedPhotoItem = nil
                    handleImageData(data, sourceID: sourceID, preview: image)
                }
            } catch {
                await MainActor.run {
                    session.updateSourceStatus(id: sourceID, status: .failed(error.localizedDescription))
                    selectedPhotoItem = nil
                }
            }
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let sourceID = UUID()
        session.addSource(id: sourceID, status: .loading)
        handleImageData(data, sourceID: sourceID, preview: image)
    }

    private func handleImageData(_ data: Data, sourceID: UUID, preview: UIImage) {
        session.updateSourceStatus(id: sourceID, status: .scanning)
        session.updateSourcePreview(id: sourceID, preview: preview)

        Task {
            do {
                let result = try await BagPhotoScanner().scan(imageData: data)
                let candidateCount = result.hasRecognizedText ? 1 : 0

                await MainActor.run {
                    session.updateSourceStatus(
                        id: sourceID,
                        status: .completed(candidateCount: candidateCount)
                    )

                    if result.hasRecognizedText {
                        let candidate = CandidateBean(
                            id: UUID(),
                            sourceID: sourceID,
                            draft: result.draft
                        )
                        session.addCandidate(candidate)
                    }
                }
            } catch {
                await MainActor.run {
                    session.updateSourceStatus(
                        id: sourceID,
                        status: .failed(error.localizedDescription)
                    )
                }
            }
        }
    }
#else
    private var photoUploadButtons: some View {
        Text("Photo scanning is not available on this platform.")
            .foregroundStyle(.secondary)
            .coffeeCard()
    }
#endif

    private func sourceImageCard(_ source: SourceImage) -> some View {
        HStack(spacing: 12) {
#if canImport(UIKit)
            if let preview = source.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
#endif

            VStack(alignment: .leading, spacing: 6) {
                switch source.status {
                case .loading:
                    Text("Loading photo...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .scanning:
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Scanning...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .completed(let count):
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(count) candidate\(count == 1 ? "" : "s") found")
                            .font(.subheadline)
                    }
                case .failed(let message):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                session.removeSource(id: source.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .coffeeCard()
    }

    private func editCandidate(_ candidate: CandidateBean) {
        // TODO: Implement edit sheet
    }

    private func removeCandidate(_ candidate: CandidateBean) {
        session.removeCandidate(id: candidate.id)
    }

    private func showComparison() {
        showingResults = true
    }
}

struct ComparisonResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [CandidateBean]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Candidates")
                            .font(.title3)
                            .fontWeight(.semibold)

                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            candidateResultCard(candidate: candidate, rank: index + 1)
                        }
                    }

                    recommendationNote

                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(CoffeeTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }
            .background(CoffeeTheme.background)
            .navigationTitle("Comparison Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onDone()
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beans Compared")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(CoffeeTheme.subtle)
                .textCase(.uppercase)

            Text("Here are your \(candidates.count) candidates")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Based on the flavor profiles you provided, here's how these beans compare. Full taste-based recommendations require your personal tasting history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .coffeeCard()
    }

    private func candidateResultCard(candidate: CandidateBean, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("#\(rank)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(CoffeeTheme.accent)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.draft.coffee.roaster)
                        .font(.headline)

                    if !candidate.draft.coffee.name.isEmpty {
                        Text(candidate.draft.coffee.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let details = [
                        candidate.draft.coffee.origin,
                        candidate.draft.coffee.variety,
                        candidate.draft.coffee.process
                    ].filter { !$0.isEmpty }.joined(separator: " · ")

                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if !candidate.draft.coffee.flavorNotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flavor Profile")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(CoffeeTheme.subtle)

                    FlowTags(tags: candidate.draft.coffee.flavorNotes)
                }
            }
        }
        .padding(16)
        .coffeeCard()
    }

    private var recommendationNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(CoffeeTheme.accent)
                Text("Get Personalized Recommendations")
                    .font(.headline)
            }

            Text("Want to know which bean best matches your taste? Log more cups in the Journal tab to build your taste profile, then Compare Beans will show personalized fit scores and recommendations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(CoffeeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(CoffeeTheme.accent.opacity(0.3), lineWidth: 2)
        )
    }
}

private enum ComparisonTab {
    case collect
    case review
}

private struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(isSelected ? .white : CoffeeTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isSelected ? CoffeeTheme.accent : CoffeeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct CandidateCard: View {
    let candidate: CandidateBean
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.draft.coffee.roaster)
                        .font(.headline)

                    if !candidate.draft.coffee.name.isEmpty {
                        Text(candidate.draft.coffee.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let details = [
                        candidate.draft.coffee.origin,
                        candidate.draft.coffee.process
                    ].filter { !$0.isEmpty }.joined(separator: " · ")

                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if !candidate.draft.coffee.flavorNotes.isEmpty {
                FlowTags(tags: candidate.draft.coffee.flavorNotes)
            }

            HStack(spacing: 12) {
                Button {
                    onEdit()
                } label: {
                    Text("Edit")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(CoffeeTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Spacer()

                Button {
                    onRemove()
                } label: {
                    Text("Remove")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .coffeeCard()
    }
}

#if canImport(UIKit)
struct CompareBeansCameraView: View {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    @State private var captureTrigger = 0

    var body: some View {
        ZStack {
            BagCameraViewWrapper(captureTrigger: captureTrigger) { image in
                onCapture(image)
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .medium))
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: Circle())
                    }

                    Spacer()

                    Button {
                        captureTrigger += 1
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

                    Color.clear
                        .frame(width: 64, height: 64)
                }
                .padding(.horizontal, 46)
                .padding(.bottom, 40)
            }
        }
    }
}

struct BagCameraViewWrapper: UIViewControllerRepresentable {
    let captureTrigger: Int
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
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
        let onCapture: (UIImage) -> Void
        var captureTrigger = 0

        init(onCapture: @escaping (UIImage) -> Void) {
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
    }
}
#endif

@Observable
final class ComparisonSession {
    var sourceImages: [SourceImage] = []
    var candidates: [CandidateBean] = []

    var isScanning: Bool {
        sourceImages.contains { $0.status == .scanning || $0.status == .loading }
    }

    func addSource(id: UUID, status: SourceImageStatus) {
#if canImport(UIKit)
        sourceImages.append(SourceImage(id: id, status: status, preview: nil))
#else
        sourceImages.append(SourceImage(id: id, status: status))
#endif
    }

    func updateSourceStatus(id: UUID, status: SourceImageStatus) {
        if let index = sourceImages.firstIndex(where: { $0.id == id }) {
            sourceImages[index].status = status
        }
    }

#if canImport(UIKit)
    func updateSourcePreview(id: UUID, preview: UIImage) {
        if let index = sourceImages.firstIndex(where: { $0.id == id }) {
            sourceImages[index].preview = preview
        }
    }
#endif

    func removeSource(id: UUID) {
        sourceImages.removeAll { $0.id == id }
        candidates.removeAll { $0.sourceID == id }
    }

    func addCandidate(_ candidate: CandidateBean) {
        candidates.append(candidate)
    }

    func removeCandidate(id: UUID) {
        candidates.removeAll { $0.id == id }
    }
}

struct SourceImage: Identifiable {
    let id: UUID
    var status: SourceImageStatus
#if canImport(UIKit)
    var preview: UIImage?
#endif
}

enum SourceImageStatus: Equatable {
    case loading
    case scanning
    case completed(candidateCount: Int)
    case failed(String)
}

struct CandidateBean: Identifiable {
    let id: UUID
    let sourceID: UUID
    var draft: BagScanDraft
}
