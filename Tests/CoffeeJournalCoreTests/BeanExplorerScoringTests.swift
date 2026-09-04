import Foundation
import XCTest
@testable import CoffeeJournalCore

final class BeanExplorerScoringTests: XCTestCase {
    func testBothImplementationsConsumeTheCommittedContractFixtures() throws {
        let document = try loadFixtures()
        let scorer = try BeanExplorerScorer(profile: loadProfile())

        let scoreCandidates = document.scoreCases.map { makeCandidate($0.candidate) }
        let scored = try scorer.compare(scoreCandidates)
        let scoredByID = Dictionary(uniqueKeysWithValues: scored.ranking.map { ($0.candidateID, $0) })
        for fixture in document.scoreCases {
            XCTAssertEqual(scoredByID[fixture.candidate.id]?.fit, fixture.expected.fitScore)
            XCTAssertEqual(scoredByID[fixture.candidate.id]?.novelty, fixture.expected.noveltyScore)
        }

        for fixture in document.comparisonCases {
            let comparison = try scorer.compare(fixture.candidates.map(makeCandidate))
            XCTAssertEqual(comparison.ranking.map(\.candidateID), fixture.expectedRanking)
            XCTAssertEqual(comparison.bestSupportedMatch.candidateID, fixture.expectedBest)
            XCTAssertEqual(comparison.frontierPick?.candidateID, fixture.expectedFrontier)
            XCTAssertEqual(comparison.fitBands.map { $0.scores.map(\.candidateID) }, fixture.expectedBands)
            for score in comparison.ranking {
                let actual = score.familiarBridges.map {
                    ExpectedBridge(category: $0.familyID, topTierCount: $0.lovedCount, observations: $0.observations)
                }
                XCTAssertEqual(actual, fixture.expectedBridges[score.candidateID])
            }
        }

        for fixture in document.eligibilityCases {
            XCTAssertEqual(
                scorer.exclusionReason(makeCandidate(fixture.candidate)),
                fixture.expectedReason
            )
        }

        for fixture in document.normalizationCases {
            XCTAssertEqual(BeanExplorerScorer.contractNormalize(fixture.input), fixture.expected)
        }
        for fixture in document.roundingCases {
            XCTAssertEqual(BeanExplorerScorer.contractRoundTenth(fixture.input), fixture.expected)
        }
        for fixture in document.bandCases {
            let scores = fixture.fits.enumerated().map { index, fit in
                BeanExplorerScore(
                    candidateID: "band-\(index)",
                    roaster: "",
                    name: "",
                    fit: fit,
                    novelty: 0,
                    matchedFamilies: [],
                    familiarBridges: [],
                    noveltyDimensions: []
                )
            }
            XCTAssertEqual(
                BeanExplorerScorer.makeFitBands(scores, threshold: 1.5).map { $0.scores.map(\.candidateID) },
                fixture.expected
            )
        }
        for fixture in document.bridgeBoundaryCases {
            XCTAssertEqual(
                BeanExplorerScorer.bridgeQualifies(
                    topTierCount: fixture.topTierCount,
                    observations: fixture.observations,
                    profile: scorer.profile
                ),
                fixture.expected
            )
        }
        for fixture in document.roleCases {
            let rows = fixture.rows.map { row in
                BeanExplorerScore(
                    candidateID: row.candidateId,
                    roaster: "",
                    name: "",
                    fit: row.profileFitScore,
                    novelty: row.profileNoveltyScore,
                    matchedFamilies: [],
                    familiarBridges: row.familiarBridges.isEmpty ? [] : [
                        .init(familyID: "fixture", familyName: "Fixture", lovedCount: 3, observations: 6)
                    ],
                    noveltyDimensions: []
                )
            }
            let resolved = BeanExplorerScorer.resolveScoredRows(rows, profile: scorer.profile)
            XCTAssertEqual(resolved.ranking.map(\.candidateID), fixture.expectedRanking)
            XCTAssertEqual(resolved.bestSupportedMatch.candidateID, fixture.expectedBest)
            XCTAssertEqual(resolved.frontierPick?.candidateID, fixture.expectedFrontier)
            XCTAssertEqual(resolved.fitBands.map { $0.scores.map(\.candidateID) }, fixture.expectedBands)
        }
    }

    func testSwiftScoresMatchGeneratedPythonParityFixtures() throws {
        let scorer = try BeanExplorerScorer(profile: loadProfile())
        let result = try scorer.compare([
            candidate(
                id: "fixture-colombia-washed",
                roaster: "Fixture Roaster A",
                name: "Citrus Lot",
                origin: "Colombia",
                process: "Washed",
                descriptors: ["orange", "nectarine", "clean"]
            ),
            candidate(
                id: "fixture-ethiopia-natural",
                roaster: "Fixture Roaster B",
                name: "Berry Lot",
                origin: "Ethiopia",
                process: "Natural",
                descriptors: ["blueberry", "jasmine"]
            ),
            candidate(
                id: "fixture-unknown-experimental",
                roaster: "Fixture Roaster C",
                name: "Tropical Lot",
                origin: "Ecuador",
                process: "Experimental",
                descriptors: ["mango", "cardamom"]
            ),
        ])

        let byID = Dictionary(uniqueKeysWithValues: result.ranking.map { ($0.candidateID, $0) })
        XCTAssertEqual(byID["fixture-colombia-washed"]?.fit, 72.9)
        XCTAssertEqual(byID["fixture-colombia-washed"]?.novelty, 10.0)
        XCTAssertEqual(byID["fixture-ethiopia-natural"]?.fit, 67.1)
        XCTAssertEqual(byID["fixture-ethiopia-natural"]?.novelty, 10.0)
        XCTAssertEqual(byID["fixture-unknown-experimental"]?.fit, 75.2)
        XCTAssertEqual(byID["fixture-unknown-experimental"]?.novelty, 37.5)
        XCTAssertEqual(result.bestSupportedMatch.candidateID, "fixture-unknown-experimental")
        XCTAssertEqual(result.frontierPick?.candidateID, "fixture-colombia-washed")
    }

    func testScoringExcludesUnconfirmedAndMissingEvidenceInsteadOfUsingNeutralDefaults() throws {
        let scorer = try BeanExplorerScorer(profile: loadProfile())

        XCTAssertEqual(
            scorer.exclusionReason(candidate(id: "unconfirmed", isConfirmed: false)),
            "Confirm this candidate after reviewing the extracted fields."
        )
        XCTAssertEqual(
            scorer.exclusionReason(candidate(id: "missing-origin", origin: "")),
            "Origin is required."
        )
        XCTAssertEqual(
            scorer.exclusionReason(candidate(id: "unknown-note", descriptors: ["silky"])),
            "Add at least one seller flavor note recognized by the profile."
        )
    }

    func testFrontierIsNullWhenNoDistinctCandidateHasFamiliarBridge() throws {
        let scorer = try BeanExplorerScorer(profile: loadProfile())
        let result = try scorer.compare([
            candidate(id: "one", name: "Tea One", descriptors: ["black tea"]),
            candidate(id: "two", name: "Tea Two", origin: "Ecuador", process: "Experimental", descriptors: ["oolong"]),
        ])

        XCTAssertNil(result.frontierPick)
    }

    func testConfirmRejectsUncertaintyAndFieldEditResolvesOnlyChangedField() throws {
        var session = BeanExplorerSession()
        let candidate = try session.addManualCandidate(
            .init(
                roaster: "April",
                name: "Volcan Azul",
                origin: "Costa Rica",
                process: "Washed",
                flavorNotes: ["Nectarine"],
                uncertainFields: ["origin"]
            )
        )

        XCTAssertThrowsError(try session.confirmCandidate(id: candidate.id)) { error in
            XCTAssertEqual(
                error as? BeanExplorerSessionError,
                .unresolvedCandidateFields(["origin"])
            )
        }
        XCTAssertFalse(session.activeCandidates[0].isConfirmed)
        XCTAssertEqual(session.activeCandidates[0].draft.uncertainFields, ["origin"])

        var edited = session.activeCandidates[0].draft
        edited.origin = "Colombia"
        try session.updateCandidate(id: candidate.id, draft: edited)
        try session.confirmCandidate(id: candidate.id)
        XCTAssertTrue(session.activeCandidates[0].isConfirmed)
        XCTAssertTrue(session.activeCandidates[0].draft.uncertainFields.isEmpty)
        XCTAssertEqual(session.activeCandidates[0].fieldProvenance["origin"], .userEntered)
        XCTAssertTrue(session.activeCandidates[0].confirmedFields.contains("origin"))

        try session.updateCandidate(id: candidate.id, draft: session.activeCandidates[0].draft)
        XCTAssertFalse(session.activeCandidates[0].isConfirmed)
    }
    
    // MARK: - Normalize Contract Tests
    
    func testScorerUsesPreMatchedFamiliesWhenProvided() throws {
        let scorer = try BeanExplorerScorer(profile: loadProfile())
        
        // Without pre-matched families: uses lexicon matching
        let withoutPrematched = try scorer.compare([
            candidate(
                id: "test-lexicon",
                descriptors: ["orange", "nectarine"]
            )
        ])
        XCTAssertTrue(withoutPrematched.ranking[0].matchedFamilies.contains("Citrus"))
        XCTAssertTrue(withoutPrematched.ranking[0].matchedFamilies.contains("Stone fruit"))
        
        // With pre-matched families: bypasses lexicon, uses provided families
        let candidateWithPrematched = BeanExplorerScoreCandidate(
            id: "test-prematched",
            roaster: "Test Roaster",
            name: "Test Coffee",
            origin: "Colombia",
            process: "Washed",
            descriptors: ["浆果", "热带水果"],  // Chinese terms NOT in lexicon
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .userEntered,
                "name": .userEntered,
                "origin": .userEntered,
                "process": .userEntered,
                "flavor_notes": .userEntered,
            ],
            unresolvedFields: [],
            preMatchedFamilies: ["fruit.berry", "fruit.tropical"]
        )
        
        let withPrematched = try scorer.compare([candidateWithPrematched])
        XCTAssertTrue(withPrematched.ranking[0].matchedFamilies.contains("Berries"))
        XCTAssertTrue(withPrematched.ranking[0].matchedFamilies.contains("Tropical fruit"))
        XCTAssertEqual(withPrematched.ranking[0].matchedFamilies.count, 2)
    }
    
    func testExclusionChecksPreMatchedFamiliesOrLexicon() throws {
        let scorer = try BeanExplorerScorer(profile: loadProfile())
        
        // Without pre-matched: fails on unknown descriptor
        let unknown = candidate(id: "unknown", descriptors: ["unknown-flavor"])
        XCTAssertEqual(
            scorer.exclusionReason(unknown),
            "Add at least one seller flavor note recognized by the profile."
        )
        
        // With pre-matched families: passes even with unknown descriptor
        let candidateWithPrematched = BeanExplorerScoreCandidate(
            id: "prematched-unknown-descriptor",
            roaster: "Test",
            name: "Test",
            origin: "Colombia",
            process: "Washed",
            descriptors: ["未知风味"],  // Unknown Chinese term
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .userEntered,
                "name": .userEntered,
                "origin": .userEntered,
                "process": .userEntered,
                "flavor_notes": .userEntered,
            ],
            unresolvedFields: [],
            preMatchedFamilies: ["fruit.citrus"]
        )
        
        XCTAssertNil(scorer.exclusionReason(candidateWithPrematched))
        
        // With empty pre-matched families: fails
        let emptyPrematched = BeanExplorerScoreCandidate(
            id: "empty-prematched",
            roaster: "Test",
            name: "Test",
            origin: "Colombia",
            process: "Washed",
            descriptors: ["unknown"],
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .userEntered,
                "name": .userEntered,
                "origin": .userEntered,
                "process": .userEntered,
                "flavor_notes": .userEntered,
            ],
            unresolvedFields: [],
            preMatchedFamilies: []
        )
        
        XCTAssertEqual(
            scorer.exclusionReason(emptyPrematched),
            "Add at least one seller flavor note recognized by the profile."
        )
    }
    
    func testSEYAlignmentWithChineseDescriptors() throws {
        // This test validates the contract: Chinese descriptors normalized to same
        // families as English → same ranking and Novelty ~10 (not 42.5).
        let scorer = try BeanExplorerScorer(profile: loadProfile())
        
        // Mate Matiwos Keramo 74158 Honey: 浆果/热带水果/佛手柑 → berry/tropical/citrus
        let keramo = BeanExplorerScoreCandidate(
            id: "sey_keramo_ethiopia_honey",
            roaster: "SEY",
            name: "Mate Matiwos Keramo 74158 Honey",
            origin: "Ethiopia",
            process: "Honey",
            descriptors: ["浆果", "热带水果", "佛手柑"],
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .extracted,
                "name": .extracted,
                "origin": .extracted,
                "process": .extracted,
                "flavor_notes": .extracted,
            ],
            unresolvedFields: [],
            preMatchedFamilies: ["fruit.berry", "fruit.tropical", "fruit.citrus"]
        )
        
        // Alejandrina Maytan Kukipata SL9 Washed: 热带水果/草莓/柔和酸质 → tropical/berry
        let sl9 = BeanExplorerScoreCandidate(
            id: "sey_sl9_peru_washed",
            roaster: "SEY",
            name: "Alejandrina Maytan Kukipata SL9 Washed",
            origin: "Peru",
            process: "Washed",
            descriptors: ["热带水果", "草莓", "柔和酸质"],
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .extracted,
                "name": .extracted,
                "origin": .extracted,
                "process": .extracted,
                "flavor_notes": .extracted,
            ],
            unresolvedFields: [],
            preMatchedFamilies: ["fruit.tropical", "fruit.berry"]
        )
        
        // Susan Meneses Pink Bourbon Washed: 洛神花/蓝莓/手指柠檬 → floral/berry/citrus
        let susan = BeanExplorerScoreCandidate(
            id: "sey_susan_colombia_washed",
            roaster: "SEY",
            name: "Susan Meneses Pink Bourbon Washed",
            origin: "Colombia",
            process: "Washed",
            descriptors: ["洛神花", "蓝莓", "手指柠檬"],
            isConfirmed: true,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .extracted,
                "name": .extracted,
                "origin": .extracted,
                "process": .extracted,
                "flavor_notes": .extracted,
            ],
            unresolvedFields: [],
            preMatchedFamilies: ["floral", "fruit.berry", "fruit.citrus"]
        )
        
        let result = try scorer.compare([keramo, sl9, susan])
        let byID = Dictionary(uniqueKeysWithValues: result.ranking.map { ($0.candidateID, $0) })
        
        // Expected ranking with corrected bag notes: Keramo > SL9 > Susan (all in similar-fit band)
        XCTAssertEqual(result.ranking.map(\.candidateID), [
            "sey_keramo_ethiopia_honey",
            "sey_sl9_peru_washed",
            "sey_susan_colombia_washed"
        ])
        
        // Top-1 should be Keramo
        XCTAssertEqual(result.bestSupportedMatch.candidateID, "sey_keramo_ethiopia_honey")
        
        // Novelty should be ~10 for all (origin/process resolved, not 42.5)
        XCTAssertEqual(byID["sey_keramo_ethiopia_honey"]?.novelty, 10.0, accuracy: 0.1)
        XCTAssertEqual(byID["sey_sl9_peru_washed"]?.novelty, 10.0, accuracy: 0.1)
        XCTAssertEqual(byID["sey_susan_colombia_washed"]?.novelty, 10.0, accuracy: 0.1)
        
        // Fit scores should match gold (within 0.5 tolerance)
        XCTAssertEqual(byID["sey_keramo_ethiopia_honey"]?.fit, 69.3, accuracy: 0.5)
        XCTAssertEqual(byID["sey_sl9_peru_washed"]?.fit, 68.4, accuracy: 0.5)
        XCTAssertEqual(byID["sey_susan_colombia_washed"]?.fit, 67.9, accuracy: 0.5)
        
        // All three should be in similar-fit band (delta < 1.5)
        XCTAssertEqual(result.fitBands.count, 1)
        XCTAssertTrue(result.fitBands[0].isSimilarFit)
        XCTAssertEqual(result.fitBands[0].scores.count, 3)
    }

    private func candidate(
        id: String,
        roaster: String = "Fixture Roaster",
        name: String = "Fixture Coffee",
        origin: String = "Colombia",
        process: String = "Washed",
        descriptors: [String] = ["orange"],
        isConfirmed: Bool = true
    ) -> BeanExplorerScoreCandidate {
        .init(
            id: id,
            roaster: roaster,
            name: name,
            origin: origin,
            process: process,
            descriptors: descriptors,
            isConfirmed: isConfirmed,
            confirmedFields: ["roaster", "name", "origin", "process", "flavor_notes"],
            fieldProvenance: [
                "roaster": .userEntered,
                "name": .userEntered,
                "origin": .userEntered,
                "process": .userEntered,
                "flavor_notes": .userEntered,
            ]
        )
    }

    private func loadProfile() throws -> BeanExplorerProfile {
        let repository = repositoryURL
        let url = repository
            .appendingPathComponent("Sources/CoffeeJournalApp/Resources/TasteProfile/profile-prior.json")
        return try BeanExplorerProfile.decode(Data(contentsOf: url))
    }

    private func loadFixtures() throws -> FixtureDocument {
        let url = repositoryURL
            .appendingPathComponent("Sources/CoffeeJournalApp/Resources/TasteProfile/profile-parity-fixtures.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FixtureDocument.self, from: Data(contentsOf: url))
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeCandidate(_ fixture: FixtureCandidate) -> BeanExplorerScoreCandidate {
        BeanExplorerScoreCandidate(
            id: fixture.id,
            roaster: fixture.roaster,
            name: fixture.name,
            origin: fixture.origin,
            process: fixture.process,
            descriptors: fixture.descriptors,
            isConfirmed: fixture.isConfirmed,
            confirmedFields: Set(fixture.confirmedFields),
            fieldProvenance: fixture.fieldProvenance.compactMapValues(BeanExplorerFieldProvenance.init(rawValue:)),
            unresolvedFields: Set(fixture.unresolvedFields)
        )
    }
}

private struct FixtureDocument: Decodable {
    let scoreCases: [ScoreCase]
    let comparisonCases: [ComparisonCase]
    let eligibilityCases: [EligibilityCase]
    let normalizationCases: [TextCase]
    let roundingCases: [NumberCase]
    let bandCases: [BandCase]
    let bridgeBoundaryCases: [BridgeBoundaryCase]
    let roleCases: [RoleCase]
}

private struct FixtureCandidate: Decodable {
    let id: String
    let roaster: String
    let name: String
    let origin: String
    let process: String
    let descriptors: [String]
    let isConfirmed: Bool
    let confirmedFields: [String]
    let fieldProvenance: [String: String]
    let unresolvedFields: [String]
}

private struct ScoreCase: Decodable {
    let candidate: FixtureCandidate
    let expected: ExpectedScore
}

private struct ExpectedScore: Decodable {
    let fitScore: Double
    let noveltyScore: Double
}

private struct ComparisonCase: Decodable {
    let candidates: [FixtureCandidate]
    let expectedRanking: [String]
    let expectedBest: String
    let expectedFrontier: String?
    let expectedBands: [[String]]
    let expectedBridges: [String: [ExpectedBridge]]
}

private struct ExpectedBridge: Codable, Equatable {
    let category: String
    let topTierCount: Int
    let observations: Int
}

private struct EligibilityCase: Decodable {
    let candidate: FixtureCandidate
    let expectedReason: String?
}

private struct TextCase: Decodable {
    let input: String
    let expected: String
}

private struct NumberCase: Decodable {
    let input: Double
    let expected: Double
}

private struct BandCase: Decodable {
    let fits: [Double]
    let expected: [[String]]
}

private struct BridgeBoundaryCase: Decodable {
    let topTierCount: Int
    let observations: Int
    let expected: Bool
}

private struct RoleCase: Decodable {
    let rows: [RoleRow]
    let expectedRanking: [String]
    let expectedBest: String
    let expectedFrontier: String?
    let expectedBands: [[String]]
}

private struct RoleRow: Decodable {
    let candidateId: String
    let profileFitScore: Double
    let profileNoveltyScore: Double
    let familiarBridges: [[String: String]]

}
