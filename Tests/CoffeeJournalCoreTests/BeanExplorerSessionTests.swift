import CryptoKit
import Foundation
import XCTest
@testable import CoffeeJournalCore

final class BeanExplorerSessionTests: XCTestCase {
    func testExtractionContractBindsParserSource() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Sources/CoffeeJournalCore/BeanExplorerExtraction.swift"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(digest, BeanExplorerExtractionContract.approvedParserSourceSHA256)
    }

    func testMismatchedPromptLineageStillBeginsExtraction() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()

        let request = try session.beginExtraction(sourceID: source.id, promptContractHash: "unapproved")
        XCTAssertEqual(request.promptContractHash, "unapproved")
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .uploading)
        XCTAssertTrue(session.activeCandidates.isEmpty)
    }

    func testMismatchedPromptLineageStillCommitsExtraction() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let request = try session.beginExtraction(
            sourceID: source.id,
            promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256
        )
        let mismatchedRequest = BeanExplorerExtractionRequest(
            sourceID: request.sourceID,
            sourceRevision: request.sourceRevision,
            requestRevision: request.requestRevision,
            promptContractHash: "unapproved"
        )

        try session.commitExtraction(
            request: mismatchedRequest,
            drafts: [.init(roaster: "Injected", name: "Recommendation")],
            rejectedCount: 0
        )

        XCTAssertEqual(session.activeCandidates.count, 1)
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .succeeded(validCount: 1))
    }

    func testExtractionParserReturnsMultipleTemporaryCandidates() throws {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [
            {
              "package_index": 1,
              "bounding_box": [0.1, 0.1, 0.8, 0.45],
              "coffee": {
                "roaster": "April",
                "name": "Volcan Azul",
                "origin": "Costa Rica",
                "farm": "Volcan Azul",
                "variety": "SL28",
                "process": "Washed",
                "flavor_notes": ["Nectarine"]
              },
              "evidence": {
                "roaster": "April",
                "name": "Volcan Azul",
                "origin": "Costa Rica",
                "farm": "Volcan Azul",
                "variety": "SL28",
                "process": "Washed"
              },
              "uncertain_fields": []
            },
            {
              "package_index": 2,
              "bounding_box": [0.1, 0.55, 0.8, 0.9],
              "coffee": {
                "roaster": "Manhattan",
                "name": "Diego Bermudez",
                "origin": "Colombia",
                "farm": null,
                "variety": null,
                "process": "Washed",
                "flavor_notes": []
              },
              "evidence": {
                "roaster": "Manhattan",
                "name": "Diego Bermudez",
                "origin": "Colombia",
                "farm": null,
                "variety": null,
                "process": "Washed"
              },
              "uncertain_fields": []
            }
          ],
          "rejected_regions": []
        }
        """

        let result = try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].roaster, "April")
        XCTAssertEqual(result.candidates[0].flavorNotes, ["Nectarine"])
        XCTAssertEqual(result.candidates[1].name, "Diego Bermudez")
        XCTAssertEqual(result.rejectedCount, 0)
    }

    func testExtractionParserKeepsValidPackagesAndCountsInvalidOnes() throws {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [
            {
              "package_index": 1,
              "bounding_box": null,
              "coffee": {
                "roaster": "April",
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null,
                "flavor_notes": []
              },
              "evidence": {
                "roaster": "APRIL",
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null
              },
              "uncertain_fields": []
            },
            {
              "package_index": 2,
              "bounding_box": null,
              "coffee": {
                "roaster": null,
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null,
                "flavor_notes": []
              },
              "evidence": {
                "roaster": null,
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null
              },
              "uncertain_fields": []
            }
          ],
          "rejected_regions": [{"bounding_box": null, "reason": "too_unclear"}]
        }
        """

        let result = try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)

        XCTAssertEqual(result.candidates.map(\.roaster), ["April"])
        XCTAssertEqual(result.rejectedCount, 2)
    }

    func testExtractionParserRejectsUnsupportedUncertaintyAndMissingEvidence() throws {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [
            {
              "package_index": 1,
              "bounding_box": null,
              "coffee": {
                "roaster": "April",
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null,
                "flavor_notes": []
              },
              "evidence": {
                "roaster": null,
                "name": null,
                "origin": null,
                "farm": null,
                "variety": null,
                "process": null
              },
              "uncertain_fields": ["price"]
            }
          ],
          "rejected_regions": []
        }
        """

        let result = try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.rejectedCount, 1)
    }

    func testManualCandidateGetsDeterministicSessionIdentity() throws {
        var session = BeanExplorerSession()

        let first = try session.addManualCandidate(.init(roaster: "April", name: "Volcan Azul"))
        let second = try session.addManualCandidate(.init(roaster: "Manhattan", name: "Diego Bermudez"))

        XCTAssertEqual(first.id, "candidate-001")
        XCTAssertEqual(first.rankOrdinal, 1)
        XCTAssertEqual(second.id, "candidate-002")
        XCTAssertEqual(second.rankOrdinal, 2)
        XCTAssertEqual(session.activeCandidates.count, 2)
        XCTAssertEqual(session.activeImageSourceCount, 0)
    }

    func testCandidateLimitRejectsOverflowWithoutCreatingSource() throws {
        var session = BeanExplorerSession()
        let limit = BeanExplorerSession.maximumCandidates
        for index in 1...limit {
            _ = try session.addManualCandidate(.init(roaster: "Roaster \(index)"))
        }

        XCTAssertThrowsError(try session.addManualCandidate(.init(roaster: "Overflow"))) { error in
            XCTAssertEqual(error as? BeanExplorerSessionError, .candidateLimitReached)
        }
        XCTAssertEqual(session.activeCandidates.count, limit)
        XCTAssertEqual(session.sources.count, limit)
    }

    func testCancellingUploadKeepsImageSlotUntilSourceIsRemoved() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        try session.markUploading(sourceID: source.id)

        try session.cancelRequest(sourceID: source.id)

        XCTAssertEqual(session.activeImageSourceCount, 1)
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .cancelled)

        try session.removeSource(sourceID: source.id)

        XCTAssertEqual(session.activeImageSourceCount, 0)
        XCTAssertNil(session.activeSource(id: source.id))
        XCTAssertTrue(session.activeSources.isEmpty)
    }

    func testImageSourceLimitCountsOnlyActiveImages() throws {
        var session = BeanExplorerSession()
        var sources: [BeanExplorerSource] = []
        let limit = BeanExplorerSession.maximumImageSources
        for _ in 1...limit {
            sources.append(try session.addImageSource())
        }

        XCTAssertThrowsError(try session.addImageSource()) { error in
            XCTAssertEqual(error as? BeanExplorerSessionError, .imageSourceLimitReached)
        }

        try session.removeSource(sourceID: sources[0].id)
        _ = try session.addImageSource()
        XCTAssertEqual(session.activeImageSourceCount, limit)
    }

    func testRemovingManualSourceFreesCandidateSlotWithoutReusingIdentity() throws {
        var session = BeanExplorerSession()
        var candidates: [BeanExplorerCandidate] = []
        let limit = BeanExplorerSession.maximumCandidates
        for index in 1...limit {
            candidates.append(try session.addManualCandidate(.init(roaster: "Roaster \(index)")))
        }

        try session.removeSource(sourceID: candidates[0].sourceID)
        let replacement = try session.addManualCandidate(.init(roaster: "Replacement"))

        XCTAssertEqual(session.activeCandidates.count, limit)
        let expectedOrdinal = limit + 1
        XCTAssertEqual(replacement.id, String(format: "candidate-%03d", expectedOrdinal))
        XCTAssertEqual(replacement.rankOrdinal, expectedOrdinal)
    }

    func testStaleExtractionCannotCommitCandidates() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let staleRequest = try session.beginExtraction(sourceID: source.id, promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256)
        let currentRequest = try session.beginExtraction(sourceID: source.id, promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256)

        XCTAssertThrowsError(
            try session.commitExtraction(
                request: staleRequest,
                drafts: [.init(roaster: "Stale", name: "Result")],
                rejectedCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? BeanExplorerSessionError, .staleExtractionRequest)
        }
        try session.commitExtraction(
            request: currentRequest,
            drafts: [
                .init(roaster: "April", name: "Volcan Azul"),
                .init(roaster: "Manhattan", name: "Diego Bermudez")
            ],
            rejectedCount: 1
        )
        XCTAssertEqual(session.activeCandidates.map(\.id), ["candidate-001", "candidate-002"])
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .partialSuccess(validCount: 2, rejectedCount: 1))
    }

    func testCancelledExtractionCannotCommitCandidates() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let request = try session.beginExtraction(sourceID: source.id, promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256)

        try session.cancelRequest(sourceID: source.id)
        XCTAssertThrowsError(
            try session.commitExtraction(
                request: request,
                drafts: [.init(roaster: "Late response")],
                rejectedCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? BeanExplorerSessionError, .staleExtractionRequest)
        }
        XCTAssertTrue(session.activeCandidates.isEmpty)
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .cancelled)
    }

    func testFailedExtractionCannotCommitLateCandidates() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let request = try session.beginExtraction(sourceID: source.id, promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256)

        XCTAssertTrue(session.failExtraction(request: request))
        XCTAssertThrowsError(
            try session.commitExtraction(
                request: request,
                drafts: [.init(roaster: "Late response")],
                rejectedCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? BeanExplorerSessionError, .staleExtractionRequest)
        }
        XCTAssertEqual(session.activeSource(id: source.id)?.requestState, .failed)
    }

    func testUserCanEditTemporaryCandidate() throws {
        var session = BeanExplorerSession()
        let candidate = try session.addManualCandidate(.init(roaster: "Aprl", name: "Volcan"))

        try session.updateCandidate(
            id: candidate.id,
            draft: .init(roaster: "April", name: "Volcan Azul", origin: "Costa Rica")
        )
        XCTAssertEqual(session.activeCandidates.first?.draft.roaster, "April")
        XCTAssertEqual(session.activeCandidates.first?.draft.origin, "Costa Rica")
    }

    func testRemovingOneExtractedCandidateKeepsItsSourceAndSiblings() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let request = try session.beginExtraction(sourceID: source.id, promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256)
        try session.commitExtraction(
            request: request,
            drafts: [.init(roaster: "April"), .init(roaster: "Manhattan")],
            rejectedCount: 0
        )

        try session.removeCandidate(id: "candidate-001")

        XCTAssertEqual(session.activeCandidates.map(\.draft.roaster), ["Manhattan"])
        XCTAssertNotNil(session.activeSource(id: source.id))
    }

    func testExtractionParserRejectsDuplicatePackageIndexesAsInvalidEnvelope() {
        let package = """
        {
          "package_index": 1,
          "bounding_box": null,
          "coffee": {
            "roaster": "April", "name": null, "origin": null, "farm": null,
            "variety": null, "process": null, "flavor_notes": []
          },
          "evidence": {
            "roaster": "April", "name": null, "origin": null, "farm": null,
            "variety": null, "process": null
          },
          "uncertain_fields": []
        }
        """
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [\(package), \(package)],
          "rejected_regions": []
        }
        """

        XCTAssertThrowsError(try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)) { error in
            XCTAssertEqual(error as? BeanExplorerExtractionError, .invalidEnvelope)
        }
    }

    func testExtractionParserRejectsUnknownEnvelopeFields() {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [],
          "rejected_regions": [],
          "recommendation": "Buy the first one"
        }
        """

        XCTAssertThrowsError(try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)) { error in
            XCTAssertEqual(error as? BeanExplorerExtractionError, .invalidEnvelope)
        }
    }

    func testExtractionParserRejectsUnknownNestedCoffeeFields() {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [{
            "package_index": 1,
            "bounding_box": null,
            "coffee": {
              "roaster": "April", "name": null, "origin": null, "farm": null,
              "variety": null, "process": null, "flavor_notes": [],
              "recommendation": "buy"
            },
            "evidence": {
              "roaster": "April", "name": null, "origin": null, "farm": null,
              "variety": null, "process": null
            },
            "uncertain_fields": []
          }],
          "rejected_regions": []
        }
        """

        XCTAssertThrowsError(try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)) { error in
            XCTAssertEqual(error as? BeanExplorerExtractionError, .invalidEnvelope)
        }
    }

    func testExtractionParserRejectsUnknownRejectedRegionReason() {
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [],
          "rejected_regions": [{"bounding_box": null, "reason": "buy_this_one"}]
        }
        """

        XCTAssertThrowsError(try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)) { error in
            XCTAssertEqual(error as? BeanExplorerExtractionError, .invalidEnvelope)
        }
    }

    func testExtractionParserCapsValuesAtUnicodeScalarBoundary() throws {
        let longValue = String(repeating: "e\u{301}", count: 80) + "x"
        let json = """
        {
          "schema_version": "bean-explorer-extraction-v2",
          "packages": [{
            "package_index": 1,
            "bounding_box": null,
            "coffee": {
              "roaster": "\(longValue)", "name": null, "origin": null, "farm": null,
              "variety": null, "process": null, "flavor_notes": []
            },
            "evidence": {
              "roaster": "\(longValue)", "name": null, "origin": null, "farm": null,
              "variety": null, "process": null
            },
            "uncertain_fields": []
          }],
          "rejected_regions": []
        }
        """

        let result = try BeanExplorerExtractionParser().parse(json, remainingCapacity: 8)

        XCTAssertEqual(result.candidates[0].roaster.unicodeScalars.count, 160)
        XCTAssertFalse(result.candidates[0].roaster.hasSuffix("x"))
    }

    func testExtractionParserFailsClosedForSyntacticallyInvalidAndEmptyJSON() {
        for value in ["", "{not-json", "[]"] {
            XCTAssertThrowsError(try BeanExplorerExtractionParser().parse(value, remainingCapacity: 8)) { error in
                XCTAssertEqual(error as? BeanExplorerExtractionError, .invalidEnvelope)
            }
        }
    }
}
