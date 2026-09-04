# Sol Max Review Packet: Bean Explorer Continuous Flow

## Proposed Decision

Replace the three-step Collect/Review/Explore prototype UI with one continuous
screen. Selecting or taking a photo starts extraction immediately. Candidates
with complete evidence and no parser-declared uncertainty are accepted by the
UI without a confirmation tap. Once two candidates satisfy the frozen scorer,
the comparison appears automatically below them.

This packet supersedes interaction-specific confirmation and step-navigation
language in the earlier Bean Explorer packets. It does not change the frozen
extraction prompt/parser, profile, scoring weights, thresholds, or role rules.

## Acceptance Criteria Written Before Review

Approve only if all of the following hold:

1. Photo selection is sufficient intent to process the photo; there is no
   additional provider confirmation dialog or manual Scan button.
2. The screen contains no Collect/Review/Explore switcher, prototype banner,
   Review Candidates button, See Recommendations button, or Ark-branded status.
3. Complete, evidence-backed, non-uncertain extraction output is trusted by
   default. Parser-declared uncertainty is not cleared automatically.
4. A candidate that cannot enter scoring is visibly marked `Check details` and
   remains editable; no missing or uncertain field receives a neutral score.
5. Comparison starts automatically only after at least two candidates pass the
   existing scorer eligibility checks.
6. The best-supported result is visually primary, the exploration alternative
   is secondary, and both retain Fit/Novelty caveats.
7. Photos and candidates remain ephemeral and do not mutate Beans or history.
8. Provider processing is disclosed inline without making internal provider
   naming or retention prose the dominant interaction.

Any conditional or rejected verdict blocks personal-device adoption under
protocol v4.

## Evidence And Exact Implementation

- User screenshots showed three competing navigation pills, separate Camera,
  Photos, manual-entry, Scan Packages, Review Candidates, Edit, Confirm,
  Remove, Add another source, and See Comparison actions.
- Every extracted candidate displayed `Needs review`, so the primary path could
  not reach comparison without repeated confirmation taps.
- `Sources/CoffeeJournalApp/BeanExplorerView.swift` now renders one scrollable
  flow: short purpose statement, one primary photo action plus camera shortcut,
  compact source thumbnails, progress, compact editable candidate cards, then
  the automatic comparison.
- A long press on a source exposes retry/removal; a candidate card opens edit,
  and its overflow menu exposes edit/removal. These are recovery actions rather
  than primary-path buttons.
- The UI calls the existing fail-closed `confirmCandidate` method automatically.
  That method rejects any candidate whose parser uncertainty is nonempty or
  whose populated fields lack provenance. The scorer independently requires
  roaster, full name, origin, process, a recognized flavor family, confirmed
  scorer fields, provenance, and no unresolved fields.
- The existing extraction prompt/parser lineage hashes remain unchanged.

## Unweighted Verification

- Swift Package tests: `53/53` pass.
- Full iOS simulator suite: `59/59` pass.
- Python scorer and pipeline tests: `49/49` pass.
- `git diff --check`: required before review.

There is no custom weighted headline metric.

## Alternatives Rejected

- Preserve explicit confirmation for every candidate: rejected because it
  makes the common successful parse look like an error state and blocks the
  user from reaching the decision they requested.
- Hide all edit and uncertainty affordances: rejected because extraction can be
  incomplete and the scorer must continue to fail closed.
- Keep the provider dialog but show it only once: rejected because selecting a
  photo already expresses the processing intent in this private app, while a
  concise inline disclosure keeps the boundary visible without interrupting.
- Automatically fabricate missing fields: rejected because it would turn
  uncertainty into false evidence and contaminate the recommendation.

## Known Unknowns And Non-Claims

- This is a personal-device interaction revision, not evidence of extraction
  accuracy, predictive purchase utility, App Store readiness, or provider
  retention policy.
- Real-device visual QA, Dynamic Type, and VoiceOver traversal remain required
  after the review gate.
- Fit is a relative ordering signal derived from a self-selected 53-rating
  snapshot, not a liking probability or a lower preference bound.
