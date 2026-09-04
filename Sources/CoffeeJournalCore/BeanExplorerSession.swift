import Foundation

public enum BeanExplorerSessionError: Error, Equatable, Sendable {
    case candidateLimitReached
    case imageSourceLimitReached
    case sourceNotFound
    case candidateNotFound
    case unresolvedCandidateFields(Set<String>)
    case promptContractMismatch
    case staleExtractionRequest
}

public enum BeanExplorerFieldProvenance: String, Equatable, Sendable, Codable {
    case extracted
    case userEntered
}

public struct BeanExplorerExtractionRequest: Equatable, Sendable {
    public let sourceID: UUID
    public let sourceRevision: Int
    public let requestRevision: Int
    public let promptContractHash: String

    public init(
        sourceID: UUID,
        sourceRevision: Int,
        requestRevision: Int,
        promptContractHash: String
    ) {
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.requestRevision = requestRevision
        self.promptContractHash = promptContractHash
    }
}

public struct BeanExplorerCandidateDraft: Equatable, Sendable, Codable {
    public var roaster: String
    public var name: String
    public var origin: String
    public var farm: String
    public var variety: String
    public var process: String
    public var flavorNotes: [String]
    public var evidence: [String: String]
    public var uncertainFields: Set<String>
    public var boundingBox: BeanExplorerBoundingBox?

    public init(
        roaster: String = "",
        name: String = "",
        origin: String = "",
        farm: String = "",
        variety: String = "",
        process: String = "",
        flavorNotes: [String] = [],
        evidence: [String: String] = [:],
        uncertainFields: Set<String> = [],
        boundingBox: BeanExplorerBoundingBox? = nil
    ) {
        self.roaster = roaster
        self.name = name
        self.origin = origin
        self.farm = farm
        self.variety = variety
        self.process = process
        self.flavorNotes = flavorNotes
        self.evidence = evidence
        self.uncertainFields = uncertainFields
        self.boundingBox = boundingBox
    }
}

public struct BeanExplorerCandidate: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let rankOrdinal: Int
    public let sourceID: UUID
    public var draft: BeanExplorerCandidateDraft
    public var isConfirmed: Bool
    public var confirmedFields: Set<String>
    public var fieldProvenance: [String: BeanExplorerFieldProvenance]
    public var isRemoved: Bool

    public init(
        id: String,
        rankOrdinal: Int,
        sourceID: UUID,
        draft: BeanExplorerCandidateDraft,
        isConfirmed: Bool = false,
        confirmedFields: Set<String> = [],
        fieldProvenance: [String: BeanExplorerFieldProvenance] = [:],
        isRemoved: Bool = false
    ) {
        self.id = id
        self.rankOrdinal = rankOrdinal
        self.sourceID = sourceID
        self.draft = draft
        self.isConfirmed = isConfirmed
        self.confirmedFields = confirmedFields
        self.fieldProvenance = fieldProvenance
        self.isRemoved = isRemoved
    }
}

public struct BeanExplorerSource: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case image
        case manual
    }

    public enum RequestState: Equatable, Sendable, Codable {
        case idle
        case uploading
        case partialSuccess(validCount: Int, rejectedCount: Int)
        case succeeded(validCount: Int)
        case cancelled
        case failed
    }

    public let id: UUID
    public let ordinal: Int
    public let kind: Kind
    public var requestRevision: Int
    public var requestState: RequestState
    public var isRemoved: Bool

    public init(
        id: UUID,
        ordinal: Int,
        kind: Kind,
        requestRevision: Int = 0,
        requestState: RequestState = .idle,
        isRemoved: Bool = false
    ) {
        self.id = id
        self.ordinal = ordinal
        self.kind = kind
        self.requestRevision = requestRevision
        self.requestState = requestState
        self.isRemoved = isRemoved
    }
}

public struct BeanExplorerSession: Equatable, Sendable, Codable {
    public static let maximumCandidates = 100
    public static let maximumImageSources = 10

    public private(set) var sources: [BeanExplorerSource] = []
    public private(set) var candidates: [BeanExplorerCandidate] = []

    public init() {}

    public mutating func clear() {
        sources = []
        candidates = []
    }

    public var activeCandidates: [BeanExplorerCandidate] {
        candidates.filter { !$0.isRemoved }
    }

    public var activeSources: [BeanExplorerSource] {
        sources.filter { !$0.isRemoved }
    }

    public var activeImageSourceCount: Int {
        activeSources.filter { $0.kind == .image }.count
    }

    public func activeSource(id: UUID) -> BeanExplorerSource? {
        sources.first { $0.id == id && !$0.isRemoved }
    }

    @discardableResult
    public mutating func addImageSource() throws -> BeanExplorerSource {
        guard activeImageSourceCount < Self.maximumImageSources else {
            throw BeanExplorerSessionError.imageSourceLimitReached
        }
        let source = BeanExplorerSource(
            id: UUID(),
            ordinal: sources.count + 1,
            kind: .image
        )
        sources.append(source)
        return source
    }

    public mutating func markUploading(sourceID: UUID) throws {
        let index = try activeSourceIndex(id: sourceID)
        sources[index].requestState = .uploading
    }

    public mutating func beginExtraction(
        sourceID: UUID,
        promptContractHash: String
    ) throws -> BeanExplorerExtractionRequest {
        // Prompt-hash mismatch is diagnostic only (logged by the app). Do not hard-block extraction.
        let index = try activeSourceIndex(id: sourceID)
        sources[index].requestRevision += 1
        sources[index].requestState = .uploading
        return BeanExplorerExtractionRequest(
            sourceID: sourceID,
            sourceRevision: 1,
            requestRevision: sources[index].requestRevision,
            promptContractHash: promptContractHash
        )
    }

    public mutating func commitExtraction(
        request: BeanExplorerExtractionRequest,
        drafts: [BeanExplorerCandidateDraft],
        rejectedCount: Int
    ) throws {
        // Prompt-hash mismatch is diagnostic only — still commit when revision/state match.
        guard let sourceIndex = sources.firstIndex(where: {
            $0.id == request.sourceID &&
            !$0.isRemoved &&
            $0.kind == .image &&
            $0.requestRevision == request.requestRevision &&
            $0.requestState == .uploading
        }) else {
            throw BeanExplorerSessionError.staleExtractionRequest
        }
        guard activeCandidates.count + drafts.count <= Self.maximumCandidates else {
            throw BeanExplorerSessionError.candidateLimitReached
        }

        let firstOrdinal = candidates.count + 1
        let newCandidates = drafts.enumerated().map { offset, draft in
            let ordinal = firstOrdinal + offset
            return BeanExplorerCandidate(
                id: String(format: "candidate-%03d", ordinal),
                rankOrdinal: ordinal,
                sourceID: request.sourceID,
                draft: draft,
                fieldProvenance: Self.extractedProvenance(for: draft)
            )
        }
        candidates.append(contentsOf: newCandidates)
        if rejectedCount > 0 {
            sources[sourceIndex].requestState = .partialSuccess(
                validCount: drafts.count,
                rejectedCount: rejectedCount
            )
        } else {
            sources[sourceIndex].requestState = .succeeded(validCount: drafts.count)
        }
    }

    public mutating func cancelRequest(sourceID: UUID) throws {
        let index = try activeSourceIndex(id: sourceID)
        sources[index].requestState = .cancelled
    }

    @discardableResult
    public mutating func failExtraction(request: BeanExplorerExtractionRequest) -> Bool {
        guard let index = sources.firstIndex(where: {
            $0.id == request.sourceID &&
            !$0.isRemoved &&
            $0.requestRevision == request.requestRevision &&
            $0.requestState == .uploading
        }) else {
            return false
        }
        sources[index].requestState = .failed
        return true
    }

    public mutating func removeSource(sourceID: UUID) throws {
        let index = try activeSourceIndex(id: sourceID)
        sources[index].isRemoved = true
        for candidateIndex in candidates.indices where candidates[candidateIndex].sourceID == sourceID {
            candidates[candidateIndex].isRemoved = true
        }
    }

    public mutating func updateCandidate(
        id: String,
        draft: BeanExplorerCandidateDraft
    ) throws {
        let index = try activeCandidateIndex(id: id)
        let previous = candidates[index].draft
        var resolvedDraft = draft
        var provenance = candidates[index].fieldProvenance
        for field in Self.changedFields(from: previous, to: draft) {
            resolvedDraft.uncertainFields.remove(field)
            provenance[field] = .userEntered
        }
        candidates[index].draft = resolvedDraft
        candidates[index].fieldProvenance = provenance
        candidates[index].isConfirmed = false
        candidates[index].confirmedFields = []
    }

    public mutating func confirmCandidate(id: String) throws {
        let index = try activeCandidateIndex(id: id)
        let unresolved = candidates[index].draft.uncertainFields
        guard unresolved.isEmpty else {
            throw BeanExplorerSessionError.unresolvedCandidateFields(unresolved)
        }
        let populated = Self.populatedFields(in: candidates[index].draft)
        let missingProvenance = populated.filter { candidates[index].fieldProvenance[$0] == nil }
        guard missingProvenance.isEmpty else {
            throw BeanExplorerSessionError.unresolvedCandidateFields(missingProvenance)
        }
        candidates[index].confirmedFields = populated
        candidates[index].isConfirmed = true
    }

    public mutating func removeCandidate(id: String) throws {
        let index = try activeCandidateIndex(id: id)
        candidates[index].isRemoved = true
    }

    @discardableResult
    public mutating func addManualCandidate(
        _ draft: BeanExplorerCandidateDraft
    ) throws -> BeanExplorerCandidate {
        guard activeCandidates.count < Self.maximumCandidates else {
            throw BeanExplorerSessionError.candidateLimitReached
        }
        let source = BeanExplorerSource(
            id: UUID(),
            ordinal: sources.count + 1,
            kind: .manual
        )
        sources.append(source)

        let ordinal = candidates.count + 1
        let candidate = BeanExplorerCandidate(
            id: String(format: "candidate-%03d", ordinal),
            rankOrdinal: ordinal,
            sourceID: source.id,
            draft: draft,
            fieldProvenance: Self.userEnteredProvenance(for: draft)
        )
        candidates.append(candidate)
        return candidate
    }

    private func activeSourceIndex(id: UUID) throws -> Int {
        guard let index = sources.firstIndex(where: { $0.id == id && !$0.isRemoved }) else {
            throw BeanExplorerSessionError.sourceNotFound
        }
        return index
    }

    private func activeCandidateIndex(id: String) throws -> Int {
        guard let index = candidates.firstIndex(where: { $0.id == id && !$0.isRemoved }) else {
            throw BeanExplorerSessionError.candidateNotFound
        }
        return index
    }

    private static func populatedFields(in draft: BeanExplorerCandidateDraft) -> Set<String> {
        var fields: Set<String> = []
        if !draft.roaster.isEmpty { fields.insert("roaster") }
        if !draft.name.isEmpty { fields.insert("name") }
        if !draft.origin.isEmpty { fields.insert("origin") }
        if !draft.farm.isEmpty { fields.insert("farm") }
        if !draft.variety.isEmpty { fields.insert("variety") }
        if !draft.process.isEmpty { fields.insert("process") }
        if !draft.flavorNotes.isEmpty { fields.insert("flavor_notes") }
        return fields
    }

    private static func extractedProvenance(
        for draft: BeanExplorerCandidateDraft
    ) -> [String: BeanExplorerFieldProvenance] {
        Dictionary(uniqueKeysWithValues: populatedFields(in: draft).compactMap { field in
            let hasEvidence: Bool
            if field == "flavor_notes" {
                hasEvidence = draft.evidence.keys.filter { $0.hasPrefix("flavor_note_") }.count == draft.flavorNotes.count
            } else {
                hasEvidence = draft.evidence[field] != nil
            }
            return hasEvidence ? (field, .extracted) : nil
        })
    }

    private static func userEnteredProvenance(
        for draft: BeanExplorerCandidateDraft
    ) -> [String: BeanExplorerFieldProvenance] {
        Dictionary(uniqueKeysWithValues: populatedFields(in: draft).map { ($0, .userEntered) })
    }

    private static func changedFields(
        from previous: BeanExplorerCandidateDraft,
        to current: BeanExplorerCandidateDraft
    ) -> Set<String> {
        var fields: Set<String> = []
        if previous.roaster != current.roaster { fields.insert("roaster") }
        if previous.name != current.name { fields.insert("name") }
        if previous.origin != current.origin { fields.insert("origin") }
        if previous.farm != current.farm { fields.insert("farm") }
        if previous.variety != current.variety { fields.insert("variety") }
        if previous.process != current.process { fields.insert("process") }
        if previous.flavorNotes != current.flavorNotes { fields.insert("flavor_notes") }
        return fields
    }
}
