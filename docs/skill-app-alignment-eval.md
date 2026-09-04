# Skill-App Alignment Evaluation

This document describes the alignment evaluation framework for coffee taste scoring, which ensures the App's `Compare Beans` feature matches the gos-coffee-taste skill/repo numeric path within tolerance.

## Product Philosophy

1. **One AI model path** for extract/normalize (App and skill share the same approach/schema) → map 原文 to flavor families + canonical origin/process
2. **One deterministic scorer** for Fit/Novelty (BeanExplorerScorer / portable_coffee_rank). Model never invents scores
3. **测试集 measures drift objectively.** When accuracy/drift is bad, then tune prompt/model — do NOT stack extra locks
4. **Keep the pipe simple**: normalize → score. Retry on hard failure is OK if already present

## Problem Statement

The App's scoring previously used closed lexicon matching for flavor notes, which failed when:
- **Chinese descriptors** were not in the lexicon (e.g. 浆果/berry, 热带水果/tropical fruit, 洛神花/hibiscus)
- **Origin/process terms** didn't match English prior keys, causing Novelty to spike to 42.5 instead of ~10

### Root Cause
Chinese SEY bean notes showed incorrect scores without normalize:
- Wrong top-1 (Susan ranked higher than Keramo/SL9)
- Novelty = 10.0 for all (correct with English origin/process)
- Missed families: `浆果 → fruit.berry`, `热带水果 → fruit.tropical`, `洛神花 → floral`

## Solution: Normalize → Score Contract

### Shared Contract (App and Skill)
1. **Model does NOT invent Fit/Novelty.** Text model only normalizes bag fields into a fixed schema.
2. **Scores only from the deterministic scorer** (`BeanExplorerScorer` / `scripts/portable_coffee_rank.py` — same math).
3. **Normalize by default** in Compare scoring path. No fragile ASCII-only heuristics as the main design.
4. **Normalize output must be constrained** to known keys:
   - Flavor families: IDs from profile lexicon (`fruit.berry`, `fruit.citrus`, etc.)
   - Origin/process: canonical strings matching `origin_stats`/`process_stats` feature keys in `profile-prior.json`

**Note**: App Ark normalizer and skill/repo numeric path must use the **same schema and same scorer**. If skill still maps in prose today, follow-up should call the same normalize→score pipe.

### Implementation

#### 1. Normalize Schema (`CoffeeDescriptorNormalized`)
```swift
{
  "flavor_families": ["fruit.berry", "fruit.tropical", "floral"],
  "origin": "Ethiopia",
  "process": "Honey",
  "descriptor_terms_kept_for_display": ["浆果", "热带水果", "洛神花"]
}
```

- **flavor_families**: Subset of profile category keys (e.g. `fruit.berry`, `fruit.citrus`)
- **origin**: Canonical origin matching `origin_stats` keys (e.g. `Ethiopia`, `Colombia`, `Peru`)
- **process**: Canonical process matching `process_stats` keys (e.g. `Washed`, `Honey`, `Natural`)
- **descriptor_terms_kept_for_display**: Raw seller notes for UI rendering

#### 2. Text-Only Ark Client (`CoffeeDescriptorNormalizer`)
- Maps free-text flavor notes + origin + process into canonical schema
- **Never invents families outside allowed list**
- **Never outputs Fit/Novelty scores**
- **Retry policy**: On invalid JSON, unknown family, or invalid origin/process → retry up to 3 times with repair prompt
- **On retry exhaustion**: Surface error to UI; **do NOT** score via closed lexicon

#### 3. Scoring Path
```
Extract → Normalize → Score (deterministic)
```

1. `BagPhotoScanner` extracts raw notes (multimodal, unchanged)
2. `CoffeeDescriptorNormalizer.normalize()` maps to canonical schema
3. `BeanExplorerScorer.score()` uses:
   - `preMatchedFamilies` (from normalize) instead of lexicon matching
   - Canonical `origin`/`process` (from normalize) for prior lookup

## Alignment 测试集 (Test Set) Framework

### Fixture: `eval/coffee_taste/sey_candidates_2026-09-04.json`
Three SEY Coffee beans with Chinese + English descriptors (corrected real bag notes):

| ID | Origin | Process | Fit (Gold) | Novelty (Gold) | Families |
|----|--------|---------|------------|----------------|----------|
| `sey_keramo_ethiopia_honey` | Ethiopia | Honey | 69.3 | 10.0 | berry, citrus, tropical |
| `sey_sl9_peru_washed` | Peru | Washed | 68.4 | 10.0 | berry, tropical |
| `sey_susan_colombia_washed` | Colombia | Washed | 67.9 | 10.0 | floral, berry, citrus |

**Expected**: Keramo > SL9 > Susan (all three in similar-fit band, delta < 1.5)

**Broken lexicon path**: Without normalize, Chinese descriptors miss families → wrong top-1 (Susan ahead), family mismatch

### Alignment Script: `scripts/evaluate_skill_app_alignment.py`

Compares gold path (English descriptors) vs test path (Chinese descriptors with or without normalize):

#### Gates (Objective Drift Meter)
1. **Top-1 Fit match**: Best candidate must match gold
2. **Ranking order**: Allow near-ties within `near_tie_fit_delta=1.5`; middle ranks may swap only inside band
3. **Novelty tolerance**: Per-candidate Novelty within ±5 of gold
4. **Family Jaccard = 1.0**: Matched family sets must equal gold after normalize

#### Usage
```bash
# Test English→English (sanity check)
python3 scripts/evaluate_skill_app_alignment.py \
  --test-descriptor-field descriptors_english_only \
  --gold-descriptor-field descriptors_english_only

# Test Chinese without normalize (should FAIL - shows drift/bug)
python3 scripts/evaluate_skill_app_alignment.py

# Test Chinese with stub normalize (should PASS - for CI without live Ark)
python3 scripts/evaluate_skill_app_alignment.py --stub-normalize

# Verbose output
python3 scripts/evaluate_skill_app_alignment.py --stub-normalize -v
```

**Stub normalize**: For CI testing without live Ark, `--stub-normalize` applies a frozen CN→canonical map:
- 浆果 → fruit.berry
- 热带水果 → fruit.tropical
- 洛神花 → floral
- 埃塞俄比亚 → Ethiopia
- 蜜处理 → Honey
- etc.

Exit code 0 if all gates pass, non-zero otherwise.

## Refreshing Gold Scores

When the profile or fixture changes:

```bash
# Score with English descriptors to establish gold
python3 scripts/portable_coffee_rank.py \
  --profile Sources/CoffeeJournalApp/Resources/TasteProfile/profile-prior.json \
  --candidates eval/coffee_taste/sey_candidates_2026-09-04.json

# Update fixture's gold_ranking section with output
```

## Testing

### Python Alignment
```bash
# Should pass with stub normalizer (English descriptors)
python3 scripts/evaluate_skill_app_alignment.py \
  --test-descriptor-field descriptors_english_only \
  --gold-descriptor-field descriptors_english_only
```

### Swift Unit Tests
See `Tests/CoffeeJournalCoreTests/BeanExplorerScoringTests.swift`:
- Schema validation for `CoffeeDescriptorNormalized`
- Retry-on-invalid for normalize failures
- Scorer with pre-matched families + Chinese origin aliases
- SEY alignment: SL9/Keramo ahead of Susan, Novelty ~10

## Known Limitations

- **Normalize by default** unless `preMatchedFamilies` already set (from prior normalize or test)
- **Quality signals** not yet normalized (e.g. 酸甜→acid_sweet_balance_positive)
- **Ark availability**: Normalize requires configured Ark API key; development mode may skip normalize when unavailable
- **Lexicon remains** for gold/fixture generation but is NOT used in App scoring hot path after normalize

## Future Work

- Extend normalize to quality signals (e.g. `酸甜 → acid_sweet_balance_positive`)
- Add confidence scores from normalize
- Expand fixture with more roasters and languages
- Automate alignment tests in CI
