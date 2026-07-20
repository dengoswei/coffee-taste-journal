---
name: coffee-taste
description: Update the user's personal coffee taste profile from new tasting data and recommend beans from candidate lists, with reasons split into emotive (感性) and rational (理性) parts. Use this whenever the user mentions drinking, rating, or buying coffee — a new bean they tasted (喝了/评价/打分), bean info or a candidate/shortlist table (候选/清单/豆子/推荐), asking what to buy next, or asking about their 风味画像/taste profile — even if they don't say "profile" or "recommend" explicitly.
---

# Coffee taste profile & recommendations

This repo contains a deterministic pipeline that turns the user's tasting
history into (a) a flavor profile with a guardrail-validated emotive
narrative and (b) safe/frontier bean recommendations. Your job is to feed it
correct data, run it, and translate its output into an answer — never to
invent taste claims the pipeline can't back.

Core principle: **every number and preference statement comes from the
deterministic code; you author only the emotive language, and only within
the guardrails.** The user rarely writes tasting notes — Great/Loved rating
concentration is the primary preference signal, not notes.

Data lives under `private/coffee_taste/` (gitignored — never commit anything
from there). Read `references/data-schemas.md` before writing observation or
candidate JSON.

## Always state the evidence base

Every profile or recommendation you deliver must carry a short **证据基础**
block, because the user is deliberately growing this dataset over time and
needs to see what the current answer rests on — and which cells are still too
thin to trust. Get the numbers from
`python3 .claude/skills/coffee-taste/scripts/coverage_report.py` (add
`--json` to consume it programmatically); never estimate them from memory.

Report at minimum:

- 观察总数 / 有评分数 / 第一人称实饮描述数
- 喜好档位分布: Disliked / Ok / Liked-Good / Loved-Great, with percentages
- 覆盖的烘焙商 (and which have only 1 record)
- 明确的缺口 — the report's 缺口 section names them

Why this matters concretely: with ~50 observations and a tier distribution
this skewed, a single bean entering or leaving the Loved/Great tier reshuffles
most of the middle ranking. Presenting a fine-grained ordering as if it were
stable misleads the user. Say what is solid (the extremes) and what is not
(the middle), and point at the specific gap they could fill next.

## Workflow A — user tasted a coffee (update the profile)

1. Collect: roaster, bean name, origin/farm/variety/process, rating tier,
   any descriptors, any first-person note. Ask only for what's missing and
   material (rating tier is essential; altitude is not).
2. Append the observation to `private/coffee_taste/flomo_observations.json`
   per `references/data-schemas.md`. Range ratings ("good~great") anchor low.
3. Run `python3 .claude/skills/coffee-taste/scripts/refresh_profile.py`
   (add `--store <app store.json>` if an app export exists on this machine).
   It rebuilds the dataset, runs the unit-test gate, and prints the top-tier
   families and stats.
4. If the profile's emotive narrative is stale (new top-tier entries, or the
   narrative names tiers/counts that changed), author a new summary JSON
   (`headline`, `narrative`, `confidence`, `confidence_reasons`) in the
   scratchpad and re-run with `--narrative <file>`. The script keeps it only
   if it passes the deterministic guardrails (90–180 Chinese chars, headline
   ≤30, no absolute claims, undersampled dimensions only with hedging, only
   flavor families present in the contract). If it prints violations, fix
   the text — do not weaken the guardrails.
5. Show the user what changed: new rating, which flavor families moved,
   whether the top-tier (Great/Loved) set changed, narrative source
   (model/fallback), plus the 证据基础 block.

### Importing an app export

The iPhone app writes exactly the format the parser reads — no hand
conversion. Run
`python3 .claude/skills/coffee-taste/scripts/inspect_app_export.py <store.json>`
first: it is read-only and reports usable verdicts, substantive notes,
bean-level verdicts, unmatched flavor terms, and the expected net gain.
Resolve what it flags (usually lexicon gaps) before merging, then pass
`--store <store.json>` to `refresh_profile.py`.

Two things the app data makes visible that flomo cannot:

- **Same coffee, different cups.** One bean can carry several brew logs with
  different verdicts (the user hit this with SAVAGE COFFEES RADIANCE: Loved
  then Ok on the same recipe). Brewing variance is part of the signal, not
  noise to be averaged away silently — surface it.
- **Bean-level vs brew-level verdicts.** `Coffee.verdict` is the user's
  settled view of the bean; `brewLogs[].verdict` is one cup. Both are
  imported; a bean-level verdict with no brew log gets weight 0.6 and a
  limitation noting no specific cup stands behind it.

## Workflow B — user provides candidate beans (recommend)

1. Parse the candidates into `private/coffee_taste/live_candidates.json` per
   `references/data-schemas.md`. When the input is several tables/screenshots,
   confirm the table→roaster mapping with the user if it's at all ambiguous —
   a mis-attributed roaster silently shifts scores.
2. Run `python3 .claude/skills/coffee-taste/scripts/recommend.py`
   (`--candidates <file>` for a one-off list; `--narrative <file>` to carry
   the current emotive summary into the report). It prints safe_match,
   frontier_pick, and a per-candidate breakdown: fit/novelty, bonus
   components, history-match scope, top-tier family hits.
3. Compose the answer using the output format below. Ground every claim in
   the breakdown: descriptor categories, top_tier_hits, history_match, and
   the bonus numbers. Seller descriptors are claims, not facts — say so.

### Recommendation output format

For **safe_match**(稳妥之选) and **frontier_pick**(拓展之选), each:

```
### [Roaster - full bean name]

**感性** — 2–3 sentences, second person, evocative: connect this bean's
declared flavor line to a thread in the user's profile ("这支会接上你
Sudan Rume 那条清爽辛香的线…"). Only reference flavor families the
breakdown actually lists for this candidate (descriptor_categories /
top_tier_hits); never promise the cup will deliver — the seller words are
claims to be verified by brewing.

**理性** —
- 预测匹配 {fit}/100，新奇度 {novelty}/100（说明主要来源：哪些家族命中、
  各 bonus 分量:direct_history / top_tier_affinity / roaster_affinity）
- 历史证据: n 条记录、加权评分 x/4；同名匹配还是 farm_only(同庄园不同豆,
  已按 1/3 降权)——写清楚是哪一种
- 风险与冲煮观察点(从报告带过来,不自创)
```

Then a one-line table of the remaining ranking (id, fit, novelty) so the
user sees the alternatives, using full bean names.

### Why the 感性/理性 split

The user wants to *feel* why a bean might delight them (that's what makes a
recommendation persuasive) but also audit the evidence (that's what makes it
trustworthy). Blending them produces text that does neither. Keep the
emotive part free of numbers and the rational part free of poetry.

## Ground rules

- Full identifiers always: full bean names, full file paths, full commit
  SHAs. Never "the trial"/"那支豆子" when a specific name exists.
- Same farm ≠ same coffee: farm-only history overlap is a hint (1/3 weight),
  not a rating of this candidate. Don't oversell it in the 感性 part.
- Roasters are treated equally unless rated history exists (then a capped
  ±3 bonus applies). Never impose cross-roaster constraints.
- Fit/novelty are uncalibrated heuristics for ordering, not probabilities —
  present them as 排序信号, not 预言.
- Privacy: `private/`, `backups/`, `.generated/` stay out of git. Bean facts
  and like-level ratings are user-approved as non-sensitive (2026-07-19) and
  may be committed to `eval/coffee_taste/` when the user asks; the raw
  tasting history and generated reports stay private by default.
- If the pipeline and the user disagree (e.g. they loved a bean the prior
  scored low), the user is right — record the observation, then check
  whether a lexicon gap or a mis-parse explains the miss before touching any
  weights.
