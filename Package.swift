// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoffeeTasteJournal",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CoffeeJournalCore",
            targets: ["CoffeeJournalCore"]
        ),
        .executable(
            name: "CoffeeJournalApp",
            targets: ["CoffeeJournalApp"]
        ),
        .executable(
            name: "CoffeeJournalCoreChecks",
            targets: ["CoffeeJournalCoreChecks"]
        )
    ],
    targets: [
        .target(
            name: "CoffeeJournalCore"
        ),
        .executableTarget(
            name: "CoffeeJournalApp",
            dependencies: ["CoffeeJournalCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CoffeeJournalCoreChecks",
            dependencies: ["CoffeeJournalCore"]
        ),
        .testTarget(
            name: "CoffeeJournalCoreTests",
            dependencies: ["CoffeeJournalCore"]
        )
    ]
)
