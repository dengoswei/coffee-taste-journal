import CoffeeJournalCore
import CryptoKit
import Foundation

enum BeanExplorerProfileResourceError: Error {
    case missingResource
    case integrityMismatch
}

enum BeanExplorerProfileResource {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let profileId: String
        let scorerVersion: String
        let lexiconVersion: String
        let swiftScorerSourceSha256: String
        let pythonScorerSourceSha256: String
        let files: [String: String]
    }

    static func load(bundle: Bundle = resourceBundle) throws -> BeanExplorerProfile {
        let manifestData = try data(named: "manifest", bundle: bundle)
        let profileData = try data(named: "profile-prior", bundle: bundle)
        let fixtureData = try data(named: "profile-parity-fixtures", bundle: bundle)
        return try validate(
            manifestData: manifestData,
            profileData: profileData,
            fixtureData: fixtureData
        )
    }

    static func validate(
        manifestData: Data,
        profileData: Data,
        fixtureData: Data
    ) throws -> BeanExplorerProfile {
        guard digest(manifestData) == BeanExplorerGeneratedContract.manifestSHA256 else {
            throw BeanExplorerProfileResourceError.integrityMismatch
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        guard manifest.schemaVersion == 1,
              manifest.profileId == BeanExplorerGeneratedContract.profileID,
              manifest.scorerVersion == BeanExplorerGeneratedContract.scorerVersion,
              manifest.lexiconVersion == BeanExplorerGeneratedContract.lexiconVersion,
              manifest.swiftScorerSourceSha256 == BeanExplorerGeneratedContract.swiftScorerSourceSHA256,
              manifest.pythonScorerSourceSha256 == BeanExplorerGeneratedContract.pythonScorerSourceSHA256 else {
            throw BeanExplorerProfileResourceError.integrityMismatch
        }

        guard manifest.files.count == 2,
              manifest.files["profile-prior.json"] == digest(profileData),
              manifest.files["profile-prior.json"] == BeanExplorerGeneratedContract.profileSHA256,
              manifest.files["profile-parity-fixtures.json"] == digest(fixtureData),
              manifest.files["profile-parity-fixtures.json"] == BeanExplorerGeneratedContract.fixtureSHA256 else {
            throw BeanExplorerProfileResourceError.integrityMismatch
        }

        let profile = try BeanExplorerProfile.decode(profileData)
        guard profile.profileId == manifest.profileId,
              profile.scorerVersion == manifest.scorerVersion,
              profile.lexiconVersion == manifest.lexiconVersion else {
            throw BeanExplorerProfileResourceError.integrityMismatch
        }
        return profile
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func data(named name: String, bundle: Bundle = resourceBundle) throws -> Data {
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "TasteProfile")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url else { throw BeanExplorerProfileResourceError.missingResource }
        return try Data(contentsOf: url)
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}
