#!/usr/bin/env python3
"""Report what a CoffeeJournal store.json would contribute, without importing it.

Read-only. Use this to sanity-check an app export before merging it into the
dataset: it reports how many brew logs carry usable verdicts, how many
first-person tasting notes are substantive, and — importantly — how many
bean-level verdicts (Coffee.verdict) would be DROPPED because the parser only
reads brewLogs[].verdict.

Usage: python3 inspect_app_export.py <path/to/store.json>
"""
import json
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts"))

from build_coffee_taste_dataset import (  # noqa: E402
    PLACEHOLDER_NOTES,
    RATING_SCORES,
    category_matches,
    normalized_text,
)

VALID_VERDICTS = {"Loved", "Liked", "Ok", "Disliked"}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    store = json.loads(path.read_text())

    coffees = store.get("coffees", [])
    logs = store.get("brewLogs", [])
    coffee_ids = {c.get("id") for c in coffees}
    logged_ids = {log.get("coffeeID") for log in logs}

    print(f"文件: {path}")
    print(f"schemaVersion: {store.get('schemaVersion')}")
    print(f"coffees: {len(coffees)} | brewLogs: {len(logs)} | bags: {len(store.get('bags', []))} (bags 不被读取)")
    print()

    orphans = [log for log in logs if log.get("coffeeID") not in coffee_ids]
    if orphans:
        print(f"⚠️  {len(orphans)} 条 brewLog 的 coffeeID 对不上任何 coffee —— 这些会被整条跳过")

    print("=== brewLogs verdict 分布(真正的评分来源) ===")
    verdicts = Counter(log.get("verdict") for log in logs)
    for label, n in verdicts.most_common():
        score = RATING_SCORES.get(label)
        flag = "" if label in VALID_VERDICTS else "  ⚠️ 非法值,评分会作废"
        print(f"  {str(label):>10}: {n:>3}  -> score {score}{flag}")

    substantive = sum(
        1 for log in logs
        if normalized_text((log.get("tastingNote") or "").strip()) not in PLACEHOLDER_NOTES
    )
    print()
    print(f"=== 第一人称实饮描述 ===")
    print(f"  有实质内容: {substantive} / {len(logs)}  (占位符/空白的评分权重降到 0.72)")

    print()
    print("=== 会被丢掉的 bean-level 评分 ===")
    dropped = [
        c for c in coffees
        if c.get("verdict") and c.get("id") not in logged_ids
    ]
    print(f"  有 Coffee.verdict 但无任何 brewLog: {len(dropped)} 支")
    for c in dropped[:15]:
        print(f"    [{c.get('verdict')}] {c.get('roaster')} - {c.get('name')}")
    if len(dropped) > 15:
        print(f"    ... 另有 {len(dropped) - 15} 支")
    if dropped:
        print("  → 当前 parse_app 只读 brewLogs[].verdict，这些评分会记为 rating_weight 0.0。")
        print("    如果数量可观，应先补上 Coffee.verdict 回退逻辑再导入。")

    print()
    print("=== 风味词覆盖 ===")
    unmatched = Counter()
    total_terms = 0
    for c in coffees:
        for term in c.get("flavorNotes", []):
            term = str(term).strip()
            if not term:
                continue
            total_terms += 1
            if not category_matches([term]):
                unmatched[term] += 1
    print(f"  风味词总数: {total_terms} | 未能归入任何风味家族: {sum(unmatched.values())}")
    if unmatched:
        print("  未匹配词频(需要考虑补词典):")
        for term, n in unmatched.most_common(20):
            print(f"    {term} × {n}")

    print()
    print("=== 预计净增 ===")
    rated = sum(
        1 for log in logs
        if log.get("coffeeID") in coffee_ids
        and RATING_SCORES.get(log.get("verdict")) is not None
    )
    exposures = sum(1 for c in coffees if c.get("id") not in logged_ids)
    print(f"  有效评分观察: +{rated}")
    print(f"  仅曝光(无评分): +{exposures}")
    print(f"  当前数据集有效评分: 36 (纯 flomo)")
    print(f"  合并后约: {36 + rated} —— 去重前")
    return 0


if __name__ == "__main__":
    sys.exit(main())
