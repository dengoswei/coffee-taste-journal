import Foundation
import UIKit
import XCTest
import CoffeeJournalCore
@testable import Coffee_Journal

@MainActor
final class BagPhotoScannerTests: XCTestCase {
    func testExplorerPromptMatchesIndependentlyApprovedContractHash() {
        XCTAssertEqual(
            BeanExplorerPhotoScanner.promptContractHash,
            BeanExplorerExtractionContract.approvedPromptSHA256
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testAddBeanScannerUsesSharedSystemRequestAndParsesLegacyDraft() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v3/responses")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

            let body = try requestBody(request)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try XCTUnwrap(root["input"] as? [[String: Any]])
            XCTAssertEqual(input.count, 2)
            XCTAssertEqual(input[0]["role"] as? String, "system")
            XCTAssertEqual(input[1]["role"] as? String, "user")

            let extraction: [String: Any] = [
                "coffee": [
                    "roaster": "April",
                    "name": "Volcan Azul",
                    "origin": "Costa Rica",
                    "farm": NSNull(),
                    "variety": "SL28",
                    "process": "Washed",
                    "flavor_notes": ["Nectarine"],
                ],
                "bag": ["roast_date": NSNull(), "total_grams": 250],
            ]
            let extractionData = try JSONSerialization.data(withJSONObject: extraction)
            let extractionText = try XCTUnwrap(String(data: extractionData, encoding: .utf8))
            let responseData = try JSONSerialization.data(withJSONObject: ["output_text": extractionText])
            return (HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!, responseData)
        }

        let result = try await makeScanner().scan(imageData: makeJPEG())

        XCTAssertEqual(result.draft.coffee.roaster, "April")
        XCTAssertEqual(result.draft.coffee.name, "Volcan Azul")
        XCTAssertEqual(result.draft.coffee.flavorNotes, ["Nectarine"])
        XCTAssertEqual(result.draft.totalGrams, 250)
    }

    func testAddBeanScannerDoesNotExposeArkResponseBodyInHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("private-response-body".utf8))
        }

        do {
            _ = try await makeScanner().scan(imageData: makeJPEG())
            XCTFail("Expected an HTTP error")
        } catch let error as BagPhotoScannerError {
            XCTAssertEqual(error.errorDescription, "Ark request failed with HTTP 500.")
            XCTAssertFalse(error.localizedDescription.contains("private-response-body"))
        }
    }

    private func makeScanner() -> BagPhotoScanner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ArkResponsesClient(
            session: session,
            credentialsLoader: {
                ArkCredentials(
                    apiKey: "test-key",
                    model: "test-model",
                    baseURL: URL(string: "https://example.test/api/v3")!
                )
            }
        )
        return BagPhotoScanner(client: client)
    }

    private func makeJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 1))
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}
