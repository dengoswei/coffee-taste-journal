import Foundation
import SwiftUI

struct TasteProfileFamily: Identifiable {
    let id: String
    let name: String
    let lovedCount: Int
    let ratedCount: Int
    let weightedRating: Double
    let color: Color

    var isStable: Bool { lovedCount > 2 }
}

struct TasteProfileRatingTier: Identifiable {
    let id: String
    let name: String
    let count: Int
    let color: Color
}

enum PersonalTasteProfile {
    static let snapshotDate = "Aug 2, 2026"
    static let ratedObservations = 53
    static let substantiveNotes = 4

    static let headline = "Citrus and stone fruit anchor your taste"
    static let narrative = "Across your highest-rated coffees, citrus and stone fruit repeat most often, followed by berries and tropical fruit. Ratings drive this profile; sparse written notes stay as clues, not preference claims."

    static let families: [TasteProfileFamily] = [
        TasteProfileFamily(id: "fruit.citrus", name: "Citrus", lovedCount: 4, ratedCount: 25, weightedRating: 1.973, color: Color(red: 0.96, green: 0.58, blue: 0.12)),
        TasteProfileFamily(id: "fruit.stone", name: "Stone fruit", lovedCount: 4, ratedCount: 22, weightedRating: 1.961, color: Color(red: 0.93, green: 0.42, blue: 0.31)),
        TasteProfileFamily(id: "fruit.berry", name: "Berries", lovedCount: 3, ratedCount: 18, weightedRating: 1.844, color: Color(red: 0.66, green: 0.16, blue: 0.28)),
        TasteProfileFamily(id: "fruit.tropical", name: "Tropical fruit", lovedCount: 3, ratedCount: 15, weightedRating: 2.069, color: Color(red: 0.91, green: 0.68, blue: 0.12)),
        TasteProfileFamily(id: "floral", name: "Floral", lovedCount: 2, ratedCount: 17, weightedRating: 1.839, color: Color(red: 0.67, green: 0.43, blue: 0.68)),
        TasteProfileFamily(id: "fruit.dried", name: "Dried fruit", lovedCount: 2, ratedCount: 0, weightedRating: 0, color: Color(red: 0.55, green: 0.33, blue: 0.24)),
        TasteProfileFamily(id: "spice_herbal", name: "Spice & herbs", lovedCount: 2, ratedCount: 0, weightedRating: 0, color: Color(red: 0.35, green: 0.52, blue: 0.31)),
        TasteProfileFamily(id: "sweet.browning", name: "Caramel sweetness", lovedCount: 2, ratedCount: 14, weightedRating: 2.006, color: Color(red: 0.63, green: 0.38, blue: 0.18))
    ]

    static let ratingTiers: [TasteProfileRatingTier] = [
        TasteProfileRatingTier(id: "loved", name: "Loved", count: 7, color: Color(red: 0.72, green: 0.20, blue: 0.24)),
        TasteProfileRatingTier(id: "liked", name: "Liked", count: 34, color: CoffeeTheme.accent),
        TasteProfileRatingTier(id: "ok", name: "Ok", count: 12, color: CoffeeTheme.subtle),
        TasteProfileRatingTier(id: "disliked", name: "Disliked", count: 0, color: Color.gray.opacity(0.35))
    ]

    static let unknowns = [
        "Preferred roast level",
        "Body and mouthfeel",
        "Finish length and character",
        "Acidity intensity and bitterness limits"
    ]
}
