# Data schemas

## Tasting observation (`private/coffee_taste/flomo_observations.json`)

Top level: `{"schema_version": ..., "curation_note": "...", "observations": [...]}`.
Append new observations to the `observations` array; never rewrite existing
entries unless the user corrects them (record the correction in `user_note`
with the date, e.g. `"confirmed Great 2026-07-20"`).

```json
{
  "id": "chat_20260720_roaster_bean",
  "entity_id": "roaster_farm_bean",
  "source_ref": "chat_20260720",
  "date": "2026-07-20",
  "coffee": {
    "roaster": "FriedHats",
    "name": "Las Margaritas Sudan Rume",
    "origin": "Colombia",
    "farm": "Las Margaritas",
    "variety": "Sudan Rume",
    "process": "Washed"
  },
  "rating": {"label": "Great"},
  "sensory": {"descriptors": ["mint", "orange", "cardamom"]},
  "user_note": "User stated (chat 2026-07-20) ..."
}
```

Field notes:

- `id` must be unique; prefix with the source (`flomo_`, `chat_`, `app_`).
- `entity_id` identifies the coffee itself — reuse the same `entity_id` when
  the user re-tastes a coffee they already logged (ratings then aggregate).
- **Rating labels** — flomo/chat family: `Great` > `Good` > `OK` > `So So` >
  `General`; app Verdict family: `Loved` > `Liked` > `Ok` > `Disliked`. Any
  other label degrades gracefully (score None + limitation) but ask the user
  rather than inventing one. If the user gives a range ("good~great"), anchor
  at the lower tier and note the range in `user_note`; upgrade only when they
  confirm.
- `sensory.descriptors`: keep the seller's/user's original words, Chinese or
  English, one term per entry. The lexicon in
  `scripts/build_coffee_taste_dataset.py` maps them to flavor families; if a
  defining descriptor matches no family (check the built dataset), extend the
  lexicon in that script (see the cardamom/mint precedent, commit `277dd4c`).
- `user_note`: only first-person statements the user actually made. This is
  rare by design — the user rarely writes notes; rating tiers carry the
  signal.
- Optional: add `"dedupe_key"` (top level) to merge duplicates of the same
  tasting across memos.

## Candidate bean (`live_candidates.json`, key `candidates`)

Top level: `{"schema_version": ..., "checked_at": "...", "purpose": "...",
"curation_notes": "...", "candidates": [...]}`.

```json
{
  "id": "live_roaster_bean",
  "roaster": "Mirra",
  "name": "Alina Solano SL9",
  "origin": "Peru",
  "region": "Cusco",
  "farm": "Alina Solano",
  "variety": "SL9",
  "process": "Washed",
  "altitude_m": "2400",
  "descriptors": ["椰奶", "coconut milk", "ataulfo mango", "pink peony"],
  "seller_notes": "free text from the seller page",
  "price": {"amount": null, "currency": "CNY", "size_grams": null},
  "availability": "in_stock_listed_2026-07-20",
  "accolades": [
    {"competition": "Copa de Oro", "region": "Huila, Colombia",
     "result": "Grand Champion", "year": 2025, "scope": "lot", "scored": false}
  ],
  "provenance_reputation": [
    {"axis": "estate", "tier": "tier_1", "name": "Hacienda La Esmeralda",
     "basis": "Tier 1 estate", "scored": false}
  ],
  "source_url": "",
  "historical_overlap": "note any same-name/same-farm history entries here"
}
```

- `accolades` records extrinsic competition/quality provenance (COE, Copa de
  Oro, national cupping placings). It is **human-judgment only and NOT read by
  any scoring code** — `candidate_prior` ignores it, exactly like region and
  estate reputation. Keep `"scored": false` as a standing reminder. Surface it
  in the 理性 section as context ("这批生豆客观顶尖"), never as a fit driver.
  `scope`: `lot` (this exact lot placed), `producer` (the grower has a record),
  `estate` (the farm has a record).
- `provenance_reputation` tags the bean's estate/region against the allowlist in
  `references/prestige-regions-estates.md`. `axis`: `estate` (Tier 1, or Tier 2-B)
  or `region` (Tier 2-A). Also extrinsic, `"scored": false`, ignored by
  `candidate_prior`. An **empty list = null**, which is the normal state for most
  beans — never a demerit; do not invent a tag for an unlisted origin/estate.
  Note CGLE farms are in Valle del Cauca (not an A-list department), so they carry
  an estate tag but no region tag. Read that reference before adding tags.
- Scoring granularity, for reference: fit uses **origin at country level only**
  (Huila/Nariño collapse to Colombia — no region_stats), **variety not at all**
  (narrative correlations only), and **farm only via direct history identity**
  (did the user rate this exact coffee before) — never farm reputation. This is
  deliberate: at region/farm granularity the history is ~1 observation per cell,
  too sparse for a prior.

- `roaster` attribution matters: mis-parsing which roaster sells which bean
  silently moves the roaster affinity bonus (this happened once — verify
  table→roaster mapping with the user when input is ambiguous).
- `descriptors` should include both the Chinese and English seller terms when
  available — matching runs on both.
- The tracked, user-approved public copy lives at
  `eval/coffee_taste/live_candidates.json`; the working copy the scripts read
  is `private/coffee_taste/live_candidates.json`. Keep both in sync when the
  user says the list is committable.
