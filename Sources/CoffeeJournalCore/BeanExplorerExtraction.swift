import Foundation

public struct BeanExplorerBoundingBox: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct BeanExplorerExtractionResult: Equatable, Sendable {
    public let candidates: [BeanExplorerCandidateDraft]
    public let rejectedCount: Int

    public init(candidates: [BeanExplorerCandidateDraft], rejectedCount: Int) {
        self.candidates = candidates
        self.rejectedCount = rejectedCount
    }
}

public enum BeanExplorerExtractionError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unsupportedSchema
    case invalidPackage
}

public struct BeanExplorerExtractionParser: Sendable {
    public init() {}

    public func parse(
        _ json: String,
        remainingCapacity: Int
    ) throws -> BeanExplorerExtractionResult {
        guard let data = json.data(using: .utf8) else {
            throw BeanExplorerExtractionError.invalidEnvelope
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasExactExtractionShape(object) else {
            throw BeanExplorerExtractionError.invalidEnvelope
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw BeanExplorerExtractionError.invalidEnvelope
        }
        guard envelope.schemaVersion == "bean-explorer-extraction-v1" else {
            throw BeanExplorerExtractionError.unsupportedSchema
        }
        guard envelope.packages.count <= 8, envelope.rejectedRegions.count <= 8,
              envelope.rejectedRegions.allSatisfy(\.isValid) else {
            throw BeanExplorerExtractionError.invalidEnvelope
        }
        let packageIndexes = envelope.packages.map(\.packageIndex)
        guard packageIndexes.allSatisfy({ $0 > 0 }),
              Set(packageIndexes).count == packageIndexes.count,
              packageIndexes.enumerated().allSatisfy({ $0.element == $0.offset + 1 }) else {
            throw BeanExplorerExtractionError.invalidEnvelope
        }

        let capacity = max(0, remainingCapacity)
        var candidates: [BeanExplorerCandidateDraft] = []
        var rejectedCount = envelope.rejectedRegions.count
        for package in envelope.packages {
            guard candidates.count < capacity else {
                rejectedCount += 1
                continue
            }
            do {
                candidates.append(try package.candidateDraft())
            } catch BeanExplorerExtractionError.invalidPackage {
                rejectedCount += 1
            }
        }
        return BeanExplorerExtractionResult(
            candidates: candidates,
            rejectedCount: rejectedCount
        )
    }
}

private struct Envelope: Decodable {
    let schemaVersion: String
    let packages: [Package]
    let rejectedRegions: [RejectedRegion]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packages
        case rejectedRegions = "rejected_regions"
    }
}

private struct Package: Decodable {
    let packageIndex: Int
    let boundingBox: [Double]?
    let coffee: CoffeeFields
    let evidence: [String: String?]
    let uncertainFields: [String]

    enum CodingKeys: String, CodingKey {
        case packageIndex = "package_index"
        case boundingBox = "bounding_box"
        case coffee
        case evidence
        case uncertainFields = "uncertain_fields"
    }

    func candidateDraft() throws -> BeanExplorerCandidateDraft {
        guard packageIndex > 0 else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        let box = try validatedBoundingBox()
        let normalizedEvidence = evidence.compactMapValues(clean)
        let allowedFields: Set<String> = [
            "roaster", "name", "origin", "farm", "variety", "process", "flavor_notes"
        ]
        let uncertainty = Set(uncertainFields)
        guard uncertainty.isSubset(of: allowedFields),
              Set(evidence.keys).isSubset(of: allowedFields.subtracting(["flavor_notes"])) else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        let scalarValues: [(field: String, value: String?)] = [
            ("roaster", clean(coffee.roaster)),
            ("name", clean(coffee.name)),
            ("origin", clean(coffee.origin)),
            ("farm", clean(coffee.farm)),
            ("variety", clean(coffee.variety)),
            ("process", clean(coffee.process)),
        ]
        for (field, value) in scalarValues {
            if value != nil && normalizedEvidence[field] == nil {
                throw BeanExplorerExtractionError.invalidPackage
            }
            if uncertainty.contains(field), value != nil {
                throw BeanExplorerExtractionError.invalidPackage
            }
        }
        let valueByField = Dictionary(uniqueKeysWithValues: scalarValues.compactMap { item in
            item.value.map { (item.field, $0) }
        })
        let notes = coffee.flavorNotes.compactMap { note -> String? in
            guard let value = clean(note.value), clean(note.evidence) != nil else { return nil }
            return value
        }
        guard notes.count == coffee.flavorNotes.count,
              notes.count <= 12,
              !uncertainty.contains("flavor_notes") || notes.isEmpty else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        let noteEvidence = coffee.flavorNotes.enumerated().reduce(into: normalizedEvidence) { result, item in
            if let evidence = clean(item.element.evidence) {
                result["flavor_note_\(item.offset + 1)"] = evidence
            }
        }
        let draft = BeanExplorerCandidateDraft(
            roaster: valueByField["roaster"] ?? "",
            name: valueByField["name"] ?? "",
            origin: valueByField["origin"] ?? "",
            farm: valueByField["farm"] ?? "",
            variety: valueByField["variety"] ?? "",
            process: valueByField["process"] ?? "",
            flavorNotes: notes,
            evidence: noteEvidence,
            uncertainFields: uncertainty,
            boundingBox: box
        )
        guard !draft.roaster.isEmpty || !draft.name.isEmpty || !draft.origin.isEmpty ||
                !draft.farm.isEmpty || !draft.variety.isEmpty || !draft.process.isEmpty ||
                !draft.flavorNotes.isEmpty else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        return draft
    }

    private func validatedBoundingBox() throws -> BeanExplorerBoundingBox? {
        guard let boundingBox else { return nil }
        guard boundingBox.count == 4 else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        let box = BeanExplorerBoundingBox(
            top: boundingBox[0],
            left: boundingBox[1],
            bottom: boundingBox[2],
            right: boundingBox[3]
        )
        guard (0...1).contains(box.top), (0...1).contains(box.left),
              (0...1).contains(box.bottom), (0...1).contains(box.right),
              box.top < box.bottom, box.left < box.right else {
            throw BeanExplorerExtractionError.invalidPackage
        }
        return box
    }
}

private struct CoffeeFields: Decodable {
    let roaster: String?
    let name: String?
    let origin: String?
    let farm: String?
    let variety: String?
    let process: String?
    let flavorNotes: [FlavorNote]

    enum CodingKeys: String, CodingKey {
        case roaster
        case name
        case origin
        case farm
        case variety
        case process
        case flavorNotes = "flavor_notes"
    }
}

private struct FlavorNote: Decodable {
    let value: String?
    let evidence: String?
}

private struct RejectedRegion: Decodable {
    let boundingBox: [Double]?
    let reason: String

    enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case reason
    }

    var isValid: Bool {
        guard ["not_coffee_package", "duplicate_in_image", "too_unclear"].contains(reason) else {
            return false
        }
        guard let boundingBox else { return true }
        guard boundingBox.count == 4 else { return false }
        return boundingBox.allSatisfy { (0...1).contains($0) } &&
            boundingBox[0] < boundingBox[2] && boundingBox[1] < boundingBox[3]
    }
}

private func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.lowercased() != "null" else { return nil }
    return String(cleaned.unicodeScalars.prefix(160))
}

private func hasExactExtractionShape(_ object: [String: Any]) -> Bool {
    guard Set(object.keys) == ["schema_version", "packages", "rejected_regions"],
          let packages = object["packages"] as? [[String: Any]],
          let rejectedRegions = object["rejected_regions"] as? [[String: Any]] else {
        return false
    }
    let packageKeys: Set<String> = [
        "package_index", "bounding_box", "coffee", "evidence", "uncertain_fields"
    ]
    let coffeeKeys: Set<String> = [
        "roaster", "name", "origin", "farm", "variety", "process", "flavor_notes"
    ]
    let evidenceKeys: Set<String> = ["roaster", "name", "origin", "farm", "variety", "process"]
    let flavorNoteKeys: Set<String> = ["value", "evidence"]
    let rejectedRegionKeys: Set<String> = ["bounding_box", "reason"]

    for package in packages {
        guard Set(package.keys) == packageKeys,
              let coffee = package["coffee"] as? [String: Any],
              Set(coffee.keys) == coffeeKeys,
              let evidence = package["evidence"] as? [String: Any],
              Set(evidence.keys) == evidenceKeys,
              let flavorNotes = coffee["flavor_notes"] as? [[String: Any]],
              flavorNotes.allSatisfy({ Set($0.keys) == flavorNoteKeys }),
              package["uncertain_fields"] is [String] else {
            return false
        }
    }
    return rejectedRegions.allSatisfy { Set($0.keys) == rejectedRegionKeys }
}
