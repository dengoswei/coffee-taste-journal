import Foundation

public enum CoffeeJournalSampleData {
    public static func store(now: Date = Date()) -> CoffeeJournalStore {
        let calendar = Calendar.current
        let guji = Coffee(
            roaster: "SEY Coffee",
            name: "Ethiopia Guji",
            origin: "Guji, Ethiopia",
            variety: "Heirloom",
            process: "Washed",
            flavorNotes: ["jasmine", "peach", "tea-like"],
            verdict: .loved
        )
        let kenya = Coffee(
            roaster: "La Cabra",
            name: "Kenya Nyeri AA",
            origin: "Nyeri, Kenya",
            variety: "SL28",
            process: "Washed",
            flavorNotes: ["blackcurrant", "citrus", "bright"],
            verdict: .liked
        )
        let colombia = Coffee(
            roaster: "Dak Coffee Roasters",
            name: "Colombia Huila",
            origin: "Huila, Colombia",
            variety: "Caturra",
            process: "Washed",
            flavorNotes: ["red apple", "brown sugar", "jasmine"],
            verdict: .ok
        )

        let gujiBag = CoffeeBag(
            coffeeID: guji.id,
            roastDate: calendar.date(byAdding: .day, value: -10, to: now) ?? now,
            totalGrams: 250,
            remainingGrams: 120,
            restDays: 10,
            brewAdvice: "Try a 1:16 ratio after day 10."
        )
        let kenyaBag = CoffeeBag(
            coffeeID: kenya.id,
            roastDate: calendar.date(byAdding: .day, value: -14, to: now) ?? now,
            totalGrams: 250,
            remainingGrams: 45,
            restDays: 12,
            brewAdvice: "Keep extraction gentle; acidity can spike."
        )
        let oldColombiaBag = CoffeeBag(
            coffeeID: colombia.id,
            roastDate: calendar.date(byAdding: .month, value: -2, to: now) ?? now,
            totalGrams: 250,
            remainingGrams: 0,
            status: .finished,
            restDays: 9
        )

        let logs = [
            BrewLog(
                coffeeID: guji.id,
                bagID: gujiBag.id,
                date: calendar.date(byAdding: .hour, value: -3, to: now) ?? now,
                verdict: .loved,
                tastingNote: "Jasmine and peach showed up clearly. A little thin.",
                gramsUsed: 18,
                details: BrewDetails(
                    method: .oreaV4,
                    doseGrams: 18,
                    doseWaterRatio: "1:16",
                    waterTemperatureCelsius: 92
                )
            ),
            BrewLog(
                coffeeID: kenya.id,
                bagID: kenyaBag.id,
                date: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
                verdict: .liked,
                tastingNote: "Blackcurrant and tea-like finish. Bright but balanced.",
                gramsUsed: 16
            ),
            BrewLog(
                coffeeID: colombia.id,
                bagID: oldColombiaBag.id,
                date: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
                verdict: .ok,
                tastingNote: "Sweet and clean, but not memorable enough to rebuy.",
                gramsUsed: 18
            ),
            BrewLog(
                coffeeID: guji.id,
                bagID: gujiBag.id,
                date: calendar.date(byAdding: .day, value: -5, to: now) ?? now,
                verdict: .loved,
                tastingNote: "More floral after rest. Tea texture is the best part.",
                gramsUsed: 17
            )
        ]

        return CoffeeJournalStore(
            coffees: [guji, kenya, colombia],
            bags: [gujiBag, kenyaBag, oldColombiaBag],
            brewLogs: logs
        )
    }
}
