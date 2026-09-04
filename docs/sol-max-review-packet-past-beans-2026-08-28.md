# Sol Max Review Packet: Silent Artwork and Past Beans Archive

## Proposed decision

Adopt the implemented Coffee Journal iteration with these product choices:

1. Remove `BGContinuedProcessingTask` and its system Live Activity. Start artwork generation immediately with a normal task plus a short UIKit background assertion, and persist deferred work for a fixed `BGProcessingTask` wake-up.
2. Record a truthful optional `CoffeeBag.finishedAt` for new active-to-finished transitions. Keep legacy timestamps absent and use the global persisted bag-array index as their deterministic ordering fallback.
3. Present Past Beans through a stable `Recent / Roasters` segmented control. Recent and each selected-roaster list show at most 50 coffees after filtering. The Roasters segment is a browsable index rather than a dropdown, ordered by completed-coffee count descending; ties use latest completion order and then the display name.

## Exact downstream action

Treat this product design as implementation-ready and proceed to device acceptance testing. Do not change the existing flavor-artwork prompt, recommendation model, taste scores, or coffee-profile evaluation.

## Frozen implementation under review

- `Sources/CoffeeJournalApp/BeansView.swift`
- `Sources/CoffeeJournalApp/CoffeeJournalApp.swift`
- `Sources/CoffeeJournalApp/FlavorArtworkBackgroundCoordinator.swift`
- `Sources/CoffeeJournalCore/CoffeeJournalStore.swift`
- `Sources/CoffeeJournalCore/Models.swift`
- `Configuration/CoffeeJournalApp-Info.plist`
- `Tests/CoffeeJournalCoreTests/CoffeeJournalCoreTests.swift`

Review snapshot: local working tree on 2026-08-28 after 27 Swift tests passed and a code-signing-disabled generic iOS build succeeded.

## Acceptance criteria written before review

Approve only if all of the following hold:

- The experience meets the explicit emotional requirement: backgrounding the app creates no system generating overlay or Live Activity.
- Best-effort deferred generation is communicated and persisted without falsely promising immediate completion.
- New completion ordering is truthful, while legacy ordering is deterministic and does not fabricate dates.
- `Recent / Roasters` remains clear at both small and large roaster counts, avoids dropdown interaction, and does not mix search scopes unexpectedly.
- Search/grouping happens before the 50-item cap, and navigating back from a roaster preserves the archive context.
- The implementation preserves old artwork during replacement and prevents a stale request from overwriting the current request.
- Accessibility and empty states are adequate for this personal iOS app iteration.

A `do not approve` or `approve with conditions` verdict blocks adoption until every condition is remediated and a new preregistered review passes.

## Evidence and current results

- Unweighted automated result: 27 of 27 Swift tests passed; no custom weighting is used.
- Generic iOS build result: succeeded with `CODE_SIGNING_ALLOWED=NO`.
- A signed device build and in-place install succeeded before the final roaster-ordering-only change. The final change passed the generic iOS build; a fresh in-place device install remains pending because the paired iPhone is currently unavailable to Xcode.
- Static search result: no `BGContinuedProcessingTask`, continued-processing title, or wildcard task identifier remains.
- `BGTaskSchedulerPermittedIdentifiers` contains one exact processing identifier: `com.dengos.CoffeeJournal.flavor-artwork.processing`.
- Added tests cover legacy decoding, finish timestamps, repeated finish, reactivation, zero-gram completion, legacy/timestamp ordering, filter-before-limit, roaster normalization, count-first roaster ordering, stale request rejection, stale-file cleanup, and deferred backoff.

## Prior independent review and remediation

The first preregistered review returned `do_not_approve`. Its implementation conditions were remediated as follows:

- Nonpositive reactivation is rejected in the UI and normalized to a truthful finished bag in the store.
- Roaster archives over 50 items retain a local search path that searches before applying the display cap.
- Changing `Recent / Roasters` no longer changes the search scope of Currently Drinking.
- Request-specific filenames plus publication checks prevent stale metadata commits and remove stale files; a filesystem race test covers this path.
- Roaster rows expose combined accessibility labels and values, and the segmented picker has an explicit accessibility label.

The two remaining acceptance observations are physical-device checks: no system surface after backgrounding during real generation, and VoiceOver/large-text behavior on the archive UI.

## Alternatives considered

### All roasters as chips

One-tap access and small initial UI change, but horizontal discovery degrades as the archive grows.

### Recent chips plus a filter sheet

Scales better than all chips, but adds two filter surfaces and a dropdown-like modal selection path.

### Keep continued processing

Maximizes the chance of uninterrupted execution, but necessarily retains the system progress surface the user explicitly rejected.

### Foreground-only generation

Avoids the system surface and is simpler, but queued work could wait indefinitely if the user backgrounds quickly and does not return soon.

## Constraints

- iOS controls when and whether `BGProcessingTask` runs.
- No server-side queue is added.
- Existing persisted snapshots must decode without destructive migration.
- Existing artwork remains visible until replacement succeeds.
- The current repository contains unrelated uncommitted taste-pipeline work that must remain untouched.
- This is a personal side project optimizing for a quiet, natural experience rather than commercial experimentation.

## Leakage boundaries

- The reviewer must not infer preference from option labels or prior reviewer identities.
- The selected UI is identified because this is a safety/adoption review, not a blind comparative ranking.
- No private coffee history, API key, Keychain data, generated artifacts, or files under `private/` or `backups/` are included.

## Known unknowns

- Real iOS scheduling latency cannot be established by unit tests or a generic build.
- The absence of a Live Activity must still be confirmed on a physical device while locking or leaving the app during a real generation.
- Final in-place installation and physical-device acceptance are blocked until the paired iPhone becomes available to Xcode again.
