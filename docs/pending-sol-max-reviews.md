# Pending Sol Max Reviews

Status date: 2026-07-19. Two review packets are prepared but NOT yet run; the
changes they cover are implemented and unit-tested (36 tests) but not
decision-ready per protocol v4 until each gate approves. Run the prepare and
review phases on a machine with `codex` CLI access.

## R1 — Evaluation integrity changes

Scope: make recommendation contract scoring non-tautological, unify the
frontier fit and narrative length thresholds, apply NFKC and two-hanzi identity
matching, and report weighted plus unweighted pairwise accuracy with tracked
regression-watch cases.

```bash
python3 scripts/consult_sol_max.py \
  --prepare \
  --topic eval-integrity-changes \
  --scope "adopt non-tautological contract scoring, unified thresholds, CJK matching, and honest pairwise reporting as the evaluation baseline" \
  --question "Review whether ordering_source-based contract scoring, FRONTIER_MIN_FIT/NARRATIVE_LENGTH_RANGE unification, NFKC+two-hanzi identity matching, and regression_watch reporting are sound, and identify remaining tautologies or blind spots." \
  --acceptance-criteria "Approve only as internal evaluation mechanics; reject any claim of calibrated recommendation accuracy; require the post-change re-run numbers to replace the superseded 0.970 contract baseline." \
  --input scripts/evaluate_coffee_taste_prompts.py \
  --input scripts/build_coffee_taste_dataset.py \
  --input eval/coffee_taste/eval_cases.example.json \
  --input docs/coffee-taste-profile-and-recommendation.md

python3 scripts/consult_sol_max.py \
  --preregistration .generated/sol-max-preregistrations/<review>.json \
  --preregistration-sha256 <sha-from-prepare>

python3 scripts/verify_sol_max_gate.py \
  .generated/sol-max-reviews/<review>.gate.json \
  --scope "adopt non-tautological contract scoring, unified thresholds, CJK matching, and honest pairwise reporting as the evaluation baseline"
```

## R2 — Profile v2 narrative guardrails

Scope: adopt prompt v2 with guardrailed model-authored narrative
(validate_model_narrative pass-through, fallback otherwise) and the
narrative_model_kept_rate metric, with the v2 adoption rule.

```bash
python3 scripts/consult_sol_max.py \
  --prepare \
  --topic profile-v2-narrative-guardrails \
  --scope "adopt guardrailed model-authored narrative (prompt v2) with deterministic validation and the PRODUCT_VERSION adoption rule" \
  --question "Review whether validate_model_narrative's guardrails (length, absolute claims, extrinsic terms, unhedged undersampled dimensions, invented flavor families, confidence clamp) are sufficient to keep model-authored narrative without reintroducing unsupported taste claims, and whether the adoption rule is defensible. Compare v1 and v2 prompts blinded." \
  --acceptance-criteria "Approve only if every kept narrative is provably contract-consistent by code; reject if any guardrail depends on model self-report; PRODUCT_VERSION may flip to v2 only with pairwise (weighted and unweighted) >= v1 and no tracked-challenge regression." \
  --input prompts/coffee_profile_v1.md \
  --input prompts/coffee_profile_v2.md \
  --input scripts/evaluate_coffee_taste_prompts.py \
  --input docs/coffee-taste-profile-and-recommendation.md

python3 scripts/consult_sol_max.py \
  --preregistration .generated/sol-max-preregistrations/<review>.json \
  --preregistration-sha256 <sha-from-prepare>

python3 scripts/verify_sol_max_gate.py \
  .generated/sol-max-reviews/<review>.gate.json \
  --scope "adopt guardrailed model-authored narrative (prompt v2) with deterministic validation and the PRODUCT_VERSION adoption rule"
```

## Blocked follow-ups

- Re-run `python3 scripts/evaluate_coffee_taste_prompts.py --versions v1 v2
  --max-cases 4 --thinking disabled` once Ark credentials are available
  (`config.json` or `ARK_API_KEY`); record the new honest baseline in
  `docs/coffee-taste-profile-and-recommendation.md` and a refreshed tracked
  summary under `eval/coffee_taste/`.
- Restore the excluded low-learnability case
  `loved_radiance_vs_ok_rogue_wave` to `private/coffee_taste/eval_cases.json`
  after copying the app export (`backups/.../store.json`) to this machine.
