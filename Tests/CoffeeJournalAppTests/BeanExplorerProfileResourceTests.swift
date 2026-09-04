import CryptoKit
import Foundation
import XCTest
@testable import Coffee_Journal

final class BeanExplorerProfileResourceTests: XCTestCase {
    func testBundledTasteProfilePassesManifestIntegrityCheck() throws {
        let profile = try BeanExplorerProfileResource.load()

        XCTAssertEqual(profile.profileId, BeanExplorerGeneratedContract.profileID)
        XCTAssertEqual(profile.evidenceBase.ratedObservations, 53)
        XCTAssertTrue(profile.statistics.roasterStats.isEmpty)
    }

    func testEveryManifestArtifactFailsClosedAfterTampering() throws {
        let manifest = try BeanExplorerProfileResource.data(named: "manifest")
        let profile = try BeanExplorerProfileResource.data(named: "profile-prior")
        let fixtures = try BeanExplorerProfileResource.data(named: "profile-parity-fixtures")

        for target in 0..<3 {
            var values = [manifest, profile, fixtures]
            values[target].append(0)
            XCTAssertThrowsError(
                try BeanExplorerProfileResource.validate(
                    manifestData: values[0],
                    profileData: values[1],
                    fixtureData: values[2]
                )
            )
        }
    }

    func testGeneratedContractBindsBothScorerImplementations() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let swift = try Data(contentsOf: repository.appendingPathComponent("Sources/CoffeeJournalCore/BeanExplorerScoring.swift"))
        let python = try Data(contentsOf: repository.appendingPathComponent("scripts/portable_coffee_rank.py"))

        XCTAssertEqual(digest(swift), BeanExplorerGeneratedContract.swiftScorerSourceSHA256)
        XCTAssertEqual(digest(python), BeanExplorerGeneratedContract.pythonScorerSourceSHA256)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
