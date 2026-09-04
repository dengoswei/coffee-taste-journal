# Bag Extraction Regression Eval — Design

## Goal

Any change to Ark **model**, **prompt**, or **parser** for Add Beans / Compare
Beans must pass a frozen image test set with published metrics. We optimize for
**complete correct extraction**, not for which prompt philosophy looks cleaner.

Existing pieces to reuse:

- `eval/coffee_bag_expected_labels.json` (5 single-bag gold labels)
- `scripts/evaluate_coffee_bag_models.py` (Add Bean field scoring)
- `docs/vlm-coffee-bag-eval.md` (smoke / batch how-to)

This design extends that into a **shared regression gate** covering Compare Beans
multi-package extraction and explicit **completeness** metrics.

## Tracks

| Track | Prompt/parser under test | Gold shape |
|---|---|---|
| `add_bean` | `BagPhotoScanner` compact schema | 1 coffee + bag meta per image |
| `compare_beans` | `BeanExplorerPhotoScanner` multi-package schema | 1..N packages per image |

Both tracks hit the same Ark endpoint/credentials. Only prompt+parser differ.
After unification work, both tracks should be scored with the **same field
metrics**; Compare still needs package-count / package-assignment metrics.

## Dataset

### Layout

```text
eval/bag_extraction/
  manifest.json                 # schema version, tracks, baseline run id
  cases/
    <case_id>/
      meta.json                 # track, notes, license, source
      images/                   # 1+ photos (prefer jpeg copies under git-lfs or private/)
      expected.json             # gold labels
  baselines/
    <run_id>.json               # frozen aggregate metrics for gate
```

Until multi-bag gold is ready, keep single-bag gold in
`eval/coffee_bag_expected_labels.json` and add Compare cases under
`eval/bag_extraction/cases/` (SEY collage etc.).

### Gold label rules

- Label only what is **visibly readable** on the image (same rule as product:
  no seller-page enrichment in gold).
- `flavor_notes`: ordered list of seller-declared sensory words on-pack / on-card.
  Synonyms allowed at score time via normalized matching, not at label time.
- Mark `hard: true` for occlusion, glare, tiny type, multi-language mix.
- Multi-package images: gold is an array of packages in reading order
  (top-to-bottom, left-to-right), each with the Add-Bean coffee fields.

### Starter sizes

| Slice | Min cases | Purpose |
|---|---:|---|
| Smoke | 5 (existing) | Always run locally |
| Core single-bag | 20+ | Gate for Add Beans + unified Compare-on-single |
| Multi-package | 10+ | Gate for Compare collage / multi-bag |
| Hard / regression_watch | as needed | Known past failures (thin flavors, wrong origin) |

Private originals may live under `private/` / `test_images/`; committed expected
JSON should avoid PII beyond package text.

## Metrics

Report micro and macro. Gate primarily on **macro** so one easy case cannot hide
systematic flavor loss.

### Per field (scalar)

For `roaster`, `name`, `origin`, `farm`, `variety`, `process`, `roast_date`,
`total_grams`:

- **Exact-normalized accuracy**: existing `normalize_string` equality in
  `evaluate_coffee_bag_models.py`.
- **Fill rate**: predicted non-empty / gold non-empty (catches over-nulling).
- **Hallucination rate**: predicted non-empty when gold is null.

### Flavor notes (primary completeness signal)

Treat notes as a set after normalization:

- **Recall (completeness)** = \|pred ∩ gold\| / \|gold\|  ← **main KPI for “漏抽”**
- **Precision** = \|pred ∩ gold\| / \|pred\|  ← hallucination control
- **F1** = harmonic mean
- **Count bias** = mean(\|pred\| − \|gold\|)

Do **not** gate only on weighted overall accuracy; flavor recall must be first-class.

### Multi-package (Compare only)

- **Package count exact match**
- **Package assignment F1**: greedy match packages by roaster+name similarity,
  then score fields inside matched pairs; unmatched gold = miss, unmatched pred =
  false package
- **Orphan rate**: packages with empty flavor_notes when gold has notes

### Aggregate report fields

```json
{
  "track": "compare_beans",
  "model": "...",
  "prompt_hash": "...",
  "parser_hash": "...",
  "n_cases": 0,
  "overall_weighted_accuracy": 0.0,
  "flavor_recall": 0.0,
  "flavor_precision": 0.0,
  "flavor_f1": 0.0,
  "field_accuracy": {},
  "package_count_accuracy": 0.0,
  "package_assignment_f1": 0.0,
  "per_case": []
}
```

## Gate (anti-regression)

Store a baseline under `eval/bag_extraction/baselines/<id>.json`.

A change **fails** the gate if any hold vs baseline on the same case set:

1. `flavor_recall` drops by **> 0.05** absolute, or
2. `overall_weighted_accuracy` drops by **> 0.03**, or
3. `flavor_precision` drops by **> 0.08** (allow small recall gains that add noise,
   but not wild hallucination), or
4. For Compare track: `package_count_accuracy` drops by **> 0.10**.

Hard cases tagged `regression_watch` are reported separately; they do not soften
the core gate unless explicitly waived in the PR.

Suggested CLI:

```bash
# Establish / refresh baseline after an accepted improvement
python3 scripts/evaluate_bag_extraction.py \
  --track both --model "$ARK_MODEL" --write-baseline baselines/YYYYMMDD.json

# Required before prompt/model/parser merge
python3 scripts/evaluate_bag_extraction.py \
  --track both --model "$ARK_MODEL" \
  --baseline eval/bag_extraction/baselines/<current>.json \
  --fail-on-regression
```

Exit non-zero on regression. Write
`.generated/bag_extraction_eval/<run_id>/{summary.md,results.json}`.

## Change process (App feature)

1. Touching Explorer/Add Bean **prompt**, **parser**, **model id**, or image
   preprocess ⇒ must attach eval summary + gate status in the review packet /
   PR.
2. Unification (Compare ← Add Beans flavor behavior) is an **improvement
   candidate**: run both tracks before/after; new baseline only after human
   accepts the metric delta.
3. Do not claim calibrated real-world accuracy; this gate is **relative
   regression control** on a frozen set.
4. Sol Max / review packets for extraction changes should cite the run id and
   the four gate metrics above.

## Implementation plan (repo)

1. **Doc** — this file (design + gate).
2. **Schema** — `eval/bag_extraction/cases/*/expected.json` for multi-package;
   keep legacy single-bag file as imported smoke set.
3. **Script** — `scripts/evaluate_bag_extraction.py` wrapping:
   - existing Add Bean scorer functions from `evaluate_coffee_bag_models.py`;
   - new Compare path that sends the frozen Explorer prompt (or unified prompt)
     and scores packages.
4. **Seed Compare gold** — at least the SEY three-card collage + 2–3 other
   multi-product images with hand labels (visible text only).
5. **Wire** — document in `docs/vlm-coffee-bag-eval.md` and AGENTS.md: “extraction
   prompt/model changes require `--fail-on-regression`”.
6. **Optional later** — Swift parser unit tests stay for schema; this eval is the
   live-model quality gate (cannot be replaced by parser-only tests).

## Non-goals

- Measuring recommendation Fit/Novelty quality (separate scorer parity fixtures).
- Provider latency/cost SLOs (log separately if needed).
- Auto-labeling gold from seller web pages (contaminates “visible-only” truth).
