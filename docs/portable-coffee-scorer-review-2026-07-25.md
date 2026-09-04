# Portable Coffee Scorer Review Packet

## Proposed decision

Adopt a two-mode recommendation contract:

- `private_full` uses the journal observations and reports profile scores plus
  an explicit direct-history adjustment.
- `portable_profile` uses only exported aggregate sufficient statistics and the
  same deterministic profile scorer. Direct history is unavailable, not zero.

## Acceptance criteria

Approve only if all of the following hold:

1. The portable export contains no observation rows, coffee identities, source
   references, notes, dates, brew context, or provenance references.
2. It contains enough aggregate statistics and exact configuration to reproduce
   the journal's `profile_fit_score` and `profile_novelty_score`.
3. The portable output never presents profile-only Fit as the private
   personalized score and exposes history as unavailable.
4. Existing private `fit_score` and `novelty_score` behavior remains unchanged.
5. The scorer and profile are SHA-256 bound and reject tampering or version
   mismatch.
6. The claim remains limited to deterministic parity with the internal
   heuristic. It makes no claim of calibrated liking probability or validated
   recommendation accuracy.

## Frozen implementation

- Private scorer: `scripts/evaluate_coffee_taste_prompts.py`
- Portable scorer and aggregate contract: `scripts/portable_coffee_rank.py`
- Exporter and generated skill instructions:
  `.claude/skills/coffee-taste/scripts/export_portable_skill.py`
- Private CLI explanation fields:
  `.claude/skills/coffee-taste/scripts/recommend.py`
- Tests: `Tests/test_coffee_taste_pipeline.py` and
  `Tests/test_portable_coffee_rank.py`

## Current unweighted verification

- 62 unit tests pass.
- Python bytecode compilation passes for all changed Python files.
- On the current 51-rating aggregate snapshot and 20 distinct candidates,
  portable versus private profile-component parity is exact:
  - maximum absolute `profile_fit_score` delta: `0.0`
  - maximum absolute `profile_novelty_score` delta: `0.0`
- Portable safe/frontier identities match the private profile-only components:
  FriedHats Las Margaritas Sudan Rume Washed and Tanat Alo Mosto Anaerobic
  Natural.
- Private personalized output still separates, for example, FriedHats Las
  Margaritas Sudan Rume Washed into profile Fit `78.1` plus history `18.0` for
  final Fit `96.1`.

## Exported data boundary

Included:

- full flavor-family, origin, process, and roaster aggregate counts and weighted
  ratings;
- Loved-tier family counts;
- rating distribution;
- exact lexicon, weights, bonus caps, novelty parameters, and frontier gate;
- profile and scorer hashes.

Excluded:

- observation arrays and IDs;
- coffee, farm, and variety identities from tasting history;
- free-text notes, source references, dates, brew parameters, and provenance
  references;
- direct-history lookup material.

Roaster names remain in aggregate roaster statistics because roaster affinity
is part of the existing profile component. They reveal aggregate coverage, not
individual coffee records. If this is considered too identifying, the safer
alternative is to make roaster affinity unavailable in portable mode and expose
that as another missing adjustment.

## Alternatives

- Model-only reasoning from the Markdown snapshot: rejected because it cannot
  reproduce origin, process, roaster, rare-family, or exact bonus effects.
- Export sanitized per-coffee history: rejected because it preserves personal
  coffee identities even without notes.
- Treat unavailable history as zero: rejected because it makes private and
  portable scores look directly comparable when they are not.

## Known unknowns and non-goals

- This change does not remediate process canonicalization, CJK substring false
  positives, sparse-family shrinkage, or descriptor vocabulary gaps.
- Aggregate cells with small `n` remain statistically unstable.
- Provenance, accolades, and price remain contextual and unscored.
- The portable scorer does not prove that the heuristic predicts future liking.
