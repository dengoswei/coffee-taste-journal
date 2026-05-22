# Coffee Taste Memory Journal

Open-source SwiftUI coffee tasting journal with a durable bean memory model, cup logging, taste reflection, and AI-assisted coffee bag extraction.

## Product Shape

- `Journal`: default tab, quick cup logging plus private tasting timeline.
- `Beans`: coffee memory objects, active/history bags, scan-assisted Add Bean.
- `Taste`: preference reflection, liked/skipped patterns, most-loved coffees.

## Model

- `Coffee`: stable identity across time.
- `CoffeeBag`: one purchased bag or lot, including roast date and grams remaining.
- `BrewLog`: one cup/brew event with quick verdict and optional brew details.

## Local Commands

```bash
swift test
swift run CoffeeJournalCoreChecks
swift build
xcodegen generate
xcodebuild -project CoffeeTasteJournal.xcodeproj \
  -scheme CoffeeJournalApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

## Local Ark Configuration

The app reads Ark credentials from the iOS Keychain. Do not commit real API keys.

For local development, copy `config.example.json` to `config.json`, fill in local credentials, and keep `config.json` ignored by git:

```bash
cp config.example.json config.json
python3 scripts/seed_ark_keychain.py
```

You can also seed credentials through Xcode Run environment variables in a debug build:

```bash
ARK_API_KEY=<your local key>
ARK_MODEL=<your Ark VLM endpoint or model>
ARK_IMAGE_MODEL=doubao-seedream-5-0-260128
ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
```

## iOS App Target

`CoffeeTasteJournal.xcodeproj` is generated from `project.yml` using XcodeGen. The app target runs on iOS 17+ and uses the existing SwiftUI screens:

- `CoffeeJournalApp`: simulator-installable iOS app.
- `CoffeeJournalCore`: framework with the journal model and taste analysis logic.
- `CoffeeJournalCoreTests`: XCTest coverage for add/reactivate/log/finish/taste fallback flows.

The current local setup has Xcode 26.4.1 selected and an iOS 26.4 simulator runtime installed.
