import CoffeeJournalCore
import Foundation
import SwiftUI

#if canImport(UIKit)
import CryptoKit
import UIKit

enum FlavorArtworkError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case imageDownloadFailed
    case imageDecodeFailed
    case imageWriteFailed
    case staleRequest
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Ark API key is not configured."
        case .invalidResponse:
            return "Ark returned an unreadable image response."
        case .imageDownloadFailed:
            return "Generated image could not be downloaded."
        case .imageDecodeFailed:
            return "Generated image could not be decoded."
        case .imageWriteFailed:
            return "Generated image variants could not be saved."
        case .staleRequest:
            return "A newer artwork request replaced this one."
        case .requestFailed(let message):
            return message
        }
    }

    var isRetryable: Bool {
        switch self {
        case .imageDownloadFailed, .requestFailed:
            return true
        case .missingAPIKey, .invalidResponse, .imageDecodeFailed, .imageWriteFailed, .staleRequest:
            return false
        }
    }
}

struct FlavorArtworkGenerator {
    static let currentGenerationVersion = 3
    private static let rejectedLegacyPromptHashes: Set<String> = [
        "1b02e168659fe8f6e6e411f1", // SEY Alo: opaque milk-coffee appearance
        "a74f128900a8f3a67e60a52b"  // ALO LOT-2: opaque milk-coffee appearance
    ]
    private let defaultModel = "doubao-seedream-5-0-260128"
    private let defaultBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!

    func identity(for coffee: Coffee) throws -> FlavorArtworkGenerationIdentity {
        let credentials = try credentials()
        let prompt = Self.prompt(for: coffee)
        return Self.identity(for: coffee, model: credentials.model, prompt: prompt)
    }

    @MainActor
    func generateIfNeeded(
        for coffee: Coffee,
        force: Bool = false,
        publicationID: UUID? = nil,
        isCurrent: @escaping () -> Bool = { true },
        commit: @escaping (FlavorArtwork) -> Bool = { _ in true }
    ) async throws -> FlavorArtworkGenerationResult {
        let credentials = try credentials()
        let prompt = Self.prompt(for: coffee)
        let identity = Self.identity(for: coffee, model: credentials.model, prompt: prompt)
        let promptHash = identity.promptHash
        let flavorKey = identity.flavorKey
        Self.debugLog("start coffeeID=\(coffee.id) roaster=\(coffee.roaster) flavorKey=\(flavorKey) promptHash=\(promptHash) notes=\(coffee.flavorNotes.joined(separator: "|"))")

        if !force, let artwork = coffee.flavorArtwork, Self.filesExist(for: artwork) {
            if artwork.promptHash == promptHash {
                Self.debugLog("skip existing artwork coffeeID=\(coffee.id) promptHash=\(promptHash)")
                return FlavorArtworkGenerationResult(status: .skippedExisting, artwork: nil, identity: identity)
            }

            let legacyPromptHash = Self.hash("\(credentials.model)\n\(Self.legacyPrompt(for: coffee))")
            if artwork.generationVersion == nil,
               artwork.promptHash == legacyPromptHash,
               !Self.rejectedLegacyPromptHashes.contains(artwork.promptHash) {
                Self.debugLog("keep accepted legacy artwork coffeeID=\(coffee.id) promptHash=\(artwork.promptHash)")
                return FlavorArtworkGenerationResult(status: .skippedAcceptedLegacy, artwork: nil, identity: identity)
            }

            Self.debugLog("artwork identity changed coffeeID=\(coffee.id) oldPromptHash=\(artwork.promptHash) newPromptHash=\(promptHash); regenerating")
        } else if let artwork = coffee.flavorArtwork, !Self.filesExist(for: artwork) {
            Self.debugLog("metadata exists but image files are missing coffeeID=\(coffee.id) promptHash=\(promptHash); regenerating")
        }

        var index = try Self.loadIndex()
        if !force, let entry = index.entries[flavorKey] {
            if Self.filesExist(for: entry) {
                Self.debugLog("reuse indexed artwork coffeeID=\(coffee.id) flavorKey=\(flavorKey)")
                let artwork = FlavorArtwork(
                    model: credentials.model,
                    generationVersion: Self.currentGenerationVersion,
                    promptHash: promptHash,
                    sourcePrompt: prompt,
                    heroFilename: entry.heroFilename,
                    cardFilename: entry.cardFilename,
                    thumbnailFilename: entry.thumbnailFilename
                )
                guard let published = try ArtworkPublicationCoordinator.publishIfCurrent(
                    isCurrent: isCurrent,
                    makeArtifacts: { artwork },
                    commit: commit,
                    cleanup: { _ in }
                ) else {
                    throw FlavorArtworkError.staleRequest
                }
                return FlavorArtworkGenerationResult(status: .reusedIndex, artwork: published, identity: identity)
            }
            Self.debugLog("indexed artwork files missing flavorKey=\(flavorKey); removing stale index entry")
            index.entries.removeValue(forKey: flavorKey)
            try Self.saveIndex(index)
        }

        let payload = ArkImageGenerationPayload(
            model: credentials.model,
            prompt: prompt,
            sequentialImageGeneration: "disabled",
            responseFormat: "url",
            size: "2K",
            stream: false,
            watermark: false
        )
        Self.debugLog("request Ark image coffeeID=\(coffee.id) model=\(credentials.model) flavorKey=\(flavorKey)")
        let response = try await requestImage(payload: payload, credentials: credentials)
        let imageData = try await downloadImage(from: response.imageURL)
        guard let image = UIImage(data: imageData) else {
            throw FlavorArtworkError.imageDecodeFailed
        }

        guard let artwork = try ArtworkPublicationCoordinator.publishIfCurrent(
            isCurrent: isCurrent,
            makeArtifacts: {
                try saveVariants(
                    image: image,
                    coffeeID: coffee.id,
                    model: credentials.model,
                    prompt: prompt,
                    promptHash: promptHash,
                    publicationID: publicationID
                )
            },
            commit: commit,
            cleanup: Self.deleteVariants
        ) else {
            throw FlavorArtworkError.staleRequest
        }
        index.entries[flavorKey] = FlavorArtworkIndexEntry(
            heroFilename: artwork.heroFilename,
            cardFilename: artwork.cardFilename,
            thumbnailFilename: artwork.thumbnailFilename
        )
        try Self.saveIndex(index)
        Self.debugLog("saved artwork coffeeID=\(coffee.id) flavorKey=\(flavorKey) promptHash=\(promptHash)")
        return FlavorArtworkGenerationResult(status: .generated, artwork: artwork, identity: identity)
    }

    private func credentials() throws -> ArkImageCredentials {
        ArkKeychain.seedFromDebugEnvironment()
        guard let apiKey = ArkKeychain.read("ARK_API_KEY"), !apiKey.isEmpty else {
            throw FlavorArtworkError.missingAPIKey
        }
        let model = ArkKeychain.read("ARK_IMAGE_MODEL").flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let baseURLString = ArkKeychain.read("ARK_BASE_URL").flatMap { $0.isEmpty ? nil : $0 }
        let baseURL = baseURLString.flatMap(URL.init(string:)) ?? defaultBaseURL
        return ArkImageCredentials(apiKey: apiKey, model: model, baseURL: baseURL)
    }

    private func requestImage(
        payload: ArkImageGenerationPayload,
        credentials: ArkImageCredentials
    ) async throws -> ArkGeneratedImage {
        var request = URLRequest(url: credentials.baseURL.appending(path: "images/generations"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FlavorArtworkError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw FlavorArtworkError.requestFailed("Ark image request failed with HTTP \(httpResponse.statusCode): \(body)")
        }

        let envelope = try JSONDecoder().decode(ArkImageGenerationResponse.self, from: data)
        guard let first = envelope.data.first, let url = first.url.flatMap(URL.init(string:)) else {
            throw FlavorArtworkError.invalidResponse
        }
        return ArkGeneratedImage(imageURL: url)
    }

    private func downloadImage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode), !data.isEmpty else {
            throw FlavorArtworkError.imageDownloadFailed
        }
        return data
    }

    private func saveVariants(
        image: UIImage,
        coffeeID: UUID,
        model: String,
        prompt: String,
        promptHash: String,
        publicationID: UUID?
    ) throws -> FlavorArtwork {
        let root = try Self.artworkRootURL()
        let relativeFolder = "FlavorArtwork/\(coffeeID.uuidString)"
        let folder = root.appendingPathComponent(relativeFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let publicationSuffix = publicationID.map { "-\($0.uuidString.lowercased())" } ?? ""
        let heroFilename = "\(relativeFolder)/\(promptHash)\(publicationSuffix)-hero.jpg"
        let cardFilename = "\(relativeFolder)/\(promptHash)\(publicationSuffix)-card.jpg"
        let thumbnailFilename = "\(relativeFolder)/\(promptHash)\(publicationSuffix)-thumb.jpg"

        try writeVariant(image, size: CGSize(width: 1200, height: 860), to: Self.fileURL(root: root, filename: heroFilename))
        try writeVariant(image, size: CGSize(width: 900, height: 620), to: Self.fileURL(root: root, filename: cardFilename))
        try writeVariant(image, size: CGSize(width: 320, height: 320), to: Self.fileURL(root: root, filename: thumbnailFilename))

        return FlavorArtwork(
            model: model,
            generationVersion: Self.currentGenerationVersion,
            promptHash: promptHash,
            sourcePrompt: prompt,
            heroFilename: heroFilename,
            cardFilename: cardFilename,
            thumbnailFilename: thumbnailFilename
        )
    }

    private func writeVariant(_ image: UIImage, size: CGSize, to url: URL) throws {
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { _ in
            image.draw(in: aspectFillRect(for: image.size, in: CGRect(origin: .zero, size: size)))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.82) else {
            throw FlavorArtworkError.imageWriteFailed
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func deleteVariants(_ artwork: FlavorArtwork) {
        guard let root = try? artworkRootURL() else { return }
        for filename in [artwork.heroFilename, artwork.cardFilename, artwork.thumbnailFilename] {
            try? FileManager.default.removeItem(at: fileURL(root: root, filename: filename))
        }
    }

    private func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func prompt(for coffee: Coffee) -> String {
        let notes = Array(coffee.flavorNotes.filter { !$0.isEmpty }.prefix(5))
        let primary = notes.prefix(3).joined(separator: ", ")
        let secondary = notes.dropFirst(3).joined(separator: ", ")
        var prompt = """
        Create a premium editorial image for a private iOS coffee tasting journal. Visualize the sensory flavor notes of this coffee as a fresh, luminous pour-over filter-coffee tasting still life. Coffee: roaster \(coffee.roaster), origin \(coffee.origin), variety \(coffee.variety), process \(coffee.process). Flavor notes in priority order: \(notes.joined(separator: ", ")). Make the first notes most prominent: \(primary).
        """
        if !secondary.isEmpty {
            prompt += " Subtly include these supporting notes only if composition allows: \(secondary)."
        }
        prompt += """
         No readable text, no labels, no logos, no packaging, no UI, no watermark-like marks. The flavor notes must be the main subject. Do not include coffee beans. Avoid unrelated props, table clutter, cafe scenes, hands, notebooks, grinders, kettles, plants, pastries, saucers, or decorative objects. If any coffee vessel appears, it must be exactly one small modern handleless ceramic pour-over tasting cup with no handle, no saucer, and no spoon. The beverage must be visibly dairy-free filter coffee: clear and translucent deep amber at thin edges, transitioning to dark brown-black in the deeper center, with a clean glossy surface. It must never be opaque beige, tan, caramel-milky, or creamy. Absolutely no milk, cream, dairy, plant milk, foam, froth, latte, cappuccino, flat white, latte art, crema, demitasse cup, espresso shot, portafilter, or espresso-machine cue. Otherwise use only the visible fruit, floral, spice, tea, or sensory elements from the flavor notes. Use a clean centered composition with strong silhouette, high visual clarity, a fresh neutral background without a muddy warm-brown cast, and enough contrast for a mobile app card. Must look useful as a small card thumbnail and as a larger bean detail hero image.
        """
        return prompt
    }

    static func legacyPrompt(for coffee: Coffee) -> String {
        let notes = Array(coffee.flavorNotes.filter { !$0.isEmpty }.prefix(5))
        let primary = notes.prefix(3).joined(separator: ", ")
        let secondary = notes.dropFirst(3).joined(separator: ", ")
        var prompt = """
        Create a premium editorial image for a private iOS coffee tasting journal. Visualize the sensory flavor notes of this coffee as a warm pour-over coffee tasting still life. Coffee: roaster \(coffee.roaster), origin \(coffee.origin), variety \(coffee.variety), process \(coffee.process). Flavor notes in priority order: \(notes.joined(separator: ", ")). Make the first notes most prominent: \(primary).
        """
        if !secondary.isEmpty {
            prompt += " Subtly include these supporting notes only if composition allows: \(secondary)."
        }
        prompt += """
         No readable text, no labels, no logos, no packaging, no UI, no watermark-like marks. The flavor notes must be the main subject. Do not include coffee beans. Avoid unrelated props, table clutter, cafe scenes, hands, notebooks, grinders, kettles, plants, pastries, saucers, or decorative objects. If any coffee vessel appears, it must be exactly one small modern handleless ceramic pour-over tasting cup with no handle, no saucer, no spoon, and no espresso styling. Do not show mugs, handled cups, demitasse cups, espresso cups, crema, portafilters, espresso shots, latte art, or espresso-machine cues unless the coffee is explicitly marked as espresso. Otherwise use only the visible fruit, floral, spice, tea, or sensory elements from the flavor notes. Use a clean centered composition with strong silhouette, high visual clarity, calm neutral background, and enough contrast for a mobile app card. Must look useful as a small card thumbnail and as a larger bean detail hero image.
        """
        return prompt
    }

    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func flavorKey(for coffee: Coffee, model: String) -> String {
        let normalizedNotes = coffee.flavorNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "|")
        return hash("v3-filter-coffee\n\(model)\n\(normalizedNotes)")
    }

    private static func identity(
        for coffee: Coffee,
        model: String,
        prompt: String
    ) -> FlavorArtworkGenerationIdentity {
        FlavorArtworkGenerationIdentity(
            model: model,
            promptHash: hash("\(model)\n\(prompt)"),
            flavorKey: flavorKey(for: coffee, model: model)
        )
    }

    static func filesExist(for artwork: FlavorArtwork) -> Bool {
        filesExist(
            heroFilename: artwork.heroFilename,
            cardFilename: artwork.cardFilename,
            thumbnailFilename: artwork.thumbnailFilename
        )
    }

    private static func filesExist(for entry: FlavorArtworkIndexEntry) -> Bool {
        filesExist(
            heroFilename: entry.heroFilename,
            cardFilename: entry.cardFilename,
            thumbnailFilename: entry.thumbnailFilename
        )
    }

    private static func filesExist(heroFilename: String, cardFilename: String, thumbnailFilename: String) -> Bool {
        do {
            let root = try artworkRootURL()
            let filenames = [heroFilename, cardFilename, thumbnailFilename]
            return filenames.allSatisfy {
                FileManager.default.fileExists(atPath: fileURL(root: root, filename: $0).path)
            }
        } catch {
            return false
        }
    }

    private static func loadIndex() throws -> FlavorArtworkIndex {
        let url = try indexURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FlavorArtworkIndex()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FlavorArtworkIndex.self, from: data)
    }

    private static func saveIndex(_ index: FlavorArtworkIndex) throws {
        let url = try indexURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomic])
    }

    private static func indexURL() throws -> URL {
        try artworkRootURL()
            .appendingPathComponent("FlavorArtwork", isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[FlavorArtwork] \(message)")
        #endif
    }

    static func artworkRootURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport.appendingPathComponent("CoffeeJournal", isDirectory: true)
    }

    static func fileURL(root: URL, filename: String) -> URL {
        filename
            .split(separator: "/")
            .reduce(root) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }
}

struct FlavorArtworkGenerationIdentity {
    var model: String
    var promptHash: String
    var flavorKey: String
}

struct FlavorArtworkGenerationResult {
    var status: FlavorArtworkGenerationStatus
    var artwork: FlavorArtwork?
    var identity: FlavorArtworkGenerationIdentity
}

enum FlavorArtworkGenerationStatus: String {
    case skippedExisting = "skipped-existing"
    case skippedAcceptedLegacy = "skipped-accepted-legacy"
    case reusedIndex = "reused-index"
    case generated = "saved"
}

actor FlavorArtworkInFlightRegistry {
    static let shared = FlavorArtworkInFlightRegistry()

    private var keys: Set<String> = []

    func begin(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.insert(key)
        return true
    }

    func finish(_ key: String) {
        keys.remove(key)
    }
}

enum FlavorArtworkDiagnostics {
    @MainActor
    static func record(
        _ event: String,
        source: String,
        coffee: Coffee?,
        message: String = "",
        fields: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "source": source,
            "message": message
        ]
        if let coffee {
            payload["coffeeID"] = coffee.id.uuidString
            payload["roaster"] = coffee.roaster
            payload["name"] = coffee.name
            payload["origin"] = coffee.origin
            payload["variety"] = coffee.variety
            payload["process"] = coffee.process
            payload["flavorNotes"] = coffee.flavorNotes
            payload["hasFlavorArtwork"] = coffee.flavorArtwork != nil
            payload["artworkPromptHash"] = coffee.flavorArtwork?.promptHash ?? ""
            payload["artworkHeroFilename"] = coffee.flavorArtwork?.heroFilename ?? ""
            payload["artworkCardFilename"] = coffee.flavorArtwork?.cardFilename ?? ""
            payload["artworkThumbnailFilename"] = coffee.flavorArtwork?.thumbnailFilename ?? ""
        }
        for (key, value) in fields {
            payload[key] = value
        }

        do {
            let folder = try FlavorArtworkGenerator.artworkRootURL()
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("flavor-artwork.jsonl", isDirectory: false)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: [.atomic])
            }
        } catch {
            print("[FlavorArtworkDiagnostics] failed event=\(event) error=\(error.localizedDescription)")
        }
    }
}

struct FlavorArtworkImage: View {
    var filename: String?
    var cornerRadius: CGFloat = 12
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        CoffeeTheme.card,
                        CoffeeTheme.background
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "sparkles")
                    .foregroundStyle(CoffeeTheme.subtle)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: filename) {
            await reloadImageWithRetry()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await reloadImageWithRetry(maxAttempts: 2, delayNanoseconds: 300_000_000)
            }
        }
    }

    @MainActor
    private func reloadImageWithRetry(
        maxAttempts: Int = 8,
        delayNanoseconds: UInt64 = 1_000_000_000
    ) async {
        guard let filename else {
            image = nil
            return
        }

        for attempt in 1...maxAttempts {
            if Task.isCancelled { return }
            if let loaded = loadImage(filename: filename) {
                image = loaded
                return
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        image = nil
        #if DEBUG
        let fileExists = fileExists(filename: filename)
        FlavorArtworkDiagnostics.record(
            "image-load-failed",
            source: "ui-image-load",
            coffee: nil,
            message: filename,
            fields: [
                "filename": filename,
                "fileExists": fileExists
            ]
        )
        print("[FlavorArtworkImage] failed to load filename=\(filename)")
        #endif
    }

    private func loadImage(filename: String?) -> UIImage? {
        guard let filename else { return nil }
        do {
            let root = try FlavorArtworkGenerator.artworkRootURL()
            let url = FlavorArtworkGenerator.fileURL(root: root, filename: filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return UIImage(contentsOfFile: url.path)
        } catch {
            #if DEBUG
            print("[FlavorArtworkImage] failed to resolve filename=\(filename): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func fileExists(filename: String) -> Bool {
        do {
            let root = try FlavorArtworkGenerator.artworkRootURL()
            let url = FlavorArtworkGenerator.fileURL(root: root, filename: filename)
            return FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }
}

private struct ArkImageCredentials {
    var apiKey: String
    var model: String
    var baseURL: URL
}

private struct ArkGeneratedImage {
    var imageURL: URL
}

private struct FlavorArtworkIndex: Codable {
    var entries: [String: FlavorArtworkIndexEntry] = [:]
}

private struct FlavorArtworkIndexEntry: Codable {
    var heroFilename: String
    var cardFilename: String
    var thumbnailFilename: String
}

private struct ArkImageGenerationPayload: Encodable {
    var model: String
    var prompt: String
    var sequentialImageGeneration: String
    var responseFormat: String
    var size: String
    var stream: Bool
    var watermark: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case sequentialImageGeneration = "sequential_image_generation"
        case responseFormat = "response_format"
        case size
        case stream
        case watermark
    }
}

private struct ArkImageGenerationResponse: Decodable {
    var data: [ImageItem]

    struct ImageItem: Decodable {
        var url: String?
    }
}
#else
struct FlavorArtworkImage: View {
    var filename: String?
    var cornerRadius: CGFloat = 12

    var body: some View {
        EmptyView()
    }
}
#endif
