# Personal Coffee Taste Profile and Recommendation

## Objective

Build a long-lived personal system that can:

1. describe a person's coffee taste without confusing seller claims with
   first-person perception;
2. rank new coffees into a high-confidence match and a bounded exploration pick;
3. evaluate prompt and pipeline changes on leakage-safe historical holdouts;
4. improve after every purchased bag without committing private notes to Git.

This is an initial local pipeline and evaluation framework. It is not yet wired
into the SwiftUI product screens.

## Method

The data contract follows the separation used by the SCA Coffee Value
Assessment:

- **Descriptive:** sensory attributes and cup structure.
- **Affective:** the person's rating or liking.
- **Extrinsic:** origin, variety, process, producer, and roaster.
- **Context:** recipe, rest, temperature, repeat brews, and evidence quality.

References:

- [SCA Coffee Value Assessment](https://sca.coffee/value-assessment)
- [SCA Coffee Standards](https://sca.coffee/research/coffee-standards)
- [World Coffee Research Sensory Lexicon](https://worldcoffeeresearch.org/read-more/news/174-world-coffee-research-sensory-lexicon)

The WCR lexicon informs broad reusable sensory families, but this pipeline does
not pretend that sparse personal notes support all 110 lexicon attributes or
0-15 intensity estimates.

## Privacy Boundary

Tracked:

- `prompts/coffee_profile_v0.md`
- `prompts/coffee_profile_v1.md`
- `prompts/coffee_recommend_v0.md`
- `prompts/coffee_recommend_v1.md`
- `eval/coffee_taste/eval_cases.example.json`
- `eval/coffee_taste/live_candidates.example.json`
- `eval/coffee_taste/evaluation_summary_20260717.md` (aggregate metrics only)
- pipeline code, documentation, and synthetic tests

Ignored and local-only:

- `backups/`: exported iPhone app container
- `backups/flomo/<timestamp>/`: complete raw Flomo corpus, media, and checksums
- `private/coffee_taste/flomo_observations.json`: curated private observations
- `private/coffee_taste/dataset.json`: normalized personal history
- `private/coffee_taste/eval_cases.json`: personal holdout labels
- `private/coffee_taste/live_candidates.json`: personal shortlist and overlap notes
- `private/coffee_taste/current_*.json` and the private Markdown report
- `.generated/coffee_taste_eval/`: prompts, raw model output, and run metrics

The builder does not include the raw Flomo memo corpus. It consumes a curated
local observation file so duplicate handling and provenance remain explicit.
Before updating that curated file, run `python3 scripts/backup_flomo.py`. The
backup script follows every API page, requires unique memo slugs, downloads
each original file plus its thumbnail when available, and only publishes the
timestamped directory after all artifacts succeed. Its `manifest.json` records
counts and time bounds, while `SHA256SUMS` supports later integrity checks.
The backup represents every current memo returned by the authenticated Flomo
API. Deleted items that the service no longer returns cannot be reconstructed
by this snapshot.

## Pipeline

### 1. Normalize Evidence

`scripts/build_coffee_taste_dataset.py` joins the app export and curated Flomo
observations, deduplicates known repeats, and separates:

- explicit ratings;
- seller or mixed-source flavor descriptors;
- first-person cup-structure signals;
- seller-claimed quality signals;
- brew context and limitations.

English lexicon terms use token boundaries. For example, `pineapple` is tropical
fruit and does not also become `apple`/pome fruit.

### 2. Build a Deterministic Profile Contract

The v1 profile pipeline allows "known preferences" only when supported by
substantive first-person notes. Flavor families inferred mostly from bag or
mixed-source descriptors stay in `likely_preferences`. Axes without direct
cup evidence remain unknown.

The language model may organize the narrative, but code grounds the final
profile axes, known/likely/unknown split, evidence IDs, and exact data counts.

### 3. Recommend Two Different Roles

The recommendation contract produces:

- `safe_match`: highest evidence-backed expected fit;
- `frontier_pick`: a different roaster, a credible familiar bridge, and one or
  two meaningful novel dimensions.

The current live-candidate path combines:

- a hard availability filter before any candidate reaches the model;
- sensory-family rating correlations;
- a capped bonus for seller-claimed structure;
- direct name/station overlap with prior rated coffees;
- candidate analogs against similar high and lower-rated historical profiles;
- deterministic validation for IDs, complete ranking, distinct roles, and
  cross-roaster ordering.

Origin, variety, process, and roaster may explain novelty or risk. They are not
allowed to become causal taste preferences.

### 4. Ground Model Output

Raw model output is preserved for prompt evaluation. The v1 pipeline then:

- filters invalid evidence IDs;
- generates conservative reasons from actual candidate fields;
- prevents "missing fermentation words means clean" reasoning;
- avoids unsupported roast, body, acidity, or variety claims;
- fills every ranking candidate exactly once;
- enforces safe/frontier role constraints.

This separation matters because a structurally valid model response can still
contain unsupported sensory reasoning.

## Evaluation Design

### Independent Sol Max Review Gate

Every substantive prompt, judge, metric, recommendation, or taste-design
decision receives an independent review from `gpt-5.6-sol` at maximum reasoning
effort before it is treated as decision-ready. The review packet must include
the proposal, evidence, alternatives, leakage boundaries, current metrics, and
unknowns.

```bash
python3 scripts/consult_sol_max.py \
  --prepare \
  --topic prompt-and-judge-design \
  --scope "adopt prompt v1 as the internal regression baseline" \
  --question "Review whether v1 is a defensible baseline and identify the next decisive experiments." \
  --acceptance-criteria "Approve only as an internal regression baseline; reject calibrated accuracy or validated taste claims without sealed and prospective evidence." \
  --input prompts/coffee_profile_v1.md \
  --input prompts/coffee_recommend_v1.md \
  --input docs/coffee-taste-profile-and-recommendation.md \
  --input eval/coffee_taste/evaluation_summary_20260717.md

python3 scripts/consult_sol_max.py \
  --preregistration .generated/sol-max-preregistrations/<review>.json \
  --preregistration-sha256 <sha-from-prepare>

python3 scripts/verify_sol_max_gate.py \
  .generated/sol-max-reviews/<review>.gate.json \
  --scope "adopt prompt v1 as the internal regression baseline"
```

The two-phase flow timestamps and hashes the scope, criteria, inputs, protocol
specification, and runner/verifier implementation before review. The runner
validates the response structure and emits a machine-readable gate.
Non-approval is blocking and has no automated override; remediate and run a new
review. Claims must be checked against repository evidence, and accepted,
rejected, and deferred recommendations are recorded in
`docs/sol-max-review-decisions.md`. Prompt comparisons should be blinded. The
default packet excludes raw personal data and generated raw outputs:
`private/`, `backups/`, and all `.generated/` files require an explicit
`--allow-private` override in both phases. Reviewable aggregate metrics live in
tracked `eval/coffee_taste/evaluation_summary_20260717.md`.

### Leakage-Safe Pairwise Holdouts

Each case removes both candidate entities from profile-building history. The
model sees candidate metadata and descriptors, but not either held-out rating.
Live purchase candidates are report-only and never provide tuning labels.

Personal cases are classified by learnability:

- **High:** training history contains usable positive and lower-rated contrasts.
- **Medium:** some related evidence exists, but the exact combination is sparse.
- **Low:** the decisive personal observation belongs to the held-out candidate
  itself and cannot be reconstructed from training history.

This prevents a cold-start surprise from being treated as an ordinary ranking
bug.

### Metrics

- profile schema and evidence-reference accuracy;
- known-preference scope and calibrated unknowns;
- raw and grounded pairwise accuracy;
- learnability-weighted and unweighted accuracy;
- ranking completeness and valid candidate IDs;
- cross-roaster role separation;
- safe-highest-fit and frontier-more-novel constraints;
- deterministic semantic guardrails;
- post-purchase surprise and repeat-purchase feedback, once available.

Recommendation evaluation should include accuracy, diversity, novelty, and
serendipity rather than accuracy alone:

- [Values of Exploration in Recommender Systems](https://research.google/pubs/values-of-exploration-in-recommender-systems/)
- [Unified Accuracy and Diversity Metrics](https://research.google/pubs/towards-unified-metrics-for-accuracy-and-diversity-for-recommender-systems/)

### Prompt Iteration

Run `.generated/coffee_taste_eval/20260717-010156` contains the same five
holdout pairs for both versions. Because these results informed prompt
selection, the five pairs are now a development/regression set rather than an
untouched test set. Its cached raw model outputs were re-scored with the final
evaluator:

| Version | Pipeline | Raw prompt | Profile | Weighted pairwise | Recommendation contract | Evidence refs |
|---|---:|---:|---:|---:|---:|---:|
| v0 | `0.828` | `0.828` | `0.859` | `0.733` | `0.879` | `0.917` |
| v1 | `0.924` | `0.909` | `1.000` | `0.800` | `0.970` | `1.000` |

The v1 contract and grounding improved evidence discipline and all three
high-learnability cases. It still missed the one medium and one low
learnability case. The result identifies both data gaps and possible model
failures; the current evidence cannot separate them. It is not evidence of
general 80% recommendation accuracy.

### v1 Engineering Baseline

Run: `.generated/coffee_taste_eval/20260717-012127`

- Model: `doubao-seed-1-6-flash-250828`, thinking disabled
- Profile score: `1.000`
- Evidence-reference accuracy: `1.000`
- Recommendation contract score: `0.970`
- Pairwise accuracy, learnability-weighted: `0.800`
- Pairwise accuracy, unweighted: `0.600`
- High-learnability core: `3/3`
- Medium challenge: `0/1`
- Low challenge: `0/1`

The result is intentionally not presented as general recommendation accuracy.
The personal development set has only five pairs and three substantive
first-person notes. Contract and evidence-reference scores primarily validate
pipeline conformance because the deterministic contract and grounding logic
also define many judged properties. The high-learnability core is useful for
regression detection; it does not validate calibrated recommendation quality.

The `60` frontier threshold, different-roaster constraint, numeric fit scores,
and expected-liking scores are uncalibrated product heuristics. They remain
hypotheses until prospective safe/frontier outcomes are collected.

### 2026-07-19 Pipeline Changes (pending Sol Max R1/R2)

The following changes are implemented and unit-tested but their new evaluation
numbers are **pending Sol Max review**; the historical numbers above were
produced by the earlier tautological contract scorer and are superseded as
comparison baselines once a re-run lands.

- **Non-tautological contract scoring.** `ground_recommendation` used to force
  `safe_fit = max_other_fit + 0.1` and `frontier_novelty = safe_novelty + 5`,
  and `score_recommendation` then verified those same forced numbers. The scorer
  now takes an `ordering_source` (the raw model output) so `safe_highest_fit`
  and `frontier_more_novel` grade the model's own ordering discipline; grounded
  output additionally records `grounding_adjustments`. Expect the contract score
  to drop from `0.970` on re-run — that drop is the correction, not a
  regression.
- **Single-source thresholds.** `FRONTIER_MIN_FIT = 60` now gates both the
  live-shortlist novelty pool (previously 55) and grounded frontier
  eligibility. `NARRATIVE_LENGTH_RANGE = (90, 180)` aligns the profile scorer
  with the prompt spec (previously 45-260), and every fallback-template branch
  combination satisfies it.
- **Dedupe observability.** `dataset.stats.collapsed_duplicates` reports
  observation-level dedupe on every build; `APP_DEDUPE_OVERRIDES` enables
  app-to-Flomo cross-source collapsing, which previously could never happen.
  Unmapped app verdict labels now degrade to unrated observations instead of
  crashing the build.
- **CJK matching.** `normalized_key` now applies NFKC (shared with the dataset
  builder), and identity matching accepts two-hanzi tokens with a CJK stop-word
  list, so Chinese coffee names can hit direct history matches.
- **Honest reporting.** The summary table now renders weighted AND unweighted
  pairwise accuracy plus a raw unweighted column, and eval cases may set
  `"regression_watch": true` to surface themselves in a dedicated "Tracked
  Challenge Cases" section (the medium Yemen-vs-Tabi and low Radiance cases are
  so flagged in the private set).
- **Top-tier rating concentration (user-requested).** The user rarely writes
  tasting notes, so Great/Loved tier concentration is now a first-class signal:
  `top_tier_family_stats` reports families appearing in >=2 top-tier coffees,
  `build_profile_contract` emits `top_tier_signals` statements into
  likely_preferences (still not "known" — descriptors remain mostly seller or
  mixed-source claims), the narrative validator accepts those families, and
  `candidate_prior` adds a capped `top_tier_affinity_bonus` (2.5 per shared
  family, max 5.0, uncalibrated like the other bonuses).
- **v2 narrative pipeline.** `prompts/coffee_profile_v2.md` keeps the
  model-authored summary verbatim when `validate_model_narrative` passes
  (length, absolute claims, extrinsic terms, unhedged undersampled dimensions,
  invented flavor families, confidence clamp); otherwise it falls back to the
  template and records `narrative_violations`. `summary_source` and
  `narrative_model_kept_rate` make adoption measurable.

**v2 adoption rule:** `PRODUCT_VERSION` switches from `v1` to `v2` only when a
re-run shows v2 pairwise accuracy (weighted and unweighted) at or above v1 with
no tracked-challenge-case regression, and Sol Max review R2 approves.

The availability-only purchase refresh is stored at
`.generated/coffee_taste_eval/20260717-current-final`. It intentionally runs
zero holdout pairs, so its displayed pairwise value is not an accuracy result.
Its current recommendation contract and evidence-reference scores are both
`1.000`.

## Reproduction

Provide Ark credentials through the environment or local `config.json`
(gitignored). Keep personal datasets and live shortlists under `private/`.

```bash
cp eval/coffee_taste/eval_cases.example.json private/coffee_taste/eval_cases.json
cp eval/coffee_taste/live_candidates.example.json private/coffee_taste/live_candidates.json

python3 scripts/build_coffee_taste_dataset.py

python3 scripts/evaluate_coffee_taste_prompts.py \
  --versions v1 \
  --max-cases 5 \
  --thinking disabled

python3 -m unittest discover -s Tests -p 'test_*.py'
```

Every run stores rendered prompts, raw responses, grounded outputs, scores, and
a Markdown summary under `.generated/coffee_taste_eval/<timestamp>/`.

## Feedback Required in the App

For each recommended coffee, collect:

- actual verdict;
- perceived flavor families;
- clarity and acid-sweet balance;
- intrusive fermentation: yes/no/uncertain;
- hot versus cool-cup evolution;
- surprise score;
- repurchase intent;
- mismatch cause: coffee, roast/rest, recipe, or expectation.

The next evaluation set should be created from these prospective outcomes, not
from repeated tuning on the current five historical pairs.
