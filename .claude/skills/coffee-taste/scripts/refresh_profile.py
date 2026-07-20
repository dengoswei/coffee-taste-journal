#!/usr/bin/env python3
"""Rebuild the taste dataset and render the current profile.

Deterministic by default: every number and preference statement comes from
build_profile_contract over the rebuilt dataset. Pass --narrative to keep a
model-authored emotive summary — it is kept ONLY if it passes
validate_model_narrative (same guardrails as prompt v2); otherwise this
script exits non-zero and prints the violations so the caller can rewrite.

Outputs (all under private/, gitignored):
  private/coffee_taste/dataset.json
  private/coffee_taste/current_profile_flomo_only.md
  private/coffee_taste/current_profile.json
"""
import argparse
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts"))

from evaluate_coffee_taste_prompts import (  # noqa: E402
    TOP_TIER_MIN_OBSERVATIONS,
    build_evidence_packet,
    build_profile_contract,
    ground_profile,
    validate_model_narrative,
)

PRIVATE = REPO / "private" / "coffee_taste"
EMPTY_STORE = {"coffees": [], "bags": [], "brewLogs": []}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--narrative",
        type=Path,
        default=None,
        help="JSON file with headline/narrative/confidence/confidence_reasons "
        "to keep as the emotive summary (guardrail-validated).",
    )
    parser.add_argument(
        "--store",
        type=Path,
        default=None,
        help="App export store.json; omitted -> flomo-only with an empty store.",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip the unit-test gate (not recommended).",
    )
    args = parser.parse_args()

    store_path = args.store
    if store_path is None:
        tmp = tempfile.NamedTemporaryFile(
            "w", suffix="_empty_store.json", delete=False
        )
        json.dump(EMPTY_STORE, tmp)
        tmp.close()
        store_path = Path(tmp.name)

    build = subprocess.run(
        [
            sys.executable,
            str(REPO / "scripts" / "build_coffee_taste_dataset.py"),
            "--store", str(store_path),
            "--flomo", str(PRIVATE / "flomo_observations.json"),
            "--output", str(PRIVATE / "dataset.json"),
        ],
        capture_output=True,
        text=True,
    )
    if build.returncode != 0:
        print(build.stdout)
        print(build.stderr, file=sys.stderr)
        return build.returncode

    if not args.skip_tests:
        tests = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", "Tests", "-p", "test_*.py"],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        if tests.returncode != 0:
            print(tests.stderr, file=sys.stderr)
            return tests.returncode

    dataset = json.loads((PRIVATE / "dataset.json").read_text())
    observations = dataset["observations"]
    contract = build_profile_contract(observations)
    packet = build_evidence_packet(observations)
    cases_path = PRIVATE / "eval_cases.json"
    assertions = (
        json.loads(cases_path.read_text()).get("profile_assertions", {})
        if cases_path.exists() else {}
    )

    narrative_source = "fallback"
    if args.narrative is not None:
        summary = json.loads(args.narrative.read_text())
        violations = validate_model_narrative(summary, contract, assertions)
        if violations:
            print(json.dumps({"narrative_violations": violations}, ensure_ascii=False))
            return 2
        profile = ground_profile(
            {"summary": summary}, contract,
            keep_model_summary=True, assertions=assertions,
        )
        narrative_source = profile["summary_source"]
    else:
        profile = ground_profile({"summary": {}}, contract, keep_model_summary=False)

    kept = profile["summary"]
    stats = dataset["stats"]
    top_tier = [
        {"category": row["category"], "top_tier_count": row["top_tier_count"]}
        for row in packet.get("top_tier_family_stats", [])
        if row["top_tier_count"] >= TOP_TIER_MIN_OBSERVATIONS
    ]
    today = datetime.now(timezone.utc).date().isoformat()
    lines = [
        f"# 当前咖啡风味画像（{today}）",
        "",
        f"生成时间：{datetime.now(timezone.utc).isoformat()}  ",
        f"叙述来源：{narrative_source}"
        "（model = 经 validate_model_narrative 确定性护栏校验；fallback = 契约模板句）。  ",
        "其余全部字段：`build_profile_contract` 确定性代码输出。  ",
        f"数据：{stats['rated_observations']} 条明确评分 / "
        f"{stats['substantive_first_person_notes']} 条第一人称实饮描述 / "
        f"合并重复 {stats['collapsed_duplicates']} 条。",
        "",
        f"## {kept['headline']}",
        "",
        kept["narrative"],
        "",
        f"置信度：{kept['confidence']}（与确定性契约钳制对齐）",
        "",
        *[f"- {reason}" for reason in kept.get("confidence_reasons", [])],
        "",
        "### 已知偏好（有第一人称文字直接支持）",
        "",
        *(
            [
                f"- {item['statement']}（置信度 {item['confidence']}；"
                f"证据：{', '.join(item['evidence_ids'])}）"
                for item in contract["known_preferences_allowed"]
            ] or ["- 暂无"]
        ),
        "",
        "### 高分层集中信号（Great/Loved 层，评分集中是最强的情感信号）",
        "",
        *(
            [
                f"- {row['category']}：{row['top_tier_count']} 支高分豆带此家族描述"
                for row in top_tier
            ] or ["- 暂无（高分层不足 2 支重合家族）"]
        ),
        "",
        "### 可能偏好（评分与风味家族的相关性，多为卖方/混合来源描述）",
        "",
        *[
            f"- {fam['label']}（{fam['observations']} 条记录，加权评分 {fam['weighted_rating']}/4）"
            for fam in contract["likely_sensory_families"]
        ],
        "",
        "### 外在相关性（只是相关，不当作因果偏好）",
        "",
        *[f"- {statement}" for statement in contract["extrinsic_correlations_allowed"]],
        "",
        "### 仍然未知 / 欠采样",
        "",
        *[f"- {unknown}" for unknown in contract["required_unknowns"]],
        "",
        "### 数据质量与局限",
        "",
        *[f"- {limitation}" for limitation in contract["data_quality"]["limitations"]],
        "",
        "### 杯感结构（逐维状态）",
        "",
        *[
            f"- {axis}: {status}"
            for axis, status in contract["required_structure"].items()
        ],
        "",
    ]

    out_md = PRIVATE / "current_profile_flomo_only.md"
    out_md.write_text("\n".join(lines))
    (PRIVATE / "current_profile.json").write_text(
        json.dumps(profile, ensure_ascii=False, indent=2) + "\n"
    )

    print(json.dumps({
        "report": str(out_md),
        "narrative_source": narrative_source,
        "rated_observations": stats["rated_observations"],
        "collapsed_duplicates": stats["collapsed_duplicates"],
        "top_tier_families": top_tier,
        "known_preferences": len(contract["known_preferences_allowed"]),
        "likely_families": len(contract["likely_sensory_families"]),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
