import XCTest
@testable import CoffeeJournalCore

final class BeanExplorerSessionPersistenceTests: XCTestCase {
    func testSessionCodableRoundTripPreservesCandidates() throws {
        var session = BeanExplorerSession()
        let source = try session.addImageSource()
        let request = try session.beginExtraction(
            sourceID: source.id,
            promptContractHash: BeanExplorerExtractionContract.approvedPromptSHA256
        )
        let draft = BeanExplorerCandidateDraft(
            roaster: "SEY COFFEE",
            name: "Mate Matiwos Keramo",
            origin: "Ethiopia",
            process: "Washed",
            flavorNotes: ["Citrus"],
            evidence: [
                "roaster": "SEY COFFEE",
                "name": "Mate Matiwos Keramo",
                "origin": "Ethiopia",
                "process": "Washed",
                "flavor_note_0": "Citrus"
            ]
        )
        XCTAssertTrue(try session.commitExtraction(request: request, drafts: [draft], rejectedCount: 0))
        try session.confirmCandidate(id: session.activeCandidates[0].id)

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(BeanExplorerSession.self, from: data)

        XCTAssertEqual(decoded.activeSources.count, 1)
        XCTAssertEqual(decoded.activeCandidates.count, 1)
        XCTAssertEqual(decoded.activeCandidates[0].draft.roaster, "SEY COFFEE")
        XCTAssertTrue(decoded.activeCandidates[0].isConfirmed)
    }

    func testClearEmptiesSession() throws {
        var session = BeanExplorerSession()
        _ = try session.addImageSource()
        session.clear()
        XCTAssertTrue(session.activeSources.isEmpty)
        XCTAssertTrue(session.activeCandidates.isEmpty)
    }
}
