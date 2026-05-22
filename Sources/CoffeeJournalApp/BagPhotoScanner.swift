import CoffeeJournalCore
import Foundation

#if canImport(UIKit)
import UIKit

struct BagPhotoScanResult: Equatable {
    var draft: BagScanDraft
    var recognizedText: String
    var filledFields: [String]
    var evidence: [String: String]
    var confidence: [String: Double]

    var hasRecognizedText: Bool {
        !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !filledFields.isEmpty
    }
}

enum BagPhotoScannerError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case requestFailed(String)
    case invalidResponse
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Ark API key is not configured. Run once from Xcode with ARK_API_KEY in the Debug environment to seed Keychain."
        case .invalidImage:
            return "The selected image could not be compressed for scanning."
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Ark returned an unreadable response."
        case .invalidJSON(let message):
            return "Ark extraction JSON could not be parsed: \(message)"
        }
    }
}

struct BagPhotoScanner {
    func scan(imageData: Data) async throws -> BagPhotoScanResult {
        let credentials = try ArkCredentials.load()
        let jpegData = try compressedJPEGData(from: imageData)
        let payload = ArkResponsesPayload(
            model: credentials.model,
            input: [
                .init(
                    role: "user",
                    content: [
                        .init(type: "input_image", imageURL: dataURL(from: jpegData), detail: "low", text: nil),
                        .init(type: "input_text", imageURL: nil, detail: nil, text: "\(Self.systemPrompt)\n\n\(Self.userPrompt)")
                    ]
                )
            ],
            temperature: 0,
            maxOutputTokens: 1500
        )

        var request = URLRequest(url: credentials.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BagPhotoScannerError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw BagPhotoScannerError.requestFailed("Ark request failed with HTTP \(httpResponse.statusCode): \(body)")
        }

        let arkResponse: ArkResponsesResponse
        do {
            arkResponse = try JSONDecoder().decode(ArkResponsesResponse.self, from: data)
        } catch {
            throw BagPhotoScannerError.invalidJSON("Ark response envelope could not be parsed: \(error.localizedDescription)")
        }
        let content = try arkResponse.extractedText()
        let extraction = try decodeExtraction(from: content)
        return extraction.scanResult()
    }
}

private extension BagPhotoScanner {
    static let systemPrompt = """
    You extract Add Bean draft information from coffee bag photos for a private coffee journal.
    Return only valid JSON. Do not wrap it in Markdown.
    Extract only information that is visible on the package.
    Use null when a value is missing, ambiguous, too long, or not confidently readable.
    Do not infer roast date, process, total grams, name, or farm from unrelated text.
    Preserve roaster, variety, process, and flavor note spelling from the image.
    If multiple photos are provided, combine evidence from all of them.
    """

    static let userPrompt = """
    Return only this JSON schema:
    {
      "coffee": {
        "roaster": string|null,
        "name": string|null,
        "origin": string|null,
        "farm": string|null,
        "variety": string|null,
        "process": string|null,
        "flavor_notes": [string]
      },
      "bag": {
        "roast_date": "YYYY-MM-DD"|null,
        "total_grams": number|null
      }
    }

    Rules:
    - Extract only visible package text. Use null for missing, ambiguous, or unreadable values.
    - Origin must be country-level only, such as Peru, Costa Rica, Panama, or Colombia.
    - Roaster is the company/brand that roasted or sold the beans.
    - Name is optional: return only a clear short product or lot name, usually 1-3 words; otherwise null.
    - Farm is optional: return only clearly visible farm, finca, estate, producer, or producer-family text.
    - Do not infer roast date, total grams, process, name, or farm.
    - Preserve flavor note wording from the package.
    """
}

private struct ArkCredentials {
    var apiKey: String
    var model: String
    var baseURL: URL

    private static let defaultModel = "ep-20260516191128-js45j"
    private static let defaultBaseURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3")!

    static func load() throws -> ArkCredentials {
        ArkKeychain.seedFromDebugEnvironment()

        guard let apiKey = ArkKeychain.read("ARK_API_KEY"), !apiKey.isEmpty else {
            throw BagPhotoScannerError.missingAPIKey
        }

        let model = ArkKeychain.read("ARK_MODEL").flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let baseURLString = ArkKeychain.read("ARK_BASE_URL").flatMap { $0.isEmpty ? nil : $0 }
        let baseURL = baseURLString.flatMap(URL.init(string:)) ?? defaultBaseURL
        return ArkCredentials(apiKey: apiKey, model: model, baseURL: baseURL)
    }
}

private struct ArkResponsesPayload: Encodable {
    var model: String
    var input: [Input]
    var temperature: Double
    var maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }

    struct Input: Encodable {
        var role: String
        var content: [Content]
    }

    struct Content: Encodable {
        var type: String
        var imageURL: String?
        var detail: String?
        var text: String?

        enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
            case detail
            case text
        }
    }
}

private struct ArkResponsesResponse: Decodable {
    var outputText: String?
    var output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    func extractedText() throws -> String {
        if let outputText, !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        let texts = output?
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []

        guard !texts.isEmpty else {
            throw BagPhotoScannerError.invalidResponse
        }
        return texts.joined(separator: "\n")
    }

    struct OutputItem: Decodable {
        var content: [Content]?
    }

    struct Content: Decodable {
        var text: String?
    }
}

private struct ArkBagExtraction: Decodable {
    var coffee: CoffeeFields?
    var bag: BagFields?
    var evidence: [String: String?]?
    var confidence: [String: Double]?

    struct CoffeeFields: Decodable {
        var roaster: String?
        var name: String?
        var origin: String?
        var farm: String?
        var variety: String?
        var process: String?
        var flavorNotes: [String]?
        var notes: String?

        enum CodingKeys: String, CodingKey {
            case roaster
            case name
            case origin
            case farm
            case variety
            case process
            case flavorNotes = "flavor_notes"
            case notes
        }
    }

    struct BagFields: Decodable {
        var roastDate: String?
        var totalGrams: Double?

        enum CodingKeys: String, CodingKey {
            case roastDate = "roast_date"
            case totalGrams = "total_grams"
        }
    }

    func scanResult() -> BagPhotoScanResult {
        var draft = MockBagScanner().manualFallbackDraft()
        var filledFields: [String] = []

        if let value = clean(coffee?.roaster) {
            draft.coffee.roaster = value
            filledFields.append("roaster")
        }
        if let value = clean(coffee?.name) {
            draft.coffee.name = value
            filledFields.append("name")
        }
        if let value = clean(coffee?.origin) {
            draft.coffee.origin = value
            filledFields.append("origin")
        }
        if let value = clean(coffee?.farm) {
            draft.coffee.farm = value
            filledFields.append("farm")
        }
        if let value = clean(coffee?.variety) {
            draft.coffee.variety = value
            filledFields.append("variety")
        }
        if let value = clean(coffee?.process) {
            draft.coffee.process = value
            filledFields.append("process")
        }

        let notes = (coffee?.flavorNotes ?? []).compactMap(clean)
        if !notes.isEmpty {
            draft.coffee.flavorNotes = notes
            filledFields.append("flavor notes")
        }

        if let date = parseDate(bag?.roastDate) {
            draft.roastDate = date
            filledFields.append("roast date")
        } else {
            draft.roastDate = nil
        }

        if let totalGrams = bag?.totalGrams {
            draft.totalGrams = totalGrams
            filledFields.append("total grams")
        } else {
            draft.totalGrams = nil
        }

        let normalizedEvidence = (evidence ?? [:]).compactMapValues { clean($0) }
        let evidenceText = normalizedEvidence
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        draft.coffee.notes = evidenceText.isEmpty ? "" : "AI extraction evidence:\n\(evidenceText)"

        return BagPhotoScanResult(
            draft: draft,
            recognizedText: evidenceText,
            filledFields: unique(filledFields),
            evidence: normalizedEvidence,
            confidence: confidence ?? [:]
        )
    }
}

private func compressedJPEGData(from imageData: Data) throws -> Data {
    guard let image = UIImage(data: imageData) else {
        throw BagPhotoScannerError.invalidImage
    }

    let maxSide: CGFloat = 1800
    let sourceSize = image.size
    let ratio = min(1, maxSide / max(sourceSize.width, sourceSize.height))
    let targetSize = CGSize(width: sourceSize.width * ratio, height: sourceSize.height * ratio)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let normalizedImage = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: targetSize))
    }

    guard let data = normalizedImage.jpegData(compressionQuality: 0.8) else {
        throw BagPhotoScannerError.invalidImage
    }
    return data
}

private func dataURL(from data: Data) -> String {
    "data:image/jpeg;base64,\(data.base64EncodedString())"
}

private func decodeExtraction(from content: String) throws -> ArkBagExtraction {
    let jsonText = extractJSONObjectText(from: content)
    guard let data = jsonText.data(using: .utf8) else {
        throw BagPhotoScannerError.invalidJSON("response was not UTF-8")
    }

    do {
        return try JSONDecoder().decode(ArkBagExtraction.self, from: data)
    } catch {
        throw BagPhotoScannerError.invalidJSON(error.localizedDescription)
    }
}

private func extractJSONObjectText(from content: String) -> String {
    var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("```") {
        text = text.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
        return text
    }
    return String(text[start...end])
}

private func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.lowercased() != "null" else { return nil }
    return cleaned
}

private func parseDate(_ value: String?) -> Date? {
    guard let value = clean(value) else { return nil }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
#endif
