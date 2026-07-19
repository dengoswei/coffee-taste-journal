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

## Personal Taste Profile Evaluation

The repository includes an evidence-grounded profile and recommendation
pipeline. Personal history and generated profiles stay under ignored
`private/`; iPhone exports stay under ignored `backups/`.

```bash
python3 scripts/build_coffee_taste_dataset.py
python3 scripts/evaluate_coffee_taste_prompts.py \
  --versions v1 \
  --max-cases 5 \
  --thinking disabled
python3 -m unittest discover -s Tests -p 'test_*.py'
```

See [docs/coffee-taste-profile-and-recommendation.md](docs/coffee-taste-profile-and-recommendation.md)
for the data contract, leakage boundaries, metrics, prompt versions, and app
integration guidance.

Prompt tuning, judge/evaluation decisions, and taste or recommendation design
must pass an independent Sol Max review before they are treated as final:

```bash
python3 scripts/consult_sol_max.py \
  --prepare \
  --topic prompt-and-judge-design \
  --scope "adopt prompt v1 as the internal regression baseline" \
  --question "Should coffee profile and recommendation v1 remain the baseline?" \
  --acceptance-criteria "Approve only as an internal regression baseline if contract gains are real and predictive claims remain explicitly unvalidated." \
  --input prompts/coffee_profile_v1.md \
  --input prompts/coffee_recommend_v1.md \
  --input docs/coffee-taste-profile-and-recommendation.md

python3 scripts/consult_sol_max.py \
  --preregistration .generated/sol-max-preregistrations/<review>.json \
  --preregistration-sha256 <sha-from-prepare>

python3 scripts/verify_sol_max_gate.py \
  .generated/sol-max-reviews/<review>.gate.json \
  --scope "adopt prompt v1 as the internal regression baseline"
```

The script invokes `gpt-5.6-sol` with maximum reasoning in a read-only,
ephemeral session. Protocol v4 binds the exact downstream scope, specification,
runner/verifier source hashes, and review inputs. It returns a blocking exit
code unless the verdict is an unconditional approval; blocked decisions must be
remediated and reviewed again. Reports and prompt snapshots stay under ignored
`.generated/sol-max-reviews/`. Inputs under `private/`, `backups/`, and generated
artifacts are rejected unless `--allow-private` is explicitly supplied.

Create a complete local Flomo backup before refreshing curated observations:

```bash
python3 scripts/backup_flomo.py
cd backups/flomo/$(jq -r .backup backups/flomo/latest.json)
shasum -a 256 -c SHA256SUMS
```

The timestamped raw memo corpus, media files, manifest, and checksums are stored
under ignored `backups/flomo/`. Flomo authorization is read from
`FLOMO_AUTHORIZATION` or `~/.flomo/config.json` and is never copied into the
backup.

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
