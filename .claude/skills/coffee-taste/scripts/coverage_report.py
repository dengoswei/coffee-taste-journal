#!/usr/bin/env python3
"""Report what the current profile is actually built on, and where the gaps are.

Read-only. This is the "证据基础" panel: how much data, how the like-levels
are distributed, which roasters/origins/processes are represented, and — the
part that drives what to buy or log next — which cells are too thin to
support a claim.

The point is not just to describe coverage but to make undersampling
actionable: a family or roaster with 1-2 observations cannot move the
profile, and a rating tier with almost no members makes the whole model
sensitive to a single bean.

Usage: python3 coverage_report.py [--json]
"""
import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts"))

from evaluate_coffee_taste_prompts import (  # noqa: E402
    TOP_TIER_MIN_OBSERVATIONS,
    build_evidence_packet,
)

PRIVATE = REPO / "private" / "coffee_taste"

# Canonical like-levels, worst to best. Both label families map onto the same
# 0-4 scale (app Verdict / curated Flomo labels).
TIERS = [
    (0, "Disliked", ["Disliked"]),
    (1, "So So / General", ["So So", "General"]),
    (2, "Ok", ["Ok", "OK"]),
    (3, "Liked / Good", ["Liked", "Good"]),
    (4, "Loved / Great", ["Loved", "Great"]),
]
# Below this an entity/roaster/family cannot meaningfully move the profile.
THIN_THRESHOLD = 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    dataset = json.loads((PRIVATE / "dataset.json").read_text())
    obs = dataset["observations"]
    stats = dataset["stats"]
    rated = [o for o in obs if o["rating"].get("score") is not None]
    packet = build_evidence_packet(obs)

    tier_counts = {}
    for score, name, _labels in TIERS:
        tier_counts[name] = sum(1 for o in rated if o["rating"]["score"] == score)

    sources = Counter(o["source"] for o in obs)

    def facet(key: str) -> list[tuple[str, int, float | None]]:
        buckets: dict[str, list[float]] = defaultdict(list)
        for o in rated:
            value = (o["coffee"].get(key) or "").strip()
            if value:
                buckets[value].append(o["rating"]["score"])
        rows = [
            (name, len(scores), round(sum(scores) / len(scores), 2))
            for name, scores in buckets.items()
        ]
        return sorted(rows, key=lambda r: (-r[1], r[0]))

    roasters = facet("roaster")
    origins = facet("origin")
    processes = facet("process")

    families = sorted(
        (
            (row["feature"], row["observations"], row["weighted_rating"])
            for row in packet["category_stats"]
        ),
        key=lambda r: -r[1],
    )
    top_tier = {
        row["category"]: row["top_tier_count"]
        for row in packet.get("top_tier_family_stats", [])
    }

    payload = {
        "totals": {
            "observations": stats["observations"],
            "rated": stats["rated_observations"],
            "unrated_exposures": stats["unrated_exposures"],
            "first_person_notes": stats["substantive_first_person_notes"],
            "collapsed_duplicates": stats["collapsed_duplicates"],
        },
        "sources": dict(sources),
        "tiers": tier_counts,
        "roasters": roasters,
        "origins": origins,
        "processes": processes,
        "families": families,
        "top_tier_families": top_tier,
        "gaps": {
            "thin_roasters": [r[0] for r in roasters if r[1] < THIN_THRESHOLD],
            "thin_families": [f[0] for f in families if f[1] < THIN_THRESHOLD],
            "tiers_below_threshold": [
                name for name, n in tier_counts.items() if n < TOP_TIER_MIN_OBSERVATIONS
            ],
        },
    }

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    t = payload["totals"]
    print("## 证据基础")
    print()
    print(f"- 观察总数 **{t['observations']}**（有评分 **{t['rated']}**，"
          f"仅曝光无评分 {t['unrated_exposures']}，合并重复 {t['collapsed_duplicates']}）")
    print(f"- 第一人称实饮描述 **{t['first_person_notes']}** 条 —— 最稀缺的证据类型")
    print(f"- 来源：" + "，".join(f"{k} {v}" for k, v in sorted(sources.items())))
    print()
    print("### 喜好档位分布")
    print()
    print("| 档位 | 数量 | 占比 |")
    print("|---|---|---|")
    for _score, name, _labels in reversed(TIERS):
        n = tier_counts[name]
        pct = f"{n / len(rated) * 100:.0f}%" if rated else "—"
        print(f"| {name} | {n} | {pct} |")
    print()
    print("### 烘焙商覆盖")
    print()
    print("| 烘焙商 | 记录数 | 平均分(0-4) |")
    print("|---|---|---|")
    for name, n, avg in roasters:
        print(f"| {name} | {n} | {avg} |")
    print()
    print("### 风味家族覆盖")
    print()
    print("| 家族 | 记录数 | 加权评分 | 高分层命中 |")
    print("|---|---|---|---|")
    for name, n, wr in families:
        hits = top_tier.get(name, 0)
        mark = f"{hits} ✅" if hits >= TOP_TIER_MIN_OBSERVATIONS else str(hits)
        print(f"| {name} | {n} | {wr} | {mark} |")
    print()
    print("### 缺口（下一步该补什么）")
    print()
    gaps = payload["gaps"]
    if gaps["tiers_below_threshold"]:
        print(f"- **档位过薄**：{'、'.join(gaps['tiers_below_threshold'])} "
              f"—— 少于 {TOP_TIER_MIN_OBSERVATIONS} 条，单支豆子的进出就能翻转结论")
    if gaps["thin_families"]:
        print(f"- **风味家族仅 1 条记录**：{'、'.join(gaps['thin_families'])} "
              "—— 无法支撑任何偏好判断")
    if gaps["thin_roasters"]:
        print(f"- **烘焙商仅 1 条记录**：{'、'.join(gaps['thin_roasters'])} "
              "—— roaster_affinity_bonus 对这些几乎没有依据")
    print(f"- **第一人称描述仅 {t['first_person_notes']} 条** —— "
          "「已知偏好」只能从这些里长出来，其余全是评分相关性")
    return 0


if __name__ == "__main__":
    sys.exit(main())
