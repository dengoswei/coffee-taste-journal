import Foundation

public enum Verdict: String, CaseIterable, Codable, Identifiable, Sendable {
    case loved = "Loved"
    case liked = "Liked"
    case ok = "Ok"
    case disliked = "Disliked"

    public var id: String { rawValue }
}

public enum BagStatus: String, Codable, Sendable {
    case active
    case finished
}

public enum BrewMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case oreaV4 = "OREA V4"
    case e1Prima = "E1 Prima"
    case aeropress = "AeroPress"

    public var id: String { rawValue }
}

public struct Coffee: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var roaster: String
    public var name: String
    public var origin: String
    public var farm: String
    public var variety: String
    public var process: String
    public var flavorNotes: [String]
    public var verdict: Verdict?
    public var notes: String
    public var flavorArtwork: FlavorArtwork?

    public init(
        id: UUID = UUID(),
        roaster: String,
        name: String,
        origin: String,
        farm: String = "",
        variety: String,
        process: String,
        flavorNotes: [String],
        verdict: Verdict? = nil,
        notes: String = "",
        flavorArtwork: FlavorArtwork? = nil
    ) {
        self.id = id
        self.roaster = roaster
        self.name = name
        self.origin = origin
        self.farm = farm
        self.variety = variety
        self.process = process
        self.flavorNotes = flavorNotes
        self.verdict = verdict
        self.notes = notes
        self.flavorArtwork = flavorArtwork
    }

    enum CodingKeys: String, CodingKey {
        case id
        case roaster
        case name
        case origin
        case farm
        case variety
        case process
        case flavorNotes
        case verdict
        case notes
        case flavorArtwork
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        roaster = try container.decode(String.self, forKey: .roaster)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decode(String.self, forKey: .origin)
        farm = try container.decodeIfPresent(String.self, forKey: .farm) ?? ""
        variety = try container.decode(String.self, forKey: .variety)
        process = try container.decode(String.self, forKey: .process)
        flavorNotes = try container.decode([String].self, forKey: .flavorNotes)
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        flavorArtwork = try container.decodeIfPresent(FlavorArtwork.self, forKey: .flavorArtwork)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(roaster, forKey: .roaster)
        try container.encode(name, forKey: .name)
        try container.encode(origin, forKey: .origin)
        try container.encode(farm, forKey: .farm)
        try container.encode(variety, forKey: .variety)
        try container.encode(process, forKey: .process)
        try container.encode(flavorNotes, forKey: .flavorNotes)
        try container.encodeIfPresent(verdict, forKey: .verdict)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(flavorArtwork, forKey: .flavorArtwork)
    }
}

public struct FlavorArtwork: Codable, Equatable, Sendable {
    public var model: String
    public var promptHash: String
    public var sourcePrompt: String
    public var createdAt: Date
    public var heroFilename: String
    public var cardFilename: String
    public var thumbnailFilename: String

    public init(
        model: String,
        promptHash: String,
        sourcePrompt: String,
        createdAt: Date = Date(),
        heroFilename: String,
        cardFilename: String,
        thumbnailFilename: String
    ) {
        self.model = model
        self.promptHash = promptHash
        self.sourcePrompt = sourcePrompt
        self.createdAt = createdAt
        self.heroFilename = heroFilename
        self.cardFilename = cardFilename
        self.thumbnailFilename = thumbnailFilename
    }
}

public struct CoffeeBag: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var coffeeID: UUID
    public var roastDate: Date?
    public var totalGrams: Double
    public var remainingGrams: Double
    public var status: BagStatus
    public var restDays: Int?
    public var brewAdvice: String
    public var photoAssetIdentifier: String?

    public init(
        id: UUID = UUID(),
        coffeeID: UUID,
        roastDate: Date? = nil,
        totalGrams: Double,
        remainingGrams: Double,
        status: BagStatus = .active,
        restDays: Int? = nil,
        brewAdvice: String = "",
        photoAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.coffeeID = coffeeID
        self.roastDate = roastDate
        self.totalGrams = totalGrams
        self.remainingGrams = remainingGrams
        self.status = status
        self.restDays = restDays
        self.brewAdvice = brewAdvice
        self.photoAssetIdentifier = photoAssetIdentifier
    }

    public var consumedGrams: Double {
        max(0, totalGrams - remainingGrams)
    }

    public var remainingRatio: Double {
        guard totalGrams > 0 else { return 0 }
        return max(0, min(1, remainingGrams / totalGrams))
    }
}

public struct BrewDetails: Codable, Equatable, Sendable {
    public var method: BrewMethod
    public var doseGrams: Double?
    public var doseWaterRatio: String
    public var waterTemperatureCelsius: Double?
    public var grindSetting: String

    public init(
        method: BrewMethod = .oreaV4,
        doseGrams: Double? = nil,
        doseWaterRatio: String = "",
        waterTemperatureCelsius: Double? = nil,
        grindSetting: String = ""
    ) {
        self.method = method
        self.doseGrams = doseGrams
        self.doseWaterRatio = doseWaterRatio
        self.waterTemperatureCelsius = waterTemperatureCelsius
        self.grindSetting = grindSetting
    }
}

public struct BrewLog: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var coffeeID: UUID
    public var bagID: UUID?
    public var date: Date
    public var verdict: Verdict
    public var tastingNote: String
    public var gramsUsed: Double?
    public var details: BrewDetails?

    public init(
        id: UUID = UUID(),
        coffeeID: UUID,
        bagID: UUID? = nil,
        date: Date = Date(),
        verdict: Verdict,
        tastingNote: String,
        gramsUsed: Double? = nil,
        details: BrewDetails? = nil
    ) {
        self.id = id
        self.coffeeID = coffeeID
        self.bagID = bagID
        self.date = date
        self.verdict = verdict
        self.tastingNote = tastingNote
        self.gramsUsed = gramsUsed
        self.details = details
    }
}

public struct BagScanDraft: Equatable, Sendable {
    public var coffee: Coffee
    public var roastDate: Date?
    public var totalGrams: Double?
    public var restDays: Int?
    public var brewAdvice: String
    public var photoAssetIdentifier: String?

    public init(
        coffee: Coffee,
        roastDate: Date? = nil,
        totalGrams: Double? = nil,
        restDays: Int? = nil,
        brewAdvice: String = "",
        photoAssetIdentifier: String? = nil
    ) {
        self.coffee = coffee
        self.roastDate = roastDate
        self.totalGrams = totalGrams
        self.restDays = restDays
        self.brewAdvice = brewAdvice
        self.photoAssetIdentifier = photoAssetIdentifier
    }
}
