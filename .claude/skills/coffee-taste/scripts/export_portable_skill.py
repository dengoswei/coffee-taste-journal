#!/usr/bin/env python3
"""Export the portable, self-contained `gos-coffee-taste` skill.

The project skill (this repo) owns the pipeline, private data, and iteration.
This exporter freezes a SNAPSHOT of the taste profile plus a portable evaluation
method into a skill directory that runs ANYWHERE by model reasoning — no journal
repo, no Python, no private data required.

Loop: taste a bean -> refresh_profile.py -> export_portable_skill.py -> sync.

Outputs (into --out, default ~/.claude/skills/gos-coffee-taste):
  SKILL.md
  profile-snapshot.md          (data-driven; regenerated each run)
  profile-prior.json           (aggregate sufficient statistics; no raw rows)
  scripts/rank_candidates.py   (standalone deterministic portable scorer)
  references/scoring-method.md
  references/prestige-regions-estates.md   (copied from this skill)

Only aggregate signals are exported. Observation rows, coffee identities,
first-person notes, dates, and brew details stay private in the journal repo.
"""
import argparse
import hashlib
import json
import shutil
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parents[1]          # .../skills/coffee-taste
REPO = Path(__file__).resolve().parents[4]               # journal repo root
sys.path.insert(0, str(REPO / "scripts"))
PRIVATE = REPO / "private" / "coffee_taste"
PORTABLE_SCORER = REPO / "scripts" / "portable_coffee_rank.py"

from build_coffee_taste_dataset import RATING_SCORE_MAX  # noqa: E402
from evaluate_coffee_taste_prompts import (  # noqa: E402
    TOP_TIER_MIN_OBSERVATIONS,
    build_evidence_packet,
    build_profile_contract,
)
from portable_coffee_rank import build_portable_profile  # noqa: E402

TIER_BY_SCORE = {3: "Loved", 2: "Liked", 1: "Ok", 0: "Disliked"}


def build_snapshot(observations: list[dict]) -> str:
    packet = build_evidence_packet(observations)
    contract = build_profile_contract(observations)

    tiers = Counter()
    notes = 0
    for obs in observations:
        score = obs["rating"].get("score")
        if score is not None:
            tiers[TIER_BY_SCORE.get(score, "?")] += 1
        note = (obs.get("user_note") or "").strip()
        if note and obs.get("source_ref", "").startswith(("chat", "flomo")):
            notes += 1
    rated = sum(tiers.values())

    top_tier = [
        row for row in packet["top_tier_family_stats"]
        if row["top_tier_count"] >= TOP_TIER_MIN_OBSERVATIONS
    ]
    likely = contract["likely_sensory_families"]
    likely_by_cat = {f["category"]: f for f in likely}

    # Firmness comes from the Loved-tier COUNT, not the average. In a
    # self-selected sample almost every family averages near 2.0, so the average
    # barely discriminates — the number of Loved-tier appearances is the real
    # signal. "Thin" = only just cleared the bar (count == the minimum): one data
    # point in or out flips it (this is how floral just entered, via Santamaria).
    firm = [row for row in top_tier
            if row["top_tier_count"] > TOP_TIER_MIN_OBSERVATIONS]
    thin = [row for row in top_tier
            if row["top_tier_count"] == TOP_TIER_MIN_OBSERVATIONS]
    # For the one explicit "count says top, average says lowest" example, pick the
    # thin family with the lowest average.
    lowest_thin = min(
        (r for r in thin if likely_by_cat.get(r["category"], {}).get("weighted_rating") is not None),
        key=lambda r: likely_by_cat[r["category"]]["weighted_rating"],
        default=None,
    )

    roasters = sorted(
        packet.get("roaster_stats", []),
        key=lambda r: -r["observations"],
    )
    thin_roasters = [r["feature"] for r in roasters if r["observations"] == 1]

    def pct(n):
        return f"{round(100 * n / rated)}%" if rated else "—"

    today = datetime.now(timezone.utc).date().isoformat()
    lines = [
        "# 口味画像快照 (frozen snapshot — NOT live)",
        "",
        f"导出时间：{today}。**这是快照**：反映导出当刻的口味,不随后续品鉴自动更新。",
        "真源与迭代在 `coffee-taste-journal` 仓库;喝了新豆需重跑 export 才会更新此处。",
        "",
        "## 证据基础",
        "",
        f"- {rated} 条明确评分 / {notes} 条第一人称笔记(笔记**不**参与偏好判定)。",
        f"- 档位分布:**Loved {tiers['Loved']}（{pct(tiers['Loved'])}）· "
        f"Liked {tiers['Liked']}（{pct(tiers['Liked'])}）· "
        f"Ok {tiers['Ok']}（{pct(tiers['Ok'])}）· Disliked {tiers['Disliked']}**。",
        "- ⚠ **自选样本**:用户只买预期会喜欢的,分布偏正、Disliked=0。能答"
        "「哪支更合我」,答不了「我的下限在哪」。",
        "",
        "## 主证据:高分层(Loved)家族集中度",
        "",
        "命中这些家族 = 强信号(它们在你最爱的杯子里反复出现)。"
        "**信号强弱看 Loved 计数**,不看均分(见下方警告):",
        "",
        *[
            f"- **{row['label']}**（`{row['category']}`）：Loved 层出现 "
            f"{row['top_tier_count']} 次 "
            + ("— 稳" if row['top_tier_count'] > TOP_TIER_MIN_OBSERVATIONS
               else "— ⚠ 薄(压线,一个数据点就可能进出)")
            for row in top_tier
        ],
        "",
        "## 评分 × 家族相关性(全样本加权分，满分 "
        f"{RATING_SCORE_MAX}）",
        "",
        *[
            f"- {f['label']}（`{f['category']}`）：{f['weighted_rating']} "
            f"（n={f['observations']}）"
            for f in likely
        ],
        "",
        "## ⚠ 已知不稳定 / 必须带的警告",
        "",
        f"- **稳的高分家族(Loved 计数 >{TOP_TIER_MIN_OBSERVATIONS})**："
        + ("、".join(r["label"] for r in firm) or "暂无")
        + "。这些才是可靠的强项。",
        f"- **薄的高分家族(压线,计数={TOP_TIER_MIN_OBSERVATIONS})**："
        + ("、".join(r["label"] for r in thin) or "暂无")
        + "。一条 Loved 就能让它进出高分层,别当稳。"
        + (
            f"例:**{lowest_thin['label']}** "
            f"是最近一条 Loved 才压进来的(均分仅 "
            f"{likely_by_cat[lowest_thin['category']]['weighted_rating']},全场最低档)。"
            if lowest_thin else ""
        ),
        "- **均分别过度解读**:自选样本把几乎所有家族的均分压在 2.0 附近,"
        "家族间区分度低——**以 Loved 计数为主信号**,不是均分。",
        "- **Disliked = 0**:画像只覆盖口味空间上半部,无下限锚点。",
        "- **价格未建模**:贵豆和便宜豆同等对待,性价比自行判断。",
        "- ~50 条数据 + 偏斜档位下,**中段排序不稳**:一条 Loved 就能重排中间。"
        "可信的是两端,别把中段精确名次当真。",
        "",
        f"## 覆盖的烘焙商(前几名)",
        "",
        f"{', '.join(r['feature'] + '(' + str(r['observations']) + ')' for r in roasters[:8])}。"
        + (f" 仅 1 条记录的:{', '.join(thin_roasters[:12])}。" if thin_roasters else ""),
        "",
    ]
    return "\n".join(lines)


SKILL_MD = """\
---
name: gos-coffee-taste
description: Evaluate which coffee beans suit THIS user and recommend from a candidate list, with reasons split into emotive (感性) and rational (理性). Use whenever the user mentions drinking, rating, or buying coffee — a candidate/shortlist table (候选/清单/豆子/推荐), asking what to buy next, or asking about their 风味画像/taste profile — even without saying "profile" or "recommend". This is the portable, snapshot-based skill; the full pipeline lives in the coffee-taste-journal repo.
---

# gos-coffee-taste — portable bean evaluator

Self-contained. It carries a frozen human-readable snapshot plus aggregate
sufficient statistics and a deterministic scorer. It never contains raw tasting
rows, coffee identities, notes, dates, or brew details.

**Always open `profile-snapshot.md` first** and read
`references/scoring-method.md`. Consult `references/prestige-regions-estates.md`
for estate/region provenance.

## Choose the scoring mode

1. If the `coffee-taste-journal` repo and `private/coffee_taste/dataset.json`
   are available, use its project skill and `recommend.py`. Report
   `score_mode=private_full`; this includes direct-history adjustments.
2. Otherwise, normalize the candidates into `{"candidates": [...]}`. Resolve
   paths relative to this `SKILL.md`, then run:

   `python3 <skill-dir>/scripts/rank_candidates.py --profile <skill-dir>/profile-prior.json --candidates <file>`

   Report `score_mode=portable_profile`. Its `profile_fit_score` is reproducible
   from exported aggregates; `history_adjustment` is unavailable, not zero.
3. Never compare `private_full.fit_score` directly with portable
   `profile_fit_score` without separating the history adjustment.

## The one thing to say every time

This is a **snapshot** (its date is in `profile-snapshot.md`). It can lag the
user's latest tastings until they re-export from the journal repo. And the
ratings behind it are a **self-selected sample** (they buy what they expect to
like; 0 Disliked) — great at "which of these suits you better", silent on "your
lower bound". Say so; never oversell.

## Workflow — user gives candidate beans

1. For each candidate, map its declared flavor descriptors to flavor **families**
   (see `references/scoring-method.md` for the family list). Seller words are
   claims, not facts — treat them as such.
2. Use the scorer output. Do not hand-invent numeric Fit or novelty values.
   Fit is an **ordering signal, not a probability**.
3. Pick a **稳妥之选**(highest-fit, best-supported) and a **拓展之选**(higher
   novelty that still bridges to a strong family). If a bean is one the user has
   already rated, say so — it's a known-good rebuy, not a discovery.
4. Provenance (estate/region tier, competition accolades) is **context only, not
   a fit driver** — surface it in 理性, never let it move the ordering.

### Output format

For **稳妥之选** and **拓展之选**, each:

```
### [Roaster - full bean name]

**感性** — 2–3 sentences, second person, evocative: connect this bean's declared
flavor line to a thread in the snapshot. Only reference families the bean
actually declares. Never promise the cup will deliver — seller words are claims.

**理性** —
- 预测匹配 / 新奇度(说明来源:命中哪些高分层家族;是否已评过=复购)
- 血统/背书(estate tier / region / accolade)——注明「不进分,仅参考」
- 风险与冲煮观察点
```

Then a one-line table of the remaining ranking (full bean names).

## Ground rules

- **Ratings are the evidence, notes are not.** Never derive a stated preference
  from the user's written words; the rating distribution is the signal.
- **Same farm != same coffee.** Farm-only overlap is a weak hint, not a rating of
  this bean. **Same variety name ≠ same coffee** either (e.g. two different
  "Sudan Rume" farms).
- **Provenance/accolades/price do not move fit.** Pedigree predicts objective
  green quality, not THIS user's liking; the snapshot shows prestigious beans
  scoring mid or low. Price is not modeled at all.
- **Trust the extremes, not the middle.** With ~50 ratings and skewed tiers, the
  middle of any ranking reshuffles on a single new data point. Present the top/
  bottom as solid and the middle as a near-tie.
- Full identifiers always (full bean names, roasters). If the pipeline/snapshot
  and the user disagree, the user is right — tell them to log it in the journal.
"""

SCORING_MD = """\
# Scoring method (portable profile component)

Do not reproduce numeric scores by free-form reasoning. Run the bundled
`scripts/rank_candidates.py` against `profile-prior.json`. The scorer carries the
same profile-fit formula and vocabulary version as the journal export.

## Modes

- `private_full`: journal data is available. Output contains `profile_fit_score`
  plus a direct-history adjustment and a personalized final score.
- `portable_profile`: raw data is absent. Output reproduces
  `profile_fit_score`; history is `unavailable`, never silently treated as zero.

## Flavor families (map descriptors to these)

`fruit.citrus` (lime, orange, lemon, bergamot) · `fruit.stone` (peach, apricot,
nectarine, plum) · `fruit.berry` (strawberry, raspberry, blueberry, mulberry) ·
`fruit.tropical` (mango, pineapple, passionfruit, lychee, soursop) ·
`fruit.dried` (raisin, dried fig, dates) · `fruit.melon` · `fruit.grape` (grape,
riesling, wine) · `floral` (jasmine, rose, orange blossom, honeysuckle) ·
`spice_herbal` (cardamom, mint, lavender, eucalyptus, clove) · `tea` (black tea,
rooibos, oolong) · `sweet.browning` (honey, caramel, sugarcane, chocolate) ·
`fermented_alcoholic` (rum, wine, boozy). Map both Chinese and English terms.

## Fit ordering (higher = better predicted match)

Exact base blend:
- **Sensory (0.75)** — the average standing of the bean's matched families in the
  snapshot. A family in the **top-tier / positive-correlation** set pulls fit up;
  a family with a below-neutral average (e.g. floral) pulls it down. This is the
  dominant term.
- **Origin (0.15)** and **Process (0.10)** — small nudges from how that
  origin/process has rated historically; neutral if unknown.

Then the exported config applies exact capped bonuses for top-tier families,
roaster affinity, and candidate quality claims. Direct history is deliberately
not exported. When private data is available the journal adds it separately;
same-farm-only evidence receives one-third credit.

## Novelty

Portable novelty is exactly: 50% family familiarity + 25% origin familiarity +
25% process familiarity, inverted to 0-100. Private mode may reduce novelty for
positive direct history. Variety is not currently scored.

## What does NOT enter fit

`provenance_reputation` (estate/region tier), `accolades` (competition wins), and
**price** are all context only — never move the ordering. They answer "is this
objectively good / expensive", not "will this user like it".
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", type=Path,
        default=Path.home() / ".claude" / "skills" / "gos-coffee-taste",
        help="Output skill directory.",
    )
    args = parser.parse_args()
    dataset = json.loads((PRIVATE / "dataset.json").read_text())
    result = export_skill(dataset, args.out)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def export_skill(dataset: dict, out: Path) -> dict:
    (out / "references").mkdir(parents=True, exist_ok=True)
    (out / "scripts").mkdir(parents=True, exist_ok=True)

    observations = dataset["observations"]
    scorer_version = hashlib.sha256(PORTABLE_SCORER.read_bytes()).hexdigest()
    portable_profile = build_portable_profile(
        observations,
        dataset_generated_at=dataset["generated_at"],
        scorer_version=scorer_version,
    )

    (out / "profile-snapshot.md").write_text(build_snapshot(observations) + "\n")
    (out / "profile-prior.json").write_text(
        json.dumps(portable_profile, ensure_ascii=False, indent=2) + "\n"
    )
    (out / "SKILL.md").write_text(SKILL_MD)
    (out / "references" / "scoring-method.md").write_text(SCORING_MD)
    shutil.copy2(PORTABLE_SCORER, out / "scripts" / "rank_candidates.py")
    shutil.copyfile(
        SKILL_DIR / "references" / "prestige-regions-estates.md",
        out / "references" / "prestige-regions-estates.md",
    )
    return {
        "out": str(out),
        "files": sorted(str(p.relative_to(out)) for p in out.rglob("*") if p.is_file()),
        "rated_observations": sum(
            1 for o in observations if o["rating"].get("score") is not None
        ),
        "profile_id": portable_profile["profile_id"],
        "scorer_version": scorer_version,
    }


if __name__ == "__main__":
    sys.exit(main())
