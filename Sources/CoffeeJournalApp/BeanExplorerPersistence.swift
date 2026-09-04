import Foundation
import CoffeeJournalCore
#if canImport(UIKit)
import UIKit
#endif

enum BeanExplorerPersistence {
    private static let folderName = "CoffeeJournal"
    private static let cacheFolderName = "bean-explorer-cache"
    private static let snapshotFileName = "session.json"

    struct Snapshot: Codable, Equatable {
        var session: BeanExplorerSession
        var imageFiles: [ImageFile]
        var updatedAt: Date

        struct ImageFile: Codable, Equatable, Identifiable {
            var id: UUID
            var fileName: String
        }
    }

    #if canImport(UIKit)
    struct RestoredState {
        var session: BeanExplorerSession
        var images: [(id: UUID, image: UIImage, data: Data)]
    }

    static func load() -> RestoredState? {
        do {
            let data = try Data(contentsOf: snapshotURL())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard !snapshot.session.activeSources.isEmpty || !snapshot.session.activeCandidates.isEmpty else {
                return nil
            }

            var images: [(id: UUID, image: UIImage, data: Data)] = []
            for file in snapshot.imageFiles {
                let url = try imagesDirectory().appendingPathComponent(file.fileName)
                let imageData = try Data(contentsOf: url)
                guard let image = UIImage(data: imageData) else { continue }
                images.append((file.id, image, imageData))
            }
            return RestoredState(session: snapshot.session, images: images)
        } catch {
            debugLog("No bean explorer cache: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(session: BeanExplorerSession, images: [(id: UUID, data: Data)]) {
        do {
            let dir = try imagesDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Replace image files atomically for the active set.
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            var imageFiles: [Snapshot.ImageFile] = []
            var keepNames = Set<String>()
            for item in images {
                let name = "\(item.id.uuidString).jpg"
                keepNames.insert(name)
                let url = dir.appendingPathComponent(name)
                try item.data.write(to: url, options: [.atomic])
                imageFiles.append(.init(id: item.id, fileName: name))
            }
            for name in existing where !keepNames.contains(name) && name.hasSuffix(".jpg") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }

            let snapshot = Snapshot(session: session, imageFiles: imageFiles, updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL(), options: [.atomic])
        } catch {
            debugLog("Failed to save bean explorer cache: \(error.localizedDescription)")
        }
    }
    #endif

    static func clear() {
        do {
            let dir = try cacheDirectory()
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            debugLog("Failed to clear bean explorer cache: \(error.localizedDescription)")
        }
    }

    private static func snapshotURL() throws -> URL {
        try cacheDirectory().appendingPathComponent(snapshotFileName)
    }

    private static func imagesDirectory() throws -> URL {
        try cacheDirectory().appendingPathComponent("images", isDirectory: true)
    }

    private static func cacheDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(cacheFolderName, isDirectory: true)
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[BeanExplorerPersistence] \(message)")
        #endif
    }
}
