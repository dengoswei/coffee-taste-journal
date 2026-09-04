# Sol Max Review Packet: Bean Explorer Deterministic Scoring Prototype

## Proposed Decision

Adopt the current Swift implementation for the personal-device Bean Explorer
prototype. The newer continuous-flow packet supersedes the manual-confirmation
interaction described by earlier packets: the UI accepts evidence-backed,
non-uncertain extraction output through the existing fail-closed confirmation
method. After at least two candidates satisfy scorer eligibility, the app loads
one manifest-bound aggregate profile, computes deterministic Fit and Novelty
locally, and shows a distinct nullable Frontier Pick plus a Best-Supported Match.

This decision does not approve distribution, extraction reliability,
predictive recommendation accuracy, calibrated likelihood, provider-policy
claims, or automatic purchase actions.

## Acceptance Criteria Written Before Review

Approve only if all of the following hold:

1. Ark extracts package text only and cannot set scores, roles, thresholds, or
   explanations.
2. Unconfirmed, uncertain, or incomplete candidates are excluded with a reason;
   missing inputs never receive neutral Fit or inflated Novelty.
3. Swift matches the frozen Python profile scorer exactly for every committed
   parity fixture.
4. Best-Supported Match is the highest Fit candidate with deterministic
   tie-breaks. Frontier Pick is distinct, Fit >= 60, and has a flavor-family
   bridge with Loved count >= 3 and category observations >= 6.
5. The resource manifest binds profile, scorer, and lexicon identifiers and the
   app fails closed on an integrity mismatch.
6. No raw observations, coffee identities, notes, dates, brew details, or
   small-cell roaster statistics enter the app resource.
7. UI copy states that Fit is a relative ordering signal, seller notes are
   claims, direct history is unavailable, and the self-selected profile cannot
   establish a lower preference bound.
8. The flow stays ephemeral and does not mutate Beans, ratings, evaluation
   cases, or recommendation history.

Any conditional or rejected verdict blocks adoption under protocol v4.

## Frozen Inputs And Identifiers

- Aggregate dataset timestamp: `2026-08-02T14:14:27.021210+00:00`.
- Rated observations: `53`.
- Profile ID:
  `0baa7bac874e6da3365bdf9778dd760e154f34bf42b2089b5b2ac291c8f9c54d`.
- Scorer version:
  `0e445b82063751dcecf40beb35d39255a7f219c6b0a00bd0bb1a67aff5a88bd4`.
- Fit weights: sensory `0.75`, origin `0.15`, process `0.10`.
- Novelty weights: flavor-family familiarity `0.50`, origin `0.25`, process
  `0.25`, inverted to `0-100`.
- Frontier gate: Fit `60.0`; blend Novelty `0.55`, Fit `0.45`.
- Near-tie display: absolute Fit delta `<= 1.5`.
- Familiar bridge: `top_tier_count >= 3` and category observations `>= 6`.
- Labels: `Fit`, `Novelty`, `Frontier Pick`, `Best-Supported Match`,
  `Relative ranking`, and `Similar Fit`.

The generated profile JSON is the runtime score contract; Swift decodes its
weights and vocabulary instead of copying them. The generated manifest binds
the JSON SHA-256 and identifiers. Roaster statistics are exported as an empty
array, making roaster affinity unavailable rather than silently zero-valued
personal history.

## Evaluator Source And Current Results

Reference scorer: `scripts/portable_coffee_rank.py`.

Swift scorer: `Sources/CoffeeJournalCore/BeanExplorerScoring.swift`.

Unweighted results first:

- Python/Swift parity: `3/3` fixed candidates exact for Fit and Novelty, with
  one shared generated document consumed by Swift tests.
- Shared contract cases: `2/2` comparison scenarios, `5/5` eligibility states,
  `4/4` normalization cases, `4/4` rounding cases, `1/1` non-chaining Similar
  Fit scenario, `4/4` bridge-boundary cases, and `4/4` role/tie cases.
- Scorable false inclusion unit cases: `0/4` invalid states.
- Frontier role rule unit cases: `2/2` (distinct bridge-qualified selection and
  null when no candidate has a bridge).
- Resource integrity: bundled load `1/1`, per-artifact tamper rejection `3/3`,
  and Python/Swift source binding `2/2`.
- Swift Package tests: `53/53` pass.
- Full iOS simulator suite: `59/59` pass (`6` app-hosted and `53` Core).
- Python scorer/pipeline tests: `49/49` pass.

There is no custom weighted headline metric.

## Alternatives Considered

- Ask Ark to recommend or emit scores: rejected because it breaks score
  determinism, provenance, and the extraction/scoring boundary.
- Call a Python or remote scoring service: rejected for a personal-device flow
  because it adds data transfer and availability failure without improving the
  frozen score.
- Recompute a live profile from the on-device store: deferred because it would
  create a second unreviewed profile builder and omit curated non-app evidence.
- Include roaster aggregates: rejected for the first prototype because
  low-count roaster cells can reveal personal history.

## Leakage Boundaries

Only derived aggregate statistics and matching vocabularies are embedded. The
review inputs exclude `private/`, device store exports, raw observations,
coffee identities, notes, timestamps, brew records, and generated review
artifacts. Candidate photos remain session-memory inputs to the separately
reviewed extraction path and are not scorer inputs.

## Known Unknowns

- Three parity fixtures are a smoke test, not broad proof across every Unicode
  normalization and word-boundary edge case.
- The August 2 profile can lag newer tastings until an explicit curated export.
- Fit and Novelty are heuristic ordering signals, not probabilities or proven
  purchase utility.
- Device interaction, Dynamic Type, VoiceOver, and real multi-package accuracy
  remain outside this scorer adoption decision.

## Remediation After The First Scorer Review

The first protocol-v4 review returned `DO NOT APPROVE`. Its five conditions are
treated as blocking and remediated as follows:

1. Python and Swift now share one versioned contract for NFKC plus lowercase
   normalization, ASCII boundaries, binary64 half-away rounding, Fit/Novelty/ID
   ranking, familiar bridges, nullable distinct Frontier, and non-chaining fit
   bands. Swift consumes the exact generated Python fixture document.
2. Candidates carry field-level provenance and confirmed-field sets. Blanket
   confirmation no longer clears uncertainty; it fails until the user edits
   each unresolved field, and editing invalidates prior confirmation.
3. A generated compiled Swift contract anchors the manifest, profile, fixture,
   Python source, and Swift source hashes. Runtime validates every
   manifest-listed resource; build tests recompute both source hashes; profile
   validation rejects private/history flags, nonempty roaster cells, duplicate
   normalized statistics, and changed role thresholds.
4. The separately approved exact Ark prompt and parser are now included in the
   review inputs. Exact-shape parser tests reject injected recommendation fields
   at the envelope and coffee-field levels; all extracted candidates remain
   unconfirmed and score inputs require field provenance.
5. Similar Fit is a deterministic non-chaining band anchored to the highest Fit
   in each band. The UI renders one label per multi-item band, and the shared
   fixture exercises the ambiguous `80, 79, 78, 76.5` chain.

The novelty explanation now says a dimension is absent or sparse in this
snapshot; it does not call the user's experience unfamiliar.

## Remediation After The Second Scorer Review

The second protocol-v4 review also returned `DO NOT APPROVE`. Its four
remaining conditions are treated as blocking and remediated as follows:

1. Python and Swift now apply the same eligibility predicate before comparison,
   and both produce the full ranked result, Best-Supported Match, nullable
   distinct Frontier Pick, Similar Fit bands, and bridge decision.
2. The single generated fixture document now covers positive and null Frontier
   cases, exact bridge boundaries, non-chaining bands, eligibility states,
   deterministic role ties, normalization, and binary64 rounding.
3. Python normalization now uses NFKC plus Unicode lowercase to match Swift;
   both implementations use the same binary64 half-away rounding rule. Contract
   metadata no longer claims casefold or decimal arithmetic.
4. The Ark extraction contract has an independently frozen prompt SHA and
   parser-source SHA. Runtime rejects an extraction whose prompt lineage differs,
   and tests bind both the live prompt and parser source to those fixed hashes.
