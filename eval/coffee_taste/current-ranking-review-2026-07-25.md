# Current Combined Ranking Review Packet (2026-07-25)

## Proposed decision

Treat the deterministic ranking below as the current ordering signal for the
user's purchase decision across the authoritative 16 live candidates plus four
non-duplicate Tanat additions.

## Acceptance criteria

Approve only if all of the following hold:

1. All 20 distinct candidates are present and the duplicate Tanat Las
   Margaritas Natural Gesha record is represented once using the authoritative
   live-candidate identity.
2. Scores follow `candidate_prior` without extra human weights. Provenance,
   accolades, and price do not change fit.
3. The ranking is presented as an uncalibrated ordering signal, not a liking
   probability.
4. Direct name history is distinguished from weak `farm_only` history.
5. The added Budha Janson Geisha Liked rating does not justify a material taste
   claim by itself; changes versus the frozen 50-rating baseline remain visible.
6. The top and bottom can be treated as more stable than the tightly clustered
   middle.

## Evaluator and data versions

- Scorer: `scripts/evaluate_coffee_taste_prompts.py` at Git commit `3c53f90`.
- Function: `candidate_prior`, applied to every available candidate without the
  `shortlist_live_candidates(limit=10)` truncation.
- Current aggregate evidence: 62 observations, 51 explicit ratings, 11 unrated
  exposures, 4 substantive first-person notes; Loved 7 / Liked 34 / Ok 10 /
  Disliked 0.
- Candidate sources: `eval/coffee_taste/live_candidates.json` (16) and
  `eval/coffee_taste/tanat_candidates_2026-07-25.json` (five, one duplicate).
- Leakage boundary: no raw notes or private observation rows are included.

## Unweighted deterministic result

| Rank | Candidate | Fit | Novelty | Rank change vs 50 |
|---:|---|---:|---:|---:|
| 1 | FriedHats - Las Margaritas Sudan Rume Washed | 96.1 | 4.5 | 0 |
| 2 | Tanat - Las Margaritas Sudan Rume Natural | 95.0 | 0.0 | 0 |
| 3 | Hatch - Santamaria Estate Lot L31 | 80.1 | 6.7 | 0 |
| 4 | Tanat - Las Margaritas Natural Gesha | 77.4 | 20.7 | 0 |
| 5 | Hatch - HLE Red Label Noria 5 FB Geisha | 74.6 | 10.0 | 0 |
| 6 | Tanat - Alo Chilaka Natural | 72.6 | 10.0 | 0 |
| 7 | Tanat - Alo Bore Washed | 72.1 | 10.0 | 0 |
| 8 | Hatch - Inmaculada Fellows Geisha | 71.8 | 10.0 | 0 |
| 9 | Hatch - Cerro Azul Hybrid Washed Geisha | 71.4 | 25.0 | 0 |
| 10 | Tanat - Jhon Saenz Washed SL9 | 71.1 | 10.0 | 0 |
| 11 | Mirra - Alina Solano SL9 | 70.9 | 10.0 | 0 |
| 12 | Subtext - Maria Delgado | 70.9 | 21.1 | 0 |
| 13 | Subtext - Copa de Oro Grand Champion - Hugo Gonzalez | 70.4 | 10.0 | 0 |
| 14 | Tanat - Elto Elora 72h Anaerobic Natural | 70.4 | 25.0 | +1 |
| 15 | Tanat - Acacia Hills Gesha | 70.3 | 27.5 | -1 |
| 16 | Subtext - Valdeir Tomazini Washed | 70.2 | 10.0 | 0 |
| 17 | Mirra - Acacia Pacamara | 68.9 | 27.5 | 0 |
| 18 | Mirra - Banko Taratu | 68.9 | 10.0 | 0 |
| 19 | Tanat - Alo Mosto Anaerobic Natural | 63.8 | 38.9 | 0 |
| 20 | Mirra - Acacia Gesha | 63.3 | 38.6 | 0 |

## Known limitations

- The sample is self-selected and has no Disliked observations.
- Seller descriptors are claims, not confirmed cup perceptions.
- Fit and novelty are heuristic ordering scores, not calibrated probabilities.
- Most middle candidates are near-ties; a single new Loved rating may reorder
  them.
- Same-farm overlap is down-weighted and must not be described as a known-good
  rebuy.
