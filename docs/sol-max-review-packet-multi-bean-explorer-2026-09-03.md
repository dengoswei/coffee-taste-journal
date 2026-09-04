# Sol Max Review Packet: Multi-Bean Explorer Workbench

## Proposed Decision

Adopt **Explorer Workbench** as the product and interaction design for a
personal, temporary, pre-purchase coffee comparison flow in Coffee Journal.

The entry sits immediately below the existing Taste profile hero. It opens a
three-stage flow:

1. **Collect** one or more camera photos or library images. One image may contain
   multiple coffee packages.
2. **Review** the extracted candidate cards, their source images, missing fields,
   and possible duplicates before scoring.
3. **Explore** an exploration-first recommendation headed by a Frontier Pick
   when one qualifies, followed by a Best-Supported Match and the remaining
   approximate ranking.

The session supports 2-8 candidates from 1-5 images. It is held in memory only
and is discarded when the flow closes. Scanned candidates never enter Beans,
ratings, evaluation cases, or recommendation history.

The approved visual direction is stored at
`docs/design-assets/multi-bean-explorer-workbench-2026-09-03.png`, SHA-256
`83f7a11a931d53857da5d6beddd66bd52541455615deb288a9deb6f6418f4852`.
The image contains illustrative products and scores, not evaluation results.

## Decision Scope

This review covers the product boundary, navigation placement, interaction
stages, result hierarchy, trust disclosures, and the architecture boundary
between visual extraction and deterministic scoring.

It does **not** approve an implementation, a prompt, a new scorer, current taste
accuracy, calibrated probabilities, a specific VLM, or shipment. Those require
their own frozen inputs, tests, acceptance criteria, and reviews.

## Acceptance Criteria Written Before Review

Approve this product design only if all of the following are true:

1. The feature remains a temporary pre-purchase workspace and cannot silently
   mutate the journal, rating history, evaluation data, or persistent candidate
   lists.
2. The primary entry belongs in Taste, while Beans -> Add Bean remains the
   post-purchase inventory path.
3. A user can trace every candidate to a source image and can delete, merge,
   supplement, or edit it before scoring.
4. Package grouping and field extraction failures are explicit. Partial results
   stay editable, and missing evidence never becomes invented metadata.
5. A generative model may extract seller-declared fields and, only after a
   separate gate, write a constrained explanation. It may not generate or alter
   Fit, Novelty, Best-Supported Match, Frontier Pick, or ranking values.
6. Fit and Novelty come from a versioned deterministic scorer and profile bound
   by identifiers and hashes. The app must fail closed on scorer/profile version
   mismatch.
7. The result leads with a Frontier Pick only when it clears the frozen fit gate
   and has a real familiar bridge. Otherwise the UI says that no credible
   frontier candidate was found and leads with the Best-Supported Match.
8. Seller descriptors are labeled as claims. Price, estate reputation, variety
   prestige, and accolades remain contextual and do not move Fit or Novelty.
9. The UI describes scores as relative ordering signals, identifies near-ties,
   and exposes the profile snapshot date and evidence limitations. It never
   renders Fit as a probability of liking.
10. Candidate photos and screenshot crops are not persisted or included in
    diagnostics by default. The UI discloses that selected images are sent to
    the configured extraction service before upload.
11. Empty, loading, partial, all-insufficient, extraction-error, scoring-error,
    offline, cancellation, and stale-profile states have recoverable behavior.
12. The approved design remains usable with Dynamic Type, VoiceOver, long
    roaster and coffee names, Chinese and English packaging, and at least a
    44-by-44-point activation target.

Any conditional verdict blocks adoption under protocol v4.

## Frozen Product Labels

- Primary action: `Compare Beans`
- Flow stages: `Collect`, `Review`, `Explore`
- Recommendation roles: `Frontier Pick`, `Best-Supported Match`
- Metrics: `Fit`, `Novelty`
- Candidate states: `Ready`, `Missing information`, `Needs review`,
  `Could not extract`
- Trust copy: `Seller flavor notes are claims.`
- Score copy: `Relative ordering`

The approved mockup predates the first review and still says `SAFE MATCH`.
That label is superseded by this frozen text specification and must be replaced
before the visual is used as implementation acceptance evidence.

## Screen Specification

### Taste Entry

Keep the existing Taste profile hero. Immediately below it, add one distinct
action panel:

- `Explore your next coffee`
- `Compare bags against your taste.`
- filled action `Compare Beans`

Do not add a fourth tab. Do not put the primary entry in Beans or hide it behind
the Add Bean flow.

### Collect And Review

The top region shows every imported source image as a thumbnail. Camera and
Photos add images to the same session. Extraction may add more than one
candidate per image.

Each candidate row shows a package crop, full roaster and coffee name, origin,
farm or producer, variety, process, and seller-declared flavor descriptors.
Every field retains source-image provenance and an extraction state. Missing or
questionable fields are visually explicit. The user can edit fields, add a
supplementary photo, delete a candidate, or merge duplicates.

`See Recommendations` is available only with two or more scorable candidates.
Candidates with insufficient inputs remain in the review list with a reason and
are excluded from the ranking rather than assigned neutral-looking fabricated
data. If fewer than two candidates are scorable, the flow asks for corrections
or additional images.

### Explore Result

The first section is Frontier Pick when one qualifies. Its explanation follows
this order:

1. familiar bridge supported by declared descriptors and the frozen profile;
2. novel origin, process, or flavor-family dimension;
3. risk and the missing or weak evidence that could change the decision.

Fit and Novelty appear as two separate metrics. A quieter Best-Supported Match
section follows with the qualification `highest evidence-backed relative Fit in
this candidate set; not a liking probability or purchase guarantee`. The
remaining ranking uses full identifiers and the frozen near-tie rules below.
Provenance, accolades, and price, if present, sit in a separate context section
labeled as unscored.

The footer identifies the profile snapshot date, score mode, profile ID, and the
self-selected evidence limitation.

## Existing Implementation Reused

- `Sources/CoffeeJournalApp/TasteView.swift`: existing Taste navigation and
  profile hero.
- `Sources/CoffeeJournalApp/BagPhotoScanner.swift`: current single-image,
  single-bag Ark extraction path and editable scan result.
- `Sources/CoffeeJournalApp/BeansView.swift`: existing post-purchase Add Bean
  flow, which remains separate.
- `scripts/portable_coffee_rank.py`: aggregate-only deterministic Fit and
  Novelty reference implementation.
- `scripts/evaluate_coffee_taste_prompts.py`: private scorer and grounding
  reference.
- `docs/portable-coffee-scorer-review-2026-07-25.md`: existing parity evidence,
  privacy boundary, alternatives, and unresolved adoption gate.

## Evaluator And Score Contract

The current portable reference scorer uses:

- Fit: sensory `0.75`, origin `0.15`, process `0.10`;
- capped quality-claim, top-tier-family, and roaster-affinity bonuses;
- Novelty: flavor-family familiarity `0.50`, origin `0.25`, process `0.25`,
  inverted to 0-100;
- Frontier eligibility: minimum Fit `60.0`;
- Frontier selection blend: Novelty `0.55`, Fit `0.45`.

Direct-history adjustment is unavailable in the portable profile and must not
be displayed as zero. The first app implementation should show a separately
derived `Previously logged` identity annotation without changing the score. A
new score adjustment requires a separate reviewed decision.

The app must not hand-copy these constants as an untracked second source of
truth. The proposed ideal architecture generates a Swift contract, frozen
profile artifact, and parity fixtures from the same versioned source used by
the Python scorer.

## Frozen Scorable And Ranking Contract

### Scorable Candidate Predicate

A candidate is scorable only when every condition below is true:

1. the user has explicitly confirmed the candidate after Review;
2. roaster and full coffee name are nonempty after whitespace normalization;
3. origin and process are nonempty and have no unresolved extraction conflict;
4. at least one preserved seller descriptor maps to a frozen scorer flavor
   family;
5. every field read by the scorer has provenance and is either user-entered,
   user-confirmed, or extracted above the separately preregistered confidence
   threshold;
6. profile ID, scorer version, lexicon version, and generated Swift contract
   hashes match.

Missing origin, process, roaster, or descriptor-family evidence never receives
the scorer's neutral default and never increases Novelty. Such a candidate is
excluded with a field-specific reason. Variety, farm, price, altitude,
provenance, and accolades do not control scorable eligibility because they are
not score inputs.

### Best-Supported Match

Among scorable candidates, rank by descending Fit, then descending Novelty, then
canonical candidate ID as a deterministic final tie-breaker. The first candidate
is labeled Best-Supported Match with the non-guarantee qualification above.

### Familiar Bridge

A candidate has a familiar bridge only if it matches at least one flavor family
that, in the frozen profile, has both:

- `top_tier_count >= 3`; and
- `observations >= 6` in category statistics.

The result names the exact matched family and its counts. It may not infer a
bridge from origin, process, roaster, variety, quality language, provenance, or
an untranslated synonym absent from the frozen lexicon.

### Frontier Pick

A Frontier Pick exists only when a candidate:

1. is distinct from Best-Supported Match;
2. is scorable;
3. has Fit at or above the frozen `60.0` gate;
4. has a familiar bridge under the rule above; and
5. wins the frozen `0.55 * Novelty + 0.45 * Fit` blend among qualifying
   candidates, using Fit and canonical candidate ID as tie-breakers.

If no distinct candidate qualifies, `frontier_pick` is `null`. The UI says
`No credible exploration pick in this set` and leads with Best-Supported Match.
It never aliases Best-Supported Match into the Frontier role.

### Near Ties And Role Collisions

- Candidates whose Fit differs by at most `1.5` points are shown in one
  `Similar Fit` band and are not given ordinal numbers within that band.
- A Frontier Pick inside the same Fit band remains visually identified by its
  exploration role, not as a higher-confidence recommendation.
- Best-Supported Match and Frontier Pick are always different candidates.
- With exactly one scorable candidate, show an individual score explanation but
  no comparison, Best-Supported Match, Frontier Pick, or ranked list.
- With zero scorable candidates, show only correction guidance.
- If scoring fails or profile hashes mismatch, show no stale roles or scores.

The `1.5`, `60.0`, familiarity, and frontier-blend thresholds are frozen here
for product semantics but remain shipment-blocked until their dedicated scorer
and threshold gate approves them.

## Immutable In-Session Lineage

The ephemeral session maintains append-only lineage in memory. It is never
written to the journal or diagnostics.

- `SourceImageRevision`: immutable ID, acquisition channel, creation time,
  original pixel dimensions, upload-crop revision, and in-memory image bytes.
- `ExtractionRevision`: immutable ID, source image revision ID, extraction
  request ID, model ID, prompt-contract hash, candidate-local region in
  normalized image coordinates, and raw returned fields.
- `CandidateRevision`: immutable candidate ID and revision ID; ordered parent
  revisions; raw visible value; normalized scorer value; source region IDs;
  field state (`extracted`, `userConfirmed`, `userEntered`, `conflicted`, or
  `missing`); and edit reason.
- A user edit appends a revision and preserves both raw extracted text and the
  new value. Descriptor translation never overwrites the source text.
- Merge creates a new candidate revision with every parent candidate and the
  chosen per-field source. Parents become inactive but remain undoable.
- Delete appends a tombstone and remains undoable until the session ends.
- Adding a supplementary photo creates new source and extraction revisions; it
  never overwrites an older crop or extraction.

Only the latest active candidate revisions enter the scorable predicate. The
UI can reveal `From image`, `Edited`, or `Merged` and open the relevant crop.

## Ephemeral Session Lifecycle

The complete state machine is:

1. `idle` -> `collecting` when Compare Beans opens;
2. each added source independently becomes `queued`, `uploading`, then
   `partialSuccess`, `succeeded`, `retryableFailure`, `terminalFailure`, or
   `cancelled`;
3. any returned candidate revision makes the session `reviewable`, even while
   other sources continue;
4. scoring runs from an immutable snapshot of active confirmed revisions and
   becomes `scoring`, then `results` or `scoringFailure`;
5. any edit after results invalidates the result snapshot and returns to
   `reviewable` before new scores can display;
6. explicit Close, completed interactive dismissal, process termination, crash,
   or memory eviction destroys source bytes, lineage, candidates, and results.

Interactive swipe dismissal with any image or candidate present requires
confirmation: `Discard this comparison?` Continue keeps the session; Discard
destroys it. While the app merely backgrounds and remains alive, the in-memory
session stays available and uploads may continue only under the existing short
foreground background allowance. There is no durable background retry. If iOS
terminates the process, the session is intentionally lost and the next launch
starts empty.

Offline collection remains editable in memory. Scoring can run locally after
candidate fields are complete. Extraction retry is per source and never removes
successful candidates from other sources. Cancellation stops the local request,
marks that source cancelled, and retains any prior successful revisions. A stale
network response whose request ID is no longer current is discarded.

## Product Privacy Contract

Before the first network extraction, disclose:

`Selected images are sent to the configured ByteDance Ark model to read coffee
package text. Images may include unrelated shelf or screen content. Coffee
history and your taste profile stay on this device.`

The contract is:

- Service identity: the configured ByteDance Ark Responses API endpoint and
  exact model ID are displayed in a details disclosure before upload.
- Payload: only a downscaled, orientation-corrected image or user-approved crop,
  the frozen extraction prompt, request ID, and schema version. No journal
  snapshot, ratings, taste profile, device identifier, location, filenames,
  photo-library asset IDs, or prior candidates are sent.
- Minimization: default to the smallest readable crop; screenshots receive an
  explicit crop/confirm step when unrelated content is visible.
- Provider retention and training: shipment is blocked until the applicable Ark
  endpoint policy is linked and states retention duration and training use. The
  app must not claim zero retention without that evidence.
- Local storage: image buffers, raw output, lineage, candidates, and results stay
  in memory. Use an ephemeral network session with URL caching disabled. Do not
  create temporary image files.
- Diagnostics: record only random request ID, model ID, schema hash, candidate
  count, latency, byte count, HTTP status, and coarse error category. Never log
  pixels, crops, raw text, extracted fields, normalized values, prompts, profile
  content, or coffee identifiers.
- Crash reporting and analytics must receive no image, OCR, candidate, or profile
  payload. Network response bodies must not appear in error descriptions.
- Cancellation cancels the client task and releases local buffers. It cannot
  promise deletion of data already accepted by the provider; the disclosure says
  so and refers to the verified provider policy.
- The bundled profile is local-only, aggregate-only, hash-bound, and contains no
  observation rows, notes, dates, brew details, or coffee identities. Because
  roaster aggregates can reveal small-cell history, the first-release artifact
  removes roaster statistics and marks roaster affinity unavailable. Reintroducing
  them requires a separate privacy and scoring gate.

## Canonical Profile And Build Contract

There is one generated artifact,
`Sources/CoffeeJournalApp/Resources/TasteProfile/profile-prior.json`, created by
the repository exporter from the current curated private dataset. It contains
`dataset_generated_at`, `profile_id`, `scorer_version`, `lexicon_version`, and
the exact aggregate score contract. The exporter also generates:

- Swift profile display data, replacing hand-maintained
  `PersonalTasteProfile` constants;
- a Swift scorer contract rather than copied constants;
- language-neutral parity fixtures and expected result hashes; and
- a manifest binding every generated file by SHA-256.

Build validation fails when any generated artifact, display summary, scorer,
fixture, manifest hash, or embedded profile ID disagrees. A profile refresh is
one atomic exporter operation. It never chooses among the existing 50-, 51-, or
53-rating snapshots by hand. No implementation may start until a fresh export
has produced one internally consistent version and its separate profile/scorer
gate has approved it.

## Preregistered Evaluation Plan

No result from this feature may be inspected before the following versioned
manifest, labels, split, metrics, and thresholds are committed under
`eval/coffee_bag_purchase_scan/v1/` and hashed in the extraction-prompt/model
preregistration.

### Dataset And Split

- 24 source-image sessions and an expected 48-72 package entities.
- 8 single-package sessions, 8 sessions with 2-4 packages in one image, 4
  front/back multi-image sessions, and 4 online-shop screenshot sessions.
- Language strata: 12 English, 8 Chinese, and 4 bilingual sessions.
- Condition tags include glare, oblique angle, occlusion, small text, unrelated
  products, duplicate packages across images, and instruction-like package text.
- Freeze 16 development sessions and seal 8 holdout sessions before prompt or
  model comparison. The holdout images and labels are unavailable to prompt
  authors until the candidate prompt/model pair is frozen.
- Use only licensed, synthetic, or explicitly consented non-private images.

### Annotation Rubric

Two annotators independently label package count, package regions, duplicate
entity relationships, raw visible field strings, field-to-region provenance,
and missing/not-visible states. Disagreements are adjudicated by a third human
without model output. Normalized scorer values are produced by the frozen
deterministic normalizer, never by the extraction model or judge.

### Unweighted Metrics And Pass Thresholds

Report every session and field equally before any stratified or weighted view:

- package-entity precision and recall: each `>= 0.95` overall;
- exact package count: `>= 22/24` sessions and `8/8` sealed holdouts;
- critical raw-field macro F1 across roaster, name, origin, process, and visible
  descriptors: `>= 0.90` overall and `>= 0.85` in every language stratum;
- hallucinated critical fields marked Ready: `0`;
- incorrect automatic duplicate merges: `0`;
- field-to-source-region provenance accuracy: `>= 0.95`;
- median user corrections: `<= 1` critical field per candidate, with p90 `<= 3`;
- scorable false inclusion for missing, conflicted, or unconfirmed inputs: `0`;
- Python/Swift Fit, Novelty, role, and ordering parity: exact on every fixture;
- privacy audit leakage into caches, temporary files, logs, analytics, or crash
  payloads: `0` bytes of prohibited content across every test scenario;
- task completion: `5/5` scripted device scenarios without researcher help;
- VoiceOver focus order, largest Dynamic Type, long bilingual names, and 44-point
  target checklist: `100%` pass.

Do not compute a custom weighted headline metric for adoption. Report strata
after the unweighted results. A failed threshold blocks shipment; it is not
averaged against stronger metrics.

### Holdout And Leakage Rules

Prompt examples, normalization lexicon, model selection, threshold changes, and
error analysis may use only development sessions. The sealed holdout is opened
once for the preregistered candidate. A failed holdout creates a new version and
new sealed data; it does not become another tuning pass. Model self-evaluation,
scorer output, and generated labels are never ground truth.

Prospective purchase usefulness and post-tasting satisfaction are separate
studies. Until they pass their own preregistered review, the product claims only
deterministic relative ordering against a personal aggregate snapshot.

## Gate Dependency Ledger

Explorer Workbench product-design approval does not approve shipment. Before
implementation or adoption of each dependent decision, run a separate protocol
v4 gate with frozen inputs and acceptance criteria:

1. multi-package extraction schema and prompt;
2. extraction model/provider choice and the provider privacy policy;
3. scorable predicate, missing-evidence behavior, and Swift/Python scorer parity;
4. `60.0` Fit, familiar-bridge, `1.5` near-tie, and frontier blend thresholds;
5. deterministic explanation templates or a narrative prompt, whichever is
   proposed;
6. extraction dataset, annotation rubric, holdout split, unweighted metrics, and
   pass thresholds before results are inspected;
7. any predictive-validity, purchase-confidence, or post-tasting claim.

The feature cannot ship while any applicable gate is blocked, conditional,
malformed, or absent.

## First Review Remediation Matrix

The initial 2026-09-03 protocol-v4 review returned `DO NOT APPROVE`. Its ten
conditions are addressed as follows:

1. scorable predicate -> `Frozen Scorable And Ranking Contract`;
2. distinct Frontier and familiar bridge -> `Frontier Pick`;
3. near ties, collisions, and fallback -> `Near Ties And Role Collisions`;
4. raw, normalized, edit, merge, and deletion lineage ->
   `Immutable In-Session Lineage`;
5. background, crash, cancellation, retry, and dismissal ->
   `Ephemeral Session Lifecycle`;
6. payload, service, retention, training, caches, logs, cancellation, and
   profile artifacts -> `Product Privacy Contract`;
7. 50/51/53-rating inconsistency -> `Canonical Profile And Build Contract`;
8. misleading Safe label -> `Best-Supported Match` with non-guarantee copy;
9. datasets, rubrics, metrics, holdouts, and thresholds ->
   `Preregistered Evaluation Plan`;
10. dependent review gates -> `Gate Dependency Ledger`.

## Current Evidence And Metrics

Unweighted evidence first:

- The 2026-07-25 tracked review packet reported 62 unit tests passing.
- It reported exact portable/private profile-component parity across 20
  candidates: maximum absolute Fit delta `0.0` and Novelty delta `0.0`.
- The earlier five-pair development set reported raw unweighted pairwise
  accuracy `0.600`; it is not a general accuracy estimate.

Custom or weighted evidence:

- The same development set reported learnability-weighted pairwise accuracy
  `0.800`, with high-learnability `3/3`, medium `0/1`, and low `0/1`.
- These historical metrics were not rerun for this product-design review and
  do not validate the multi-image extraction flow.

There is a current profile-version inconsistency that must be resolved before
implementation acceptance:

- the installed portable skill snapshot says 2026-07-21 with 50 ratings;
- the current app's `PersonalTasteProfile` says 2026-08-02 with 53 ratings;
- the 2026-07-25 portable scorer review packet refers to a 51-rating snapshot.

The design therefore requires a fresh canonical export rather than choosing any
of these snapshots by hand.

## Alternatives Considered

### A. Lightweight Compare Sheet

Put Compare in the Taste toolbar, extend extraction to arrays, manually port the
scorer to Swift, and present a simple list and ranking. This ships fastest but
weakens the exploration entry and makes Python/Swift score drift likely.

### B. Explorer Workbench

Use the three-stage flow described above, an ephemeral candidate session with
field provenance, and generated Python/Swift scoring artifacts with shared
fixtures. This is the proposed decision.

### C. Explorer Lens

Overlay live package boxes and recommendation hints on the camera view. This is
visually distinctive but depends on real-time package grouping, small-text
recognition, and overlay accessibility before the decision logic is proven.
It is deferred as a possible later input mode.

## Constraints

- Personal iOS app; no new backend or account system.
- Existing Ark credentials and network extraction path may be reused, but no
  model/provider choice is approved by this review.
- No persistent wishlist, purchase button, catalog, or fourth tab.
- Existing journal data and dirty worktree changes must be preserved.
- The implementation must use the repository-native score scale and output Fit
  and Novelty together.
- The middle of the ranking is unstable on sparse, self-selected evidence.
- Sol Max protocol v4 blocks conditional or rejected decisions.

## Leakage Boundaries

This review packet contains product design, tracked aggregate metrics, and
public source code only. It contains no raw observations, coffee history rows,
private notes, candidate photos, screenshots, user identifiers, dates of
individual tastings, or brew details. The visual mockup is not sent as a review
input because the current review runner accepts UTF-8 text files only; this
screen specification is the reviewable representation.

For the product itself, imported photos may contain unrelated shelf or screen
content. The design must crop or minimize payloads where practical, disclose
network processing, avoid persistent storage, and keep raw image content out of
logs and diagnostics.

## Known Unknowns

- Accuracy of grouping multiple packages from one real shelf photo.
- Whether front-only photos contain enough fields for useful scoring.
- Latency and cost for 1-5 images and 2-8 candidates.
- Whether Chinese and English packaging can share one extraction prompt without
  recall loss or normalization changing score-triggering descriptors.
- Exact threshold for a candidate to be scorable.
- Exact near-tie display threshold.
- Whether deterministic explanations can cover the first release or a separate
  constrained narrative prompt is required.
- How the canonical current profile is refreshed and bundled into signed app
  builds without exposing raw personal history.

## Required Experiments Before Shipment

1. Build a representative, non-private package-image fixture set covering one
   bag, multiple bags, front/back pairs, screenshots, glare, occlusion, Chinese,
   English, duplicates, and unrelated products.
2. Define field-level expected labels and report unweighted package grouping,
   candidate count, and field extraction results before any weighted summary.
3. Generate Swift parity fixtures from a freshly exported profile and require
   exact Fit, Novelty, Best-Supported Match, Frontier Pick, and
   version-mismatch parity
   with the Python reference.
4. Run device usability checks for the 2-candidate happy path, partial extraction,
   all-insufficient input, retry, cancellation, and VoiceOver.
5. Run a separate preregistered Sol Max review for any new extraction prompt,
   score-contract change, narrative prompt, threshold, or evaluation conclusion.
