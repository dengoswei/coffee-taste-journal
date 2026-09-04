import CoffeeJournalCore
import Foundation

#if canImport(UIKit)

/// Normalized coffee descriptor output from text-only Ark normalization.
/// Maps free-text flavor notes, origin, and process to canonical profile keys.
public struct CoffeeDescriptorNormalized: Codable, Equatable, Sendable {
    /// Matched flavor family IDs from the profile lexicon.
    /// Must be subset of profile category keys (e.g. "fruit.berry", "fruit.citrus", etc.)
    public let flavorFamilies: [String]
    
    /// Canonical origin matching profile origin_stats keys.
    /// Must match case-normalized keys like "Ethiopia", "Colombia", "Peru".
    public let origin: String?
    
    /// Canonical process matching profile process_stats keys.
    /// Must match case-normalized keys like "Washed", "Honey", "Natural".
    public let process: String?
    
    /// Original descriptor terms kept for display purposes.
    /// These are the raw seller notes, preserved for UI rendering.
    public let descriptorTermsKeptForDisplay: [String]
    
    enum CodingKeys: String, CodingKey {
        case flavorFamilies = "flavor_families"
        case origin
        case process
        case descriptorTermsKeptForDisplay = "descriptor_terms_kept_for_display"
    }
    
    public init(
        flavorFamilies: [String],
        origin: String?,
        process: String?,
        descriptorTermsKeptForDisplay: [String]
    ) {
        self.flavorFamilies = flavorFamilies
        self.origin = origin
        self.process = process
        self.descriptorTermsKeptForDisplay = descriptorTermsKeptForDisplay
    }
}

enum CoffeeDescriptorNormalizerError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case invalidJSON(String)
    case unknownFamily([String])
    case invalidOriginOrProcess(origin: String?, process: String?)
    case retryLimitExceeded
    case requestFailed(statusCode: Int)
    
    var errorDescription: String? {
        switch self:
        case .missingAPIKey:
            return "Ark API key is not configured."
        case .invalidResponse:
            return "Ark returned an unreadable response."
        case .invalidJSON(let detail):
            return "Normalize JSON could not be parsed: \(detail)"
        case .unknownFamily(let families):
            return "Unknown flavor families returned: \(families.joined(separator: ", "))"
        case .invalidOriginOrProcess(let origin, let process):
            return "Origin or process not in allowed set: origin=\(origin ?? "nil"), process=\(process ?? "nil")"
        case .retryLimitExceeded:
            return "Normalize retry limit exceeded after multiple invalid responses."
        case .requestFailed(let statusCode):
            return "Ark request failed with HTTP \(statusCode)."
        }
    }
}

struct CoffeeDescriptorNormalizer: Sendable {
    private let client: ArkResponsesClient
    private let profile: BeanExplorerProfile
    private let maxRetries: Int
    
    init(
        client: ArkResponsesClient = ArkResponsesClient(),
        profile: BeanExplorerProfile,
        maxRetries: Int = 3
    ) {
        self.client = client
        self.profile = profile
        self.maxRetries = maxRetries
    }
    
    /// Normalize raw coffee descriptors to canonical profile keys.
    func normalize(
        descriptors: [String],
        origin: String,
        process: String
    ) async throws -> CoffeeDescriptorNormalized {
        var attempt = 0
        var lastError: Error?
        
        while attempt < maxRetries {
            do {
                let result = try await attemptNormalize(
                    descriptors: descriptors,
                    origin: origin,
                    process: process,
                    retryContext: attempt > 0 ? buildRetryContext(lastError: lastError) : nil
                )
                try validate(result)
                return result
            } catch {
                lastError = error
                attempt += 1
                
                if !shouldRetry(error: error) {
                    throw error
                }
            }
        }
        
        throw CoffeeDescriptorNormalizerError.retryLimitExceeded
    }
    
    private func attemptNormalize(
        descriptors: [String],
        origin: String,
        process: String,
        retryContext: String?
    ) async throws -> CoffeeDescriptorNormalized {
        let userPrompt = buildUserPrompt(
            descriptors: descriptors,
            origin: origin,
            process: process,
            retryContext: retryContext
        )
        
        let content = try await client.extract(
            imageData: Data(), // Empty for text-only
            systemPrompt: Self.systemPrompt(profile: profile),
            userPrompt: userPrompt,
            maxOutputTokens: 800
        )
        
        return try decodeNormalized(from: content)
    }
    
    private func buildUserPrompt(
        descriptors: [String],
        origin: String,
        process: String,
        retryContext: String?
    ) -> String {
        var prompt = """
        Normalize these coffee descriptors to canonical profile keys:
        
        Flavor notes: \(descriptors.joined(separator: ", "))
        Origin: \(origin)
        Process: \(process)
        
        Return ONLY this JSON shape (no markdown, no explanation):
        {
          "flavor_families": [<family_id>, ...],
          "origin": "<canonical_origin>" | null,
          "process": "<canonical_process>" | null,
          "descriptor_terms_kept_for_display": [<original_term>, ...]
        }
        """
        
        if let retryContext {
            prompt += "\n\n" + retryContext
        }
        
        return prompt
    }
    
    private func buildRetryContext(lastError: Error?) -> String {
        guard let error = lastError else {
            return "Previous attempt failed. Please ensure output is valid JSON with only allowed family IDs and canonical origin/process keys."
        }
        
        if case CoffeeDescriptorNormalizerError.unknownFamily(let families) = error {
            return "CORRECTION REQUIRED: These family IDs are not allowed: \(families.joined(separator: ", ")). Use only the family IDs from the allowed list in the system prompt."
        }
        
        if case CoffeeDescriptorNormalizerError.invalidOriginOrProcess(let origin, let process) = error {
            return "CORRECTION REQUIRED: Origin '\(origin ?? "")' or process '\(process ?? "")' not in allowed set. Use only the exact canonical keys from the system prompt lists."
        }
        
        if case CoffeeDescriptorNormalizerError.invalidJSON(let detail) = error {
            return "CORRECTION REQUIRED: JSON was invalid (\(detail)). Return valid JSON matching the exact shape specified."
        }
        
        return "Previous attempt failed. Please ensure output is valid JSON with only allowed keys."
    }
    
    private func decodeNormalized(from content: String) throws -> CoffeeDescriptorNormalized {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip markdown code fences if present
        let jsonText: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let codeLines = lines.dropFirst().drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let endIndex = codeLines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "```" }) ?? codeLines.endIndex
            jsonText = codeLines.prefix(upTo: endIndex).joined(separator: "\n")
        } else {
            jsonText = trimmed
        }
        
        guard let data = jsonText.data(using: .utf8) else {
            throw CoffeeDescriptorNormalizerError.invalidJSON("Could not encode as UTF-8")
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CoffeeDescriptorNormalized.self, from: data)
        } catch {
            throw CoffeeDescriptorNormalizerError.invalidJSON(error.localizedDescription)
        }
    }
    
    private func validate(_ result: CoffeeDescriptorNormalized) throws {
        // Check families are in allowed set
        let allowedFamilies = Set(profile.lexicon.categoryTerms.keys)
        let unknownFamilies = result.flavorFamilies.filter { !allowedFamilies.contains($0) }
        guard unknownFamilies.isEmpty else {
            throw CoffeeDescriptorNormalizerError.unknownFamily(unknownFamilies)
        }
        
        // Check origin and process are in allowed sets
        let allowedOrigins = Set(profile.statistics.originStats.map { BeanExplorerScorer.contractNormalize($0.feature) })
        let allowedProcesses = Set(profile.statistics.processStats.map { BeanExplorerScorer.contractNormalize($0.feature) })
        
        if let origin = result.origin {
            let normalized = BeanExplorerScorer.contractNormalize(origin)
            guard allowedOrigins.contains(normalized) else {
                throw CoffeeDescriptorNormalizerError.invalidOriginOrProcess(origin: origin, process: result.process)
            }
        }
        
        if let process = result.process {
            let normalized = BeanExplorerScorer.contractNormalize(process)
            guard allowedProcesses.contains(normalized) else {
                throw CoffeeDescriptorNormalizerError.invalidOriginOrProcess(origin: result.origin, process: process)
            }
        }
    }
    
    private func shouldRetry(error: Error) -> Bool {
        switch error {
        case CoffeeDescriptorNormalizerError.invalidJSON,
             CoffeeDescriptorNormalizerError.unknownFamily,
             CoffeeDescriptorNormalizerError.invalidOriginOrProcess:
            return true
        default:
            return false
        }
    }
    
    private static func systemPrompt(profile: BeanExplorerProfile) -> String {
        let familyList = profile.lexicon.categoryTerms.keys.sorted().joined(separator: "\n  - ")
        let originList = profile.statistics.originStats.map(\.feature).sorted().joined(separator: "\n  - ")
        let processList = profile.statistics.processStats.map(\.feature).sorted().joined(separator: "\n  - ")
        
        return """
        You normalize coffee flavor descriptors to canonical profile keys.
        
        Map free-text flavor notes, origin, and process to canonical schema.
        NEVER invent flavor families outside the allowed list.
        NEVER output Fit or Novelty scores - you only normalize descriptors.
        
        Allowed flavor family IDs (use these EXACT IDs only):
          - \(familyList)
        
        Allowed origin keys (use these EXACT values only):
          - \(originList)
        
        Allowed process keys (use these EXACT values only):
          - \(processList)
        
        Semantic mapping rules:
        - Map Chinese terms to their English equivalents: 浆果→berry, 热带水果→tropical fruit, 柑橘→citrus, etc.
        - Map synonyms: stone fruit=核果, berries=浆果, caramel=焦糖, honey=蜂蜜, apple=苹果, black tea=红茶, etc.
        - For flavor_families, return the family ID from the allowed list (e.g. "fruit.berry", "fruit.citrus")
        - For origin and process, return the EXACT canonical key from the allowed list (case matters)
        - If origin or process cannot be mapped to an allowed key, use null
        - descriptor_terms_kept_for_display should contain the original raw terms for UI display
        
        Return ONLY valid JSON. Do not use markdown code fences. Do not add explanations.
        """
    }
}

// MARK: - Text-only Ark client extension

extension ArkResponsesClient {
    /// Send text-only request (no image data).
    func extract(
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int
    ) async throws -> String {
        let credentials = try credentialsLoader()
        let payload = ArkResponsesPayload(
            model: credentials.model,
            input: [
                .init(
                    role: "system",
                    content: [
                        .init(type: "input_text", imageURL: nil, detail: nil, text: systemPrompt)
                    ]
                ),
                .init(
                    role: "user",
                    content: [
                        .init(type: "input_text", imageURL: nil, detail: nil, text: userPrompt)
                    ]
                )
            ],
            temperature: 0,
            maxOutputTokens: maxOutputTokens
        )
        
        var request = URLRequest(url: credentials.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 120
        
        defer {
            if invalidatesSessionAfterRequest {
                session.finishTasksAndInvalidate()
            }
        }
        
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoffeeDescriptorNormalizerError.invalidResponse
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CoffeeDescriptorNormalizerError.requestFailed(statusCode: httpResponse.statusCode)
        }
        
        // Use same response structure as BagPhotoScanner
        struct ArkResponsesResponse: Decodable {
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
                    throw CoffeeDescriptorNormalizerError.invalidResponse
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
        
        let decoded = try JSONDecoder().decode(ArkResponsesResponse.self, from: data)
        return try decoded.extractedText()
    }
}

#endif
