#!/usr/bin/env python3
"""Evaluate coffee-profile and recommendation prompts with leakage-safe holdouts."""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from build_coffee_taste_dataset import category_matches, normalized_text, quality_matches


DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"
DEFAULT_MODEL = "doubao-seed-1-6-flash-250828"
VERSIONS = ("v0", "v1", "v2")
# Versions whose output goes through deterministic grounding. v2 additionally
# keeps the model-authored narrative when it passes validate_model_narrative.
GROUNDED_VERSIONS = ("v1", "v2")
# Version whose grounded output feeds the private product report. v2 may take
# over only after it meets the adoption rule in
# docs/coffee-taste-profile-and-recommendation.md (pairwise >= v1 weighted AND
# unweighted, no tracked-challenge regression).
PRODUCT_VERSION = "v1"
# Single source of truth for the frontier fit gate (prompt v1/v2 rule text,
# live-shortlist novelty pool, and grounded frontier eligibility).
FRONTIER_MIN_FIT = 60.0
# Narrative length band in characters; must match the prompt spec (90-180).
NARRATIVE_LENGTH_RANGE = (90, 180)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def read_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return read_json(path)


def config_api_key(config: dict[str, Any]) -> str | None:
    value = config.get("api_key")
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("secret"), str):
        return value["secret"]
    return None


def parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.strip("`")
        if stripped.startswith("json"):
            stripped = stripped[4:].strip()
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start == -1 or end <= start:
            raise
        parsed = json.loads(stripped[start : end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("model output is not a JSON object")
    return parsed


def extract_response_text(body: dict[str, Any]) -> str:
    output_text = body.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text
    texts: list[str] = []
    for item in body.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if isinstance(content, dict) and isinstance(content.get("text"), str):
                texts.append(content["text"])
    if not texts:
        raise ValueError("response has no output text")
    return "\n".join(texts)


def call_responses(
    api_key: str,
    base_url: str,
    model: str,
    prompt: str,
    timeout: int,
    max_output_tokens: int,
    thinking_type: str,
) -> dict[str, Any]:
    payload = {
        "model": model,
        "input": [{
            "role": "user",
            "content": [{"type": "input_text", "text": prompt}],
        }],
        "temperature": 0.0,
        "max_output_tokens": max_output_tokens,
        "thinking": {"type": thinking_type},
    }
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/responses",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw_body = response.read().decode("utf-8")
            if not raw_body.strip():
                raise RuntimeError("Ark returned an empty response body")
            body = json.loads(raw_body)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
    try:
        text = extract_response_text(body)
    except Exception as exc:
        diagnostic = json.dumps(body, ensure_ascii=False)[:2000]
        raise RuntimeError(f"{exc}; response body: {diagnostic}") from exc
    return {
        "status": 200,
        "elapsed_ms": int((time.time() - started) * 1000),
        "usage": body.get("usage"),
        "raw_text": text,
        "parsed": parse_json_object(text),
    }


def json_block(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def render_template(path: Path, replacements: dict[str, Any]) -> str:
    text = path.read_text()
    for key, value in replacements.items():
        text = text.replace("{{" + key + "}}", json_block(value))
    missing = re.findall(r"\{\{[A-Z0-9_]+\}\}", text)
    if missing:
        raise ValueError(f"unresolved prompt placeholders in {path}: {missing}")
    return text


def compact_observation(item: dict[str, Any]) -> dict[str, Any]:
    note = item.get("user_note") or ""
    if not item["evidence"].get("substantive_first_person_note"):
        note = ""
    return {
        "id": item["id"],
        "entity_id": item["entity_id"],
        "date": item.get("date"),
        "coffee": item["coffee"],
        "rating": item["rating"],
        "descriptors": item["sensory"].get("descriptors", []),
        "descriptor_categories": item["sensory"].get("descriptor_categories", []),
        "quality_signals": item["sensory"].get("quality_signals", []),
        "claimed_quality_signals": item["sensory"].get("claimed_quality_signals", []),
        "user_note": note,
        "descriptor_origin": item["sensory"].get("descriptor_origin"),
        "evidence": item["evidence"],
    }


def weighted_feature_stats(
    observations: list[dict[str, Any]],
    extractor: Any,
) -> list[dict[str, Any]]:
    values: dict[str, dict[str, float]] = defaultdict(lambda: {
        "positive_weight": 0.0,
        "lower_weight": 0.0,
        "score_weighted": 0.0,
        "rating_weight": 0.0,
        "observations": 0.0,
    })
    for item in observations:
        score = item["rating"].get("score")
        weight = float(item["evidence"].get("rating_weight") or 0)
        if score is None or weight <= 0:
            continue
        for feature in set(extractor(item)):
            row = values[str(feature)]
            row["observations"] += 1
            row["score_weighted"] += score * weight
            row["rating_weight"] += weight
            if score >= 3:
                row["positive_weight"] += weight
            else:
                row["lower_weight"] += weight
    rows = []
    for feature, row in values.items():
        total = row["rating_weight"]
        rows.append({
            "feature": feature,
            "observations": int(row["observations"]),
            "weighted_rating": round(row["score_weighted"] / total, 3) if total else None,
            "positive_weight": round(row["positive_weight"], 3),
            "lower_weight": round(row["lower_weight"], 3),
            "contrast": round(row["positive_weight"] - row["lower_weight"], 3),
        })
    return sorted(rows, key=lambda row: (-row["contrast"], -row["observations"], row["feature"]))


def build_evidence_packet(observations: list[dict[str, Any]]) -> dict[str, Any]:
    rated = [item for item in observations if item["rating"].get("score") is not None]
    substantive = [
        item for item in observations
        if item["evidence"].get("substantive_first_person_note")
    ]
    ranked = sorted(
        rated,
        key=lambda item: (
            item["rating"]["score"],
            item["evidence"].get("rating_weight", 0),
            item.get("date") or "",
        ),
        reverse=True,
    )
    lower = sorted(
        rated,
        key=lambda item: (
            item["rating"]["score"],
            -float(item["evidence"].get("rating_weight", 0)),
            item.get("date") or "",
        ),
    )
    return {
        "method_notes": [
            "Ratings are affective evidence.",
            "Flavor descriptors may be seller claims unless a substantive first-person note confirms them.",
            "Unrated exposure is not preference evidence.",
            "Feature statistics are correlations, not causal rules.",
        ],
        "data_quality": {
            "observations": len(observations),
            "rated_observations": len(rated),
            "substantive_first_person_notes": len(substantive),
            "placeholder_or_metadata_only_ratings": len(rated) - len(substantive),
            "sources": sorted({item["source"] for item in observations}),
        },
        "category_stats": weighted_feature_stats(
            observations,
            lambda item: item["sensory"].get("descriptor_categories", []),
        ),
        "quality_signal_stats": weighted_feature_stats(
            observations,
            lambda item: item["sensory"].get("quality_signals", []),
        ),
        "origin_stats": weighted_feature_stats(
            observations,
            lambda item: [item["coffee"].get("origin")] if item["coffee"].get("origin") else [],
        ),
        "process_stats": weighted_feature_stats(
            observations,
            lambda item: [item["coffee"].get("process")] if item["coffee"].get("process") else [],
        ),
        "variety_stats": weighted_feature_stats(
            observations,
            lambda item: [item["coffee"].get("variety")] if item["coffee"].get("variety") else [],
        ),
        "high_evidence_examples": [compact_observation(item) for item in ranked[:10]],
        "lower_rated_contrasts": [compact_observation(item) for item in lower[:8]],
        "substantive_notes": [compact_observation(item) for item in substantive],
    }


CATEGORY_LABELS = {
    "fruit.berry": "莓果",
    "fruit.citrus": "柑橘",
    "fruit.stone": "核果",
    "fruit.tropical": "热带水果",
    "fruit.dried": "果干",
    "fruit.grape": "葡萄/酒香联想",
    "fruit.pome": "仁果",
    "fruit.melon": "瓜果",
    "floral": "花香",
    "tea": "茶感",
    "sweet.browning": "糖化/焦糖甜香",
    "cocoa_nut": "可可/坚果",
    "spice_herbal": "香料/草本",
    "fermented_alcoholic": "发酵/酒香联想",
}


def evidence_ids_for_signal(
    observations: list[dict[str, Any]],
    signals: set[str],
    minimum_score: int = 3,
) -> list[str]:
    return [
        item["id"]
        for item in observations
        if item["rating"].get("score") is not None
        and item["rating"]["score"] >= minimum_score
        and item["evidence"].get("substantive_first_person_note")
        and signals.intersection(item["sensory"].get("quality_signals", []))
    ]


def evidence_ids_for_category(
    observations: list[dict[str, Any]],
    category: str,
    positive: bool,
    limit: int = 4,
) -> list[str]:
    matches = [
        item for item in observations
        if category in item["sensory"].get("descriptor_categories", [])
        and item["rating"].get("score") is not None
        and ((item["rating"]["score"] >= 3) if positive else (item["rating"]["score"] <= 2))
    ]
    matches.sort(
        key=lambda item: (
            item["rating"]["score"],
            item["evidence"].get("rating_weight", 0),
            item.get("date") or "",
        ),
        reverse=positive,
    )
    return [item["id"] for item in matches[:limit]]


def correlation_statements(
    rows: list[dict[str, Any]],
    kind: str,
    minimum_observations: int = 2,
    limit: int = 4,
) -> list[str]:
    selected = [
        row for row in rows
        if row["observations"] >= minimum_observations
        and row["contrast"] > 0
    ][:limit]
    return [
        f"在当前自选样本中，{kind}“{row['feature']}”与较高评分相关"
        f"（{row['observations']} 条，非因果偏好）。"
        for row in selected
    ]


def build_profile_contract(observations: list[dict[str, Any]]) -> dict[str, Any]:
    packet = build_evidence_packet(observations)
    clarity_ids = evidence_ids_for_signal(observations, {"clarity_positive"})
    acid_sweet_ids = evidence_ids_for_signal(
        observations,
        {"acid_sweet_balance_positive"},
    )
    clean_ids = evidence_ids_for_signal(
        observations,
        {"cleanliness_positive", "fermentation_clean_positive"},
    )
    temperature_ids = [
        item["id"]
        for item in observations
        if item["evidence"].get("substantive_first_person_note")
        and item["rating"].get("score", 0) >= 3
        and any(term in normalized_key(item.get("user_note")) for term in ("温度", "冷", "cool"))
    ]
    variability_ids = evidence_ids_for_signal(
        observations,
        {"brew_variability"},
        minimum_score=0,
    )

    known_preferences: list[dict[str, Any]] = []
    if clarity_ids:
        known_preferences.append({
            "statement": "偏好风味表达明显、容易辨识的杯子",
            "evidence_ids": clarity_ids,
            "confidence": 0.72 if len(clarity_ids) >= 2 else 0.55,
        })
    if acid_sweet_ids:
        known_preferences.append({
            "statement": "偏好酸与甜彼此协调，而不是只追求酸度强弱",
            "evidence_ids": acid_sweet_ids,
            "confidence": 0.52,
        })
    if clean_ids:
        known_preferences.append({
            "statement": "偏好干净、没有突兀发酵感抢戏的表达",
            "evidence_ids": clean_ids,
            "confidence": 0.58,
        })

    likely_rows = [
        row for row in packet["category_stats"]
        if row["observations"] >= 3
        and row["weighted_rating"] is not None
        and row["weighted_rating"] >= 2.8
        and row["contrast"] > 1
    ][:7]
    likely_families = [
        {
            "category": row["feature"],
            "label": CATEGORY_LABELS.get(row["feature"], row["feature"]),
            "observations": row["observations"],
            "weighted_rating": row["weighted_rating"],
            "evidence_ids": evidence_ids_for_category(
                observations,
                row["feature"],
                positive=True,
            ),
            "counterevidence_ids": evidence_ids_for_category(
                observations,
                row["feature"],
                positive=False,
                limit=2,
            ),
            "evidence_type": "rating_correlation_with_mostly_seller_or_mixed_descriptors",
        }
        for row in likely_rows
    ]

    axis_facts: list[dict[str, Any]] = []
    if clarity_ids:
        axis_facts.append({
            "axis": "风味辨识度",
            "direction": "偏好明显、容易辨识的风味表达",
            "strength": 0.78,
            "confidence": 0.72 if len(clarity_ids) >= 2 else 0.55,
            "evidence_ids": clarity_ids,
            "counterevidence_ids": variability_ids[:2],
            "description": "这是少数有第一人称实饮文字直接支持的偏好；同一支豆也出现过冲煮波动。",
        })
    if acid_sweet_ids:
        axis_facts.append({
            "axis": "酸甜关系",
            "direction": "偏好酸甜协调",
            "strength": 0.64,
            "confidence": 0.52,
            "evidence_ids": acid_sweet_ids,
            "counterevidence_ids": [],
            "description": "目前只能确认酸甜协调得到正面反馈，不能据此推断偏好的酸度强度。",
        })
    if clean_ids:
        axis_facts.append({
            "axis": "干净度与发酵感",
            "direction": "偏好干净、发酵感不抢戏的结果",
            "strength": 0.72,
            "confidence": 0.58,
            "evidence_ids": clean_ids,
            "counterevidence_ids": [],
            "description": "实验性处理本身不是负面；关键是杯中是否仍清楚、干净、没有突兀发酵感。",
        })
    if likely_families:
        family_names = "、".join(item["label"] for item in likely_families[:5])
        axis_facts.append({
            "axis": "水果与甜香家族",
            "direction": f"评分相关性较强的家族包括{family_names}",
            "strength": 0.7,
            "confidence": 0.48,
            "evidence_ids": list(dict.fromkeys(
                evidence_id
                for family in likely_families[:5]
                for evidence_id in family["evidence_ids"]
            ))[:8],
            "counterevidence_ids": list(dict.fromkeys(
                evidence_id
                for family in likely_families[:5]
                for evidence_id in family["counterevidence_ids"]
            ))[:4],
            "description": "这是评分与豆袋/混合来源描述的相关性，不等同于已确认喝到每个具体风味词。",
        })

    required_structure = {
        "acidity": (
            "已知偏好酸甜协调；偏好的酸度强度未知"
            if acid_sweet_ids else "偏好的酸度质量与强度均证据不足"
        ),
        "sweetness": (
            "已知甜感需要与酸质协调；偏好的甜度强度未知"
            if acid_sweet_ids else "偏好的甜度质量与强度均证据不足"
        ),
        "mouthfeel": "证据不足",
        "aftertaste": "证据不足",
        "clarity": (
            "偏好明显、容易辨识的风味表达（中等置信）"
            if clarity_ids else "证据不足"
        ),
        "cleanliness": (
            "偏好干净、无突兀发酵感的表达（低至中等置信）"
            if clean_ids else "证据不足"
        ),
        "complexity": "证据不足",
        "fermentation_tolerance": (
            "可接受实验性处理，但偏好结果干净；具体容忍上限未知"
            if clean_ids
            else "处理法与评分存在混合结果；对发酵感的具体容忍上限未知"
        ),
        "temperature_evolution": (
            "有高评分样本在降温后风味更明显；是否为稳定偏好仍未知"
            if temperature_ids else "证据不足"
        ),
    }
    rated = sum(item["rating"].get("score") is not None for item in observations)
    substantive = sum(
        bool(item["evidence"].get("substantive_first_person_note"))
        for item in observations
    )
    likely_labels = [item["label"] for item in likely_families]
    # Part lengths are tuned so every branch combination lands inside
    # NARRATIVE_LENGTH_RANGE; test_fallback_narrative_satisfies_length_spec pins this.
    narrative_parts = ["你像是在寻找一杯有清楚主线、而不是只靠标签取胜的咖啡，愿意为真实的杯中体验买单。"]
    if clarity_ids and acid_sweet_ids:
        narrative_parts.append("风味最好能自己亮起来，酸与甜也要彼此托住。")
    elif clarity_ids:
        narrative_parts.append("目前最直接的信号，是你会为明显、容易辨识的风味表达加分。")
    elif acid_sweet_ids:
        narrative_parts.append("目前最直接的信号，是你会为酸与甜彼此协调的杯子加分。")
    if clean_ids:
        narrative_parts.append("实验性处理并不构成障碍，但不希望突兀发酵感抢戏。")
    if temperature_ids:
        narrative_parts.append("降温后风味继续展开，曾给你留下很深的正面印象。")
    narrative_parts.append("多数具体风味词仍来自豆袋或混合来源，口感、余韵和强度偏好还需要更多实饮记录来确认，这份画像会随每一支新豆继续生长。")
    headline = (
        "喜欢风味轮廓清楚、酸甜彼此托住的杯子"
        if clarity_ids and acid_sweet_ids
        else "偏好正在收敛，但直接实饮证据仍然稀疏"
    )
    return {
        "known_preferences_allowed": known_preferences,
        "axis_facts": axis_facts,
        "likely_sensory_families": likely_families,
        "required_structure": required_structure,
        "required_unknowns": [
            "偏好的烘焙度",
            "偏好的醇厚度与口感质地",
            "偏好的余韵长度与类型",
            "可接受的苦味范围",
            "偏好的酸度强度",
            "对发酵感的具体容忍上限",
        ],
        "extrinsic_correlations_allowed": [
            *correlation_statements(packet["origin_stats"], "产地", limit=3),
            *correlation_statements(packet["process_stats"], "处理法", limit=3),
            *correlation_statements(packet["variety_stats"], "品种", limit=2),
        ],
        "likely_preferences_allowed": [
            f"评分记录与{label}风味家族呈正相关，但多数描述不是第一人称确认。"
            for label in likely_labels
        ],
        "data_quality": {
            "rated_observations": rated,
            "substantive_notes": substantive,
            "limitations": [
                "历史记录高度受主动选购影响，负面样本较少。",
                "多数风味词来自豆袋或无法区分来源的 Flomo 摘录。",
                "第一人称实饮描述很少，具体口感与结构偏好仍欠采样。",
                "冲煮配方与状态可能造成同一咖啡的评分波动。",
            ],
        },
        "fallback_summary": {
            "headline": headline,
            "narrative": "".join(narrative_parts),
            "confidence": 0.6,
            "confidence_reasons": [
                f"有 {rated} 条明确评分，但只有 {substantive} 条第一人称实饮描述。",
                "清晰度、酸甜协调和干净度有直接文字证据。",
                "具体水果家族主要是评分与卖方/混合来源描述的相关性。",
            ],
        },
    }


# Undersampled dimensions (see required_unknowns) that a kept narrative may
# mention only alongside an explicit hedge marker.
UNDERSAMPLED_DIMENSION_TERMS = ("烘焙", "醇厚", "口感", "余韵", "苦味")
HEDGE_MARKERS = ("未知", "不确定", "仍需", "还需要", "证据不足", "欠采样", "还不清楚", "有待")


def validate_model_narrative(
    summary: dict[str, Any],
    contract: dict[str, Any],
    assertions: dict[str, Any],
) -> list[str]:
    """Deterministic guardrails deciding whether a model-authored summary is kept.

    Returns violation labels; empty means the summary may be kept verbatim.
    """
    violations: list[str] = []
    narrative = str(summary.get("narrative") or "")
    headline = str(summary.get("headline") or "")
    if not (NARRATIVE_LENGTH_RANGE[0] <= len(narrative) <= NARRATIVE_LENGTH_RANGE[1]):
        violations.append("narrative_length_out_of_range")
    if not headline or len(headline) > 30:
        violations.append("headline_missing_or_too_long")
    text = normalized_key(f"{headline} {narrative}")
    for phrase in assertions.get("forbidden_absolute_phrases", []):
        if normalized_key(phrase) in text:
            violations.append("forbidden_absolute_phrase")
            break
    for term in assertions.get("known_preference_forbidden_terms", []):
        if normalized_key(term) in text:
            violations.append("extrinsic_term_in_narrative")
            break
    if any(term in text for term in UNDERSAMPLED_DIMENSION_TERMS):
        if not any(marker in text for marker in HEDGE_MARKERS):
            violations.append("unhedged_undersampled_dimension")
    # Families the deterministic contract itself asserts (fallback narrative and
    # known-preference statements) are safe to echo; anything beyond that set is
    # an invented flavor claim.
    contract_text = [
        str((contract.get("fallback_summary") or {}).get("narrative") or ""),
        *[
            str(item.get("statement") or "")
            for item in contract.get("known_preferences_allowed", [])
        ],
    ]
    allowed_families = {
        item["category"] for item in contract.get("likely_sensory_families", [])
    } | set(category_matches(contract_text))
    mentioned_families = set(category_matches([narrative, headline]))
    if not mentioned_families.issubset(allowed_families):
        violations.append("invented_flavor_family")
    return violations


def ground_profile(
    profile: dict[str, Any],
    contract: dict[str, Any],
    keep_model_summary: bool = False,
    assertions: dict[str, Any] | None = None,
) -> dict[str, Any]:
    grounded = dict(profile)
    grounded["summary"] = contract["fallback_summary"]
    grounded["summary_source"] = "fallback"
    grounded["narrative_violations"] = []
    if keep_model_summary:
        model_summary = profile.get("summary") or {}
        violations = validate_model_narrative(
            model_summary,
            contract,
            assertions or {},
        )
        grounded["narrative_violations"] = violations
        if not violations:
            kept = dict(model_summary)
            fallback_confidence = float(
                contract["fallback_summary"].get("confidence", 0.6)
            )
            model_confidence = kept.get("confidence")
            kept["confidence"] = (
                min(float(model_confidence), fallback_confidence)
                if isinstance(model_confidence, (int, float))
                else fallback_confidence
            )
            grounded["summary"] = kept
            grounded["summary_source"] = "model"
    grounded["preference_axes"] = contract["axis_facts"]
    sensory = dict(grounded.get("sensory_profile") or {})
    likely = contract["likely_sensory_families"]
    sensory["dominant_families"] = [item["label"] for item in likely[:4]]
    sensory["secondary_families"] = [item["label"] for item in likely[4:7]]
    sensory["structure"] = contract["required_structure"]
    grounded["sensory_profile"] = sensory
    grounded["extrinsic_correlations"] = contract["extrinsic_correlations_allowed"]
    grounded["known_preferences"] = [
        item["statement"] for item in contract["known_preferences_allowed"]
    ]
    grounded["likely_preferences"] = contract["likely_preferences_allowed"]
    grounded["unknowns"] = contract["required_unknowns"]
    grounded["data_quality"] = contract["data_quality"]
    return grounded


def normalized_key(value: Any) -> str:
    return normalized_text(str(value or ""))


def prior_stat_map(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {normalized_key(row["feature"]): row for row in rows}


def identity_tokens(value: str) -> set[str]:
    stop_words = {
        "coffee", "coffees", "finca", "farm", "estate", "station", "washing",
        "gesha", "geisha", "natural", "washed", "anaerobic",
        "\u5496\u5561", "\u5e84\u56ed", "\u5904\u7406", "\u6c34\u6d17", "\u65e5\u6652", "\u538c\u6c27", "\u7470\u590f", "\u871c\u5904\u7406",
    }
    normalized = normalized_key(value)
    ascii_tokens = {
        token for token in re.findall(r"[a-z0-9]+", normalized)
        if len(token) >= 4
    }
    cjk_tokens = {
        token for token in re.findall(r"[\u3400-\u9fff]+", normalized)
        if len(token) >= 2
    }
    return {token for token in ascii_tokens | cjk_tokens if token not in stop_words}


def significant_identity_tokens(candidate: dict[str, Any]) -> set[str]:
    tokens = identity_tokens(" ".join([
        str(candidate.get("name") or ""),
        str(candidate.get("farm") or ""),
    ]))
    return tokens


def direct_history_match(
    candidate: dict[str, Any],
    observations: list[dict[str, Any]],
) -> dict[str, Any]:
    tokens = significant_identity_tokens(candidate)
    if not tokens:
        return {
            "matched_tokens": [],
            "rated_observations": 0,
            "weighted_rating": None,
            "observation_ids": [],
        }
    matches = []
    for item in observations:
        score = item["rating"].get("score")
        weight = float(item["evidence"].get("rating_weight") or 0)
        if score is None or weight <= 0:
            continue
        historical_tokens = identity_tokens(" ".join([
            str(item["coffee"].get("name") or ""),
            str(item["coffee"].get("farm") or ""),
        ]))
        if tokens.intersection(historical_tokens):
            matches.append(item)
    total_weight = sum(float(item["evidence"]["rating_weight"]) for item in matches)
    weighted_rating = (
        sum(
            item["rating"]["score"] * float(item["evidence"]["rating_weight"])
            for item in matches
        ) / total_weight
        if total_weight else None
    )
    return {
        "matched_tokens": sorted({
            token
            for token in tokens
            if any(
                token in identity_tokens(" ".join([
                    str(item["coffee"].get("name") or ""),
                    str(item["coffee"].get("farm") or ""),
                ]))
                for item in matches
            )
        }),
        "rated_observations": len(matches),
        "weighted_rating": round(weighted_rating, 3) if weighted_rating is not None else None,
        "observation_ids": [item["id"] for item in matches],
    }


def candidate_prior(
    candidate: dict[str, Any],
    evidence_packet: dict[str, Any],
    observations: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    enriched = dict(candidate)
    categories = category_matches(candidate.get("descriptors", []))
    claimed_quality_signals = quality_matches(candidate.get("descriptors", []))
    category_stats = prior_stat_map(evidence_packet["category_stats"])
    origin_stats = prior_stat_map(evidence_packet["origin_stats"])
    process_stats = prior_stat_map(evidence_packet["process_stats"])

    category_scores = [
        max(
            0.0,
            min(
                100.0,
                ((category_stats[normalized_key(category)]["weighted_rating"] - 1) / 3) * 100,
            ),
        )
        for category in categories
        if normalized_key(category) in category_stats
        and category_stats[normalized_key(category)]["weighted_rating"] is not None
    ]
    sensory_fit = statistics.mean(category_scores) if category_scores else 50.0
    origin_row = origin_stats.get(normalized_key(candidate.get("origin")))
    process_row = process_stats.get(normalized_key(candidate.get("process")))
    origin_fit = (
        max(0.0, min(100.0, ((origin_row["weighted_rating"] - 1) / 3) * 100))
        if origin_row and origin_row["weighted_rating"] is not None else 50.0
    )
    process_fit = (
        max(0.0, min(100.0, ((process_row["weighted_rating"] - 1) / 3) * 100))
        if process_row and process_row["weighted_rating"] is not None else 50.0
    )
    fit = sensory_fit * 0.75 + origin_fit * 0.15 + process_fit * 0.10
    quality_bonus = min(
        7.0,
        sum({
            "clarity_positive": 3.0,
            "cleanliness_positive": 3.0,
            "acid_sweet_balance_positive": 3.0,
            "brightness_positive": 1.5,
            "juiciness_positive": 1.0,
        }.get(signal, 0.0) for signal in claimed_quality_signals),
    )
    history_match = direct_history_match(candidate, observations or [])
    history_bonus = 0.0
    if (
        history_match["rated_observations"] >= 1
        and history_match["weighted_rating"] is not None
        and history_match["weighted_rating"] >= 3
    ):
        history_bonus = min(18.0, 10.0 + 4.0 * (history_match["rated_observations"] - 1))
    fit = min(100.0, fit + quality_bonus + history_bonus)

    category_familiarity_scores = [
        min(1.0, category_stats[normalized_key(category)]["observations"] / 6) * 100
        for category in categories
        if normalized_key(category) in category_stats
    ]
    category_familiarity = (
        statistics.mean(category_familiarity_scores)
        if category_familiarity_scores else 0.0
    )
    origin_familiarity = 80.0 if origin_row else 10.0
    process_familiarity = 80.0 if process_row else 20.0
    novelty = 100 - (
        category_familiarity * 0.50
        + origin_familiarity * 0.25
        + process_familiarity * 0.25
    )
    if history_bonus:
        novelty -= min(20.0, history_bonus)

    enriched["descriptor_categories"] = categories
    enriched["claimed_quality_signals"] = claimed_quality_signals
    enriched["direct_history_match"] = history_match
    enriched["deterministic_prior"] = {
        "fit_score": round(fit, 1),
        "novelty_score": round(max(0.0, min(100.0, novelty)), 1),
        "quality_claim_bonus": round(quality_bonus, 1),
        "direct_history_bonus": round(history_bonus, 1),
        "note": (
            "Prefilter prior only. Seller quality claims have a small capped bonus; "
            "direct historical identity overlap has a larger but non-causal bonus."
        ),
    }
    return enriched


def shortlist_live_candidates(
    candidates: list[dict[str, Any]],
    evidence_packet: dict[str, Any],
    observations: list[dict[str, Any]],
    limit: int = 10,
) -> list[dict[str, Any]]:
    unavailable_markers = (
        "sold_out",
        "unavailable",
        "archived",
        "discontinued",
    )
    available_candidates = [
        candidate
        for candidate in candidates
        if not any(
            marker in normalized_key(candidate.get("availability"))
            for marker in unavailable_markers
        )
    ]
    if not available_candidates:
        raise ValueError("no available live candidates")
    enriched = [
        candidate_prior(candidate, evidence_packet, observations)
        for candidate in available_candidates
    ]
    fit_ranked = sorted(
        enriched,
        key=lambda item: (-item["deterministic_prior"]["fit_score"], item["id"]),
    )
    novelty_ranked = sorted(
        (
            item for item in enriched
            if item["deterministic_prior"]["fit_score"] >= FRONTIER_MIN_FIT
        ),
        key=lambda item: (
            -item["deterministic_prior"]["novelty_score"],
            -item["deterministic_prior"]["fit_score"],
            item["id"],
        ),
    )
    selected: list[dict[str, Any]] = []
    selected_ids: set[str] = set()
    for item in [*fit_ranked[:6], *novelty_ranked]:
        if item["id"] not in selected_ids:
            selected.append(item)
            selected_ids.add(item["id"])
        if len(selected) >= limit:
            break
    return selected


def find_entity(dataset: dict[str, Any], entity_id: str) -> dict[str, Any]:
    for entity in dataset["entities"]:
        if entity["entity_id"] == entity_id:
            return entity
    raise KeyError(f"unknown entity: {entity_id}")


def holdout_candidate(entity: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": entity["entity_id"],
        "roaster": entity["coffee"].get("roaster"),
        "name": entity["coffee"].get("name"),
        "origin": entity["coffee"].get("origin"),
        "farm": entity["coffee"].get("farm"),
        "variety": entity["coffee"].get("variety"),
        "process": entity["coffee"].get("process"),
        "descriptors": entity.get("descriptors", []),
        "descriptor_categories": entity.get("descriptor_categories", []),
        "claimed_quality_signals": entity.get("claimed_quality_signals", []),
    }


def recommendation_evidence_packet(
    observations: list[dict[str, Any]],
) -> dict[str, Any]:
    packet = build_evidence_packet(observations)
    return {
        "method_notes": [
            "This packet contains training history only; held-out candidate ratings are excluded.",
            "Category statistics reflect rating correlations and mostly seller or mixed-source descriptors.",
            "Use sensory evidence for fit. Use origin, process, variety, and roaster only for novelty or risk.",
        ],
        "category_stats": packet["category_stats"],
        "quality_signal_stats": packet["quality_signal_stats"],
        "high_evidence_examples": packet["high_evidence_examples"],
        "lower_rated_contrasts": packet["lower_rated_contrasts"],
    }


def category_jaccard(left: list[str], right: list[str]) -> float:
    left_set = set(left)
    right_set = set(right)
    if not left_set or not right_set:
        return 0.0
    return len(left_set.intersection(right_set)) / len(left_set.union(right_set))


def enrich_candidates_with_analogs(
    candidates: list[dict[str, Any]],
    observations: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    enriched: list[dict[str, Any]] = []
    for candidate in candidates:
        rows: list[dict[str, Any]] = []
        for item in observations:
            score = item["rating"].get("score")
            if score is None:
                continue
            similarity = category_jaccard(
                candidate.get("descriptor_categories", []),
                item["sensory"].get("descriptor_categories", []),
            )
            if similarity <= 0:
                continue
            rows.append({
                "observation_id": item["id"],
                "similarity": round(similarity, 3),
                "rating_label": item["rating"].get("label"),
                "rating_score": score,
                "descriptor_categories": item["sensory"].get(
                    "descriptor_categories",
                    [],
                ),
                "descriptor_origin": item["sensory"].get("descriptor_origin"),
                "substantive_first_person_note": bool(
                    item["evidence"].get("substantive_first_person_note")
                ),
            })
        positive = sorted(
            (row for row in rows if row["rating_score"] >= 3),
            key=lambda row: (
                -row["similarity"],
                -row["rating_score"],
                row["observation_id"],
            ),
        )[:3]
        lower = sorted(
            (row for row in rows if row["rating_score"] <= 2),
            key=lambda row: (
                -row["similarity"],
                row["rating_score"],
                row["observation_id"],
            ),
        )[:3]
        max_positive = positive[0]["similarity"] if positive else 0.0
        max_lower = lower[0]["similarity"] if lower else 0.0
        item = dict(candidate)
        item["analog_evidence"] = {
            "similarity_metric": "Jaccard over broad descriptor categories",
            "top_positive": positive,
            "top_lower": lower,
            "max_positive_similarity": max_positive,
            "max_lower_similarity": max_lower,
            "contrast_margin": round(max_positive - max_lower, 3),
            "interpretation": (
                "A close lower-rated analog is material counterevidence. "
                "The margin is a tie-breaker, not a calibrated probability."
            ),
        }
        enriched.append(item)
    return enriched


def collect_evidence_ids(value: Any) -> list[str]:
    ids: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in {"evidence_ids", "counterevidence_ids"} and isinstance(nested, list):
                ids.extend(str(item) for item in nested)
            else:
                ids.extend(collect_evidence_ids(nested))
    elif isinstance(value, list):
        for nested in value:
            ids.extend(collect_evidence_ids(nested))
    return ids


def flatten_text(value: Any) -> str:
    if isinstance(value, dict):
        return " ".join(flatten_text(item) for item in value.values())
    if isinstance(value, list):
        return " ".join(flatten_text(item) for item in value)
    return str(value or "")


def score_profile(
    profile: dict[str, Any],
    valid_observation_ids: set[str],
    assertions: dict[str, Any],
) -> dict[str, Any]:
    required_keys = {
        "summary", "preference_axes", "sensory_profile", "extrinsic_correlations",
        "known_preferences", "likely_preferences", "unknowns", "data_quality",
    }
    schema_ok = required_keys.issubset(profile)
    evidence_ids = collect_evidence_ids(profile)
    evidence_valid = sum(item in valid_observation_ids for item in evidence_ids)
    evidence_accuracy = evidence_valid / len(evidence_ids) if evidence_ids else 0.0
    text = flatten_text(profile).casefold()
    concept_hits = [
        any(term.casefold() in text for term in alternatives)
        for alternatives in assertions["required_concepts"]
    ]
    concept_coverage = sum(concept_hits) / len(concept_hits)
    unknowns = profile.get("unknowns")
    unknowns_ok = isinstance(unknowns, list) and len(unknowns) >= assertions["minimum_unknowns"]
    forbidden_hits = [
        phrase for phrase in assertions["forbidden_absolute_phrases"]
        if phrase.casefold() in text
    ]
    known_text = flatten_text(profile.get("known_preferences")).casefold()
    known_scope_hits = [
        term for term in assertions.get("known_preference_forbidden_terms", [])
        if term.casefold() in known_text
    ]
    known_scope_ok = not known_scope_hits
    axes = profile.get("preference_axes")
    axes_ok = isinstance(axes, list) and len(axes) >= 3
    narrative = ((profile.get("summary") or {}).get("narrative") or "")
    narrative_ok = NARRATIVE_LENGTH_RANGE[0] <= len(narrative) <= NARRATIVE_LENGTH_RANGE[1]
    score = statistics.mean([
        float(schema_ok),
        evidence_accuracy,
        concept_coverage,
        float(unknowns_ok),
        float(not forbidden_hits),
        float(known_scope_ok),
        float(axes_ok),
        float(narrative_ok),
    ])
    return {
        "score": round(score, 4),
        "schema_ok": schema_ok,
        "evidence_reference_accuracy": round(evidence_accuracy, 4),
        "evidence_reference_count": len(evidence_ids),
        "concept_coverage": round(concept_coverage, 4),
        "concept_hits": concept_hits,
        "unknowns_ok": unknowns_ok,
        "forbidden_hits": forbidden_hits,
        "known_preference_scope_ok": known_scope_ok,
        "known_preference_scope_hits": known_scope_hits,
        "axes_ok": axes_ok,
        "narrative_length": len(narrative),
        "narrative_ok": narrative_ok,
    }


def ordering_discipline(
    recommendation: dict[str, Any],
    candidate_ids: set[str],
) -> tuple[bool, bool]:
    """safe_highest_fit / frontier_more_novel computed from a recommendation's own ranking.

    Pass the RAW model output here when scoring grounded output: the grounder
    forces safe fit to the maximum and frontier novelty above safe, so checking
    the grounded numbers would be tautological.
    """
    safe_id = (recommendation.get("safe_match") or {}).get("candidate_id")
    frontier_id = (recommendation.get("frontier_pick") or {}).get("candidate_id")
    ranking = recommendation.get("ranking")
    ranking_by_id = {
        item.get("candidate_id"): item
        for item in ranking
        if isinstance(item, dict) and item.get("candidate_id") in candidate_ids
    } if isinstance(ranking, list) else {}
    safe_fit = (ranking_by_id.get(safe_id) or {}).get("fit_score")
    frontier_novelty = (ranking_by_id.get(frontier_id) or {}).get("novelty_score")
    safe_novelty = (ranking_by_id.get(safe_id) or {}).get("novelty_score")
    numeric_fit_scores = [
        item.get("fit_score")
        for item in ranking_by_id.values()
        if isinstance(item.get("fit_score"), (int, float))
    ]
    safe_highest_fit = (
        isinstance(safe_fit, (int, float))
        and bool(numeric_fit_scores)
        and safe_fit == max(numeric_fit_scores)
    )
    frontier_more_novel = (
        isinstance(frontier_novelty, (int, float))
        and isinstance(safe_novelty, (int, float))
        and frontier_novelty > safe_novelty
    )
    return safe_highest_fit, frontier_more_novel


def score_recommendation(
    recommendation: dict[str, Any],
    candidate_ids: set[str],
    candidate_roasters: dict[str, str],
    valid_observation_ids: set[str],
    expected_safe_id: str | None,
    constraints: dict[str, Any],
    ordering_source: dict[str, Any] | None = None,
) -> dict[str, Any]:
    required_keys = {"safe_match", "frontier_pick", "ranking", "caveats"}
    schema_ok = required_keys.issubset(recommendation)
    safe = recommendation.get("safe_match") or {}
    frontier = recommendation.get("frontier_pick") or {}
    safe_id = safe.get("candidate_id")
    frontier_id = frontier.get("candidate_id")
    ids_valid = safe_id in candidate_ids and frontier_id in candidate_ids
    distinct = safe_id != frontier_id
    ranking = recommendation.get("ranking")
    ranking_ids = [
        item.get("candidate_id")
        for item in ranking
        if isinstance(item, dict)
    ] if isinstance(ranking, list) else []
    ranking_complete = len(ranking_ids) == len(candidate_ids) and set(ranking_ids) == candidate_ids
    safe_highest_fit, frontier_more_novel = ordering_discipline(
        ordering_source if ordering_source is not None else recommendation,
        candidate_ids,
    )
    evidence_ids = collect_evidence_ids({"safe": safe, "frontier": frontier})
    evidence_valid = sum(item in valid_observation_ids for item in evidence_ids)
    evidence_accuracy = evidence_valid / len(evidence_ids) if evidence_ids else 0.0
    expected_ok = expected_safe_id is None or safe_id == expected_safe_id
    novelty = frontier.get("novelty_dimensions")
    bridge = frontier.get("bridge_to_profile")
    frontier_explained = isinstance(novelty, list) and bool(novelty) and isinstance(bridge, list) and bool(bridge)
    text = flatten_text(recommendation).casefold()
    semantic_patterns = {
        "absence_implies_clean": (
            ("无发酵描述", "干净"),
            ("无负面发酵", "干净"),
            ("no ferment", "clean"),
        ),
        "unsupported_roast_advice": (
            ("中浅度烘焙",),
            ("浅度烘焙",),
            ("light roast",),
        ),
        "variety_implies_acidity": (
            ("gesha", "过高酸度"),
            ("geisha", "高酸度"),
            ("瑰夏", "高酸度"),
        ),
        "pome_mislabeled_stone": (
            ("青苹果", "核果"),
            ("green apple", "stone fruit"),
        ),
    }
    semantic_hits = [
        label
        for label, alternatives in semantic_patterns.items()
        if any(all(term in text for term in pattern) for pattern in alternatives)
    ]
    semantic_ok = not semantic_hits
    different_roasters_ok = True
    if constraints.get("different_roasters") and ids_valid:
        different_roasters_ok = candidate_roasters.get(safe_id) != candidate_roasters.get(frontier_id)
    score = statistics.mean([
        float(schema_ok),
        float(ids_valid),
        float(distinct),
        float(ranking_complete),
        evidence_accuracy,
        float(expected_ok),
        float(frontier_explained),
        float(different_roasters_ok),
        float(safe_highest_fit),
        float(frontier_more_novel),
        float(semantic_ok),
    ])
    return {
        "score": round(score, 4),
        "schema_ok": schema_ok,
        "safe_id": safe_id,
        "frontier_id": frontier_id,
        "ids_valid": ids_valid,
        "distinct": distinct,
        "ranking_complete": ranking_complete,
        "evidence_reference_accuracy": round(evidence_accuracy, 4),
        "evidence_reference_count": len(evidence_ids),
        "expected_safe_id": expected_safe_id,
        "expected_safe_ok": expected_ok,
        "frontier_explained": frontier_explained,
        "different_roasters_ok": different_roasters_ok,
        "safe_highest_fit": safe_highest_fit,
        "frontier_more_novel": frontier_more_novel,
        "semantic_guardrail_ok": semantic_ok,
        "semantic_guardrail_hits": semantic_hits,
    }


def ground_recommendation(
    recommendation: dict[str, Any],
    candidates: list[dict[str, Any]],
    valid_observation_ids: set[str],
    constraints: dict[str, Any],
    profile: dict[str, Any],
    lock_to_prior: bool = False,
) -> dict[str, Any]:
    grounded = json.loads(json.dumps(recommendation, ensure_ascii=False))
    candidate_by_id = {item["id"]: item for item in candidates}
    candidate_ids = list(candidate_by_id)
    candidate_id_set = set(candidate_ids)
    original_ranking = grounded.get("ranking")
    ranking_by_id: dict[str, dict[str, Any]] = {}
    if isinstance(original_ranking, list):
        for row in original_ranking:
            if not isinstance(row, dict):
                continue
            candidate_id = row.get("candidate_id")
            if candidate_id in candidate_id_set and candidate_id not in ranking_by_id:
                ranking_by_id[candidate_id] = dict(row)

    ranking: list[dict[str, Any]] = []
    for candidate_id in candidate_ids:
        candidate = candidate_by_id[candidate_id]
        prior = candidate.get("deterministic_prior") or {}
        row = ranking_by_id.get(candidate_id, {})
        if lock_to_prior and prior:
            fit_score = prior.get("fit_score", 50)
            novelty_score = prior.get("novelty_score", 50)
        else:
            fit_score = row.get("fit_score", prior.get("fit_score", 50))
            novelty_score = row.get("novelty_score", prior.get("novelty_score", 50))
        category_labels = [
            CATEGORY_LABELS.get(category, category)
            for category in candidate.get("descriptor_categories", [])
        ]
        ranking.append({
            "candidate_id": candidate_id,
            "fit_score": max(0, min(100, float(fit_score))),
            "novelty_score": max(0, min(100, float(novelty_score))),
            "confidence": max(0, min(1, float(row.get("confidence", 0.55)))),
            "short_reason": (
                f"候选声明覆盖{'、'.join(category_labels)}；"
                "排序反映历史相关性，不代表已确认杯中表现。"
                if category_labels
                else "候选描述信息有限，排序置信度较低。"
            ),
        })
    ranking_by_id = {row["candidate_id"]: row for row in ranking}

    safe = grounded.get("safe_match")
    safe = dict(safe) if isinstance(safe, dict) else {}
    safe_id = safe.get("candidate_id")
    if lock_to_prior or safe_id not in candidate_id_set:
        safe_id = max(
            candidate_ids,
            key=lambda candidate_id: (
                ranking_by_id[candidate_id]["fit_score"],
                -ranking_by_id[candidate_id]["novelty_score"],
                candidate_id,
            ),
        )
    analog_override = False
    if not lock_to_prior:
        safe_margin = float(
            (candidate_by_id[safe_id].get("analog_evidence") or {}).get(
                "contrast_margin",
                0.0,
            )
        )
        nonnegative_alternatives = [
            candidate_id for candidate_id in candidate_ids
            if candidate_id != safe_id
            and float(
                (candidate_by_id[candidate_id].get("analog_evidence") or {}).get(
                    "contrast_margin",
                    0.0,
                )
            ) >= 0
        ]
        if safe_margin < 0 and nonnegative_alternatives:
            safe_id = max(
                nonnegative_alternatives,
                key=lambda candidate_id: (
                    float(
                        (
                            candidate_by_id[candidate_id].get("analog_evidence")
                            or {}
                        ).get("contrast_margin", 0.0)
                    ),
                    ranking_by_id[candidate_id]["fit_score"],
                    candidate_id,
                ),
            )
            analog_override = True

    frontier = grounded.get("frontier_pick")
    frontier = dict(frontier) if isinstance(frontier, dict) else {}
    frontier_id = frontier.get("candidate_id")

    def frontier_candidates() -> list[str]:
        eligible = [
            candidate_id for candidate_id in candidate_ids
            if candidate_id != safe_id
            and (
                not constraints.get("different_roasters")
                or candidate_by_id[candidate_id].get("roaster")
                != candidate_by_id[safe_id].get("roaster")
            )
        ]
        fit_eligible = [
            candidate_id for candidate_id in eligible
            if ranking_by_id[candidate_id]["fit_score"] >= FRONTIER_MIN_FIT
        ]
        return fit_eligible or eligible

    eligible_frontiers = frontier_candidates()
    frontier_invalid = (
        frontier_id not in eligible_frontiers
        or frontier_id == safe_id
    )
    if lock_to_prior or frontier_invalid:
        frontier_id = max(
            eligible_frontiers,
            key=lambda candidate_id: (
                ranking_by_id[candidate_id]["novelty_score"] * 0.55
                + ranking_by_id[candidate_id]["fit_score"] * 0.45,
                ranking_by_id[candidate_id]["fit_score"],
                candidate_id,
            ),
        )

    grounding_adjustments = {
        "safe_fit_raised": False,
        "frontier_novelty_raised": False,
    }
    safe_fit = ranking_by_id[safe_id]["fit_score"]
    maximum_other_fit = max(
        (
            row["fit_score"]
            for candidate_id, row in ranking_by_id.items()
            if candidate_id != safe_id
        ),
        default=safe_fit,
    )
    if safe_fit < maximum_other_fit:
        ranking_by_id[safe_id]["fit_score"] = min(100.0, maximum_other_fit + 0.1)
        grounding_adjustments["safe_fit_raised"] = True

    safe_novelty = ranking_by_id[safe_id]["novelty_score"]
    frontier_novelty = ranking_by_id[frontier_id]["novelty_score"]
    if frontier_novelty <= safe_novelty:
        if safe_novelty >= 100:
            ranking_by_id[safe_id]["novelty_score"] = 94.9
            safe_novelty = 94.9
        ranking_by_id[frontier_id]["novelty_score"] = min(100.0, safe_novelty + 5.0)
        grounding_adjustments["frontier_novelty_raised"] = True

    profile_evidence_ids = [
        evidence_id
        for axis in profile.get("preference_axes", [])
        if isinstance(axis, dict)
        for evidence_id in axis.get("evidence_ids", [])
        if evidence_id in valid_observation_ids
    ]
    profile_evidence_ids = list(dict.fromkeys(profile_evidence_ids))

    def grounded_pick(
        original: dict[str, Any],
        candidate_id: str,
        role: str,
    ) -> dict[str, Any]:
        candidate = candidate_by_id[candidate_id]
        row = ranking_by_id[candidate_id]
        same_candidate = original.get("candidate_id") == candidate_id
        evidence_ids = [
            evidence_id for evidence_id in original.get("evidence_ids", [])
            if evidence_id in valid_observation_ids
        ] if same_candidate else []
        direct_ids = [
            evidence_id
            for evidence_id in (candidate.get("direct_history_match") or {}).get(
                "observation_ids",
                [],
            )
            if evidence_id in valid_observation_ids
        ]
        evidence_ids = list(dict.fromkeys([
            *direct_ids,
            *evidence_ids,
            *profile_evidence_ids,
        ]))[:5]
        history_match = candidate.get("direct_history_match") or {}
        category_labels = [
            CATEGORY_LABELS.get(category, category)
            for category in candidate.get("descriptor_categories", [])
        ]
        history_reason = (
            f"历史中有 {history_match.get('rated_observations')} 条名称或处理站直接重合的"
            f"评分记录，加权评分为 {history_match.get('weighted_rating')}/4。"
            if history_match.get("rated_observations")
            else (
                f"候选声明覆盖{'、'.join(category_labels)}，这些家族在历史评分中"
                "存在正相关，但多数不是第一人称确认。"
                if category_labels
                else "候选描述信息有限，匹配主要依赖整体评分模式，置信度较低。"
            )
        )
        reasons = [
            history_reason,
            (
                f"卖方或混合来源描述为 {', '.join(candidate.get('descriptors', [])[:6])}；"
                "这些是候选特征声明，需用实际冲煮验证。"
            ),
        ]
        risks = [
            "候选描述不能证明实际杯中一定清晰、干净或酸甜协调，不能从词语缺失反向推断。",
            "烘焙日期、静置、配方和运输会改变实际表现。",
        ]
        if not candidate.get("process") or normalized_key(candidate.get("process")) == "unknown":
            risks.append("处理法未知；不能据此推断发酵感或干净度。")
        watchpoints = [
            "分别记录热杯与降温后的风味辨识度、酸甜关系和实际杯感。",
            "记录是否出现抢戏的发酵感、惊喜度，以及是否愿意复购。",
        ]
        result = {
            "candidate_id": candidate_id,
            "expected_liking": int(round(row["fit_score"])),
            "confidence": round(float(row.get("confidence", 0.55)), 2),
            "reasons": reasons,
            "evidence_ids": evidence_ids,
            "risks": risks,
            "brew_watchpoints": watchpoints,
        }
        if role == "frontier":
            result["novelty_dimensions"] = [
                f"产地：{candidate.get('origin') or '未知'}",
                f"处理：{candidate.get('process') or '未知'}",
                f"新风味线索：{', '.join(candidate.get('descriptors', [])[:2])}",
            ]
            result["bridge_to_profile"] = [
                (
                    f"保留{'、'.join(category_labels[:3])}等历史正相关家族。"
                    if category_labels
                    else "保留整体水果或甜香主线，但具体家族证据有限。"
                ),
                "杯感结构必须通过实饮验证，不把卖方声明或描述缺失预先当作干净度证据。",
            ]
        return result

    grounded["safe_match"] = grounded_pick(safe, safe_id, "safe")
    grounded["frontier_pick"] = grounded_pick(frontier, frontier_id, "frontier")
    grounded["ranking"] = sorted(
        ranking_by_id.values(),
        key=lambda row: (-row["fit_score"], row["candidate_id"]),
    )
    grounded["caveats"] = [
        "候选数据来自在售页面或历史记录中的描述快照，不能替代实饮。",
        "相似度只比较宽泛风味家族，未建模具体强度、烘焙、批次与冲煮状态。",
        "探索推荐只能离线检查结构；真实惊喜度需要喝完后的反馈闭环。",
    ]
    if analog_override:
        grounded["caveats"].append(
            "混合排序器否决了原始安全款：其最相似低评分近邻比最相似正向近邻更接近。"
        )
    grounded["grounding_adjustments"] = grounding_adjustments
    return grounded


def run_model_call(
    output_path: Path,
    prompt: str,
    api_key: str,
    base_url: str,
    model: str,
    timeout: int,
    max_output_tokens: int,
    thinking_type: str,
    force: bool,
) -> dict[str, Any]:
    write_text(output_path.with_suffix(".prompt.txt"), prompt)
    if output_path.exists() and not force:
        existing = read_json(output_path)
        if existing.get("parsed") is not None:
            return existing

    attempts: list[dict[str, Any]] = []
    result: dict[str, Any] | None = None
    for attempt in range(1, 4):
        try:
            result = call_responses(
                api_key,
                base_url,
                model,
                prompt,
                timeout,
                max_output_tokens,
                thinking_type,
            )
            result["error"] = None
            attempts.append({"attempt": attempt, "error": None, "elapsed_ms": result["elapsed_ms"]})
            break
        except Exception as exc:
            attempts.append({"attempt": attempt, "error": str(exc), "elapsed_ms": None})
            if attempt < 3:
                time.sleep(attempt * 2)
    if result is None:
        result = {
            "status": None,
            "elapsed_ms": None,
            "usage": None,
            "raw_text": None,
            "parsed": None,
            "error": attempts[-1]["error"],
        }
    result["attempts"] = attempts
    write_json(output_path, result)
    return result


def render_evaluation_summary(
    path: Path,
    model: str,
    max_cases: int,
    summaries: dict[str, Any],
    versions: tuple[str, ...],
) -> None:
    lines = [
        "# Coffee Taste Prompt Evaluation",
        "",
        f"- Model: `{model}`",
        f"- Holdout cases executed per version: {max_cases}",
        "- Live candidate set is report-only and excluded from tuning labels.",
        "",
        "| Version | Pipeline | Raw prompt | Profile | Pairwise (weighted) | Pairwise (unweighted) | Raw pairwise (unweighted) | Recommendation contract | Evidence refs |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for version in versions:
        summary = summaries[version]
        lines.append(
            f"| {version} | {summary['overall_score']:.3f} | "
            f"{summary['raw_overall_score']:.3f} | "
            f"{summary['profile_score']:.3f} | {summary['pairwise_accuracy']:.3f} | "
            f"{summary['pairwise_accuracy_unweighted']:.3f} | "
            f"{summary['raw_pairwise_accuracy_unweighted']:.3f} | "
            f"{summary['recommendation_contract_score']:.3f} | "
            f"{summary['evidence_reference_accuracy']:.3f} |"
        )
    watch_rows = [
        (version, row)
        for version in versions
        for row in summaries[version].get("regression_watch", [])
    ]
    if watch_rows:
        lines.extend([
            "",
            "## Tracked Challenge Cases",
            "",
            "Cases flagged `regression_watch` in the eval set. They stay inside the",
            "mean metrics above; this section keeps them from hiding in the weighted average.",
            "",
            "| Version | Case | Learnability | Pipeline safe pick | Raw safe pick |",
            "|---|---|---|---|---|",
        ])
        for version, row in watch_rows:
            lines.append(
                f"| {version} | {row['case_id']} | {row['level']} | "
                f"{'correct' if row['pipeline_expected_safe_ok'] else 'WRONG'} | "
                f"{'correct' if row['raw_expected_safe_ok'] else 'WRONG'} |"
            )
    for version in versions:
        levels = summaries[version].get("pairwise_by_learnability", {})
        if not levels:
            continue
        lines.extend([
            "",
            f"## {version} Pairwise by Learnability",
            "",
            "| Level | Cases | Pipeline accuracy | Raw prompt accuracy |",
            "|---|---:|---:|---:|",
        ])
        for level in ("high", "medium", "low", "unspecified"):
            if level not in levels:
                continue
            row = levels[level]
            lines.append(
                f"| {level} | {row['cases']} | {row['accuracy']:.3f} | "
                f"{row['raw_accuracy']:.3f} |"
            )
    kept_rates = [
        (version, summaries[version].get("narrative_model_kept_rate"))
        for version in versions
        if summaries[version].get("narrative_model_kept_rate") is not None
    ]
    if kept_rates:
        lines.extend([
            "",
            "## Narrative Source",
            "",
            "Share of grounded profiles whose model-authored summary passed the",
            "deterministic narrative guardrails and was kept verbatim.",
            "",
            "| Version | Model narrative kept rate |",
            "|---|---:|",
            *[
                f"| {version} | {rate:.3f} |"
                for version, rate in kept_rates
            ],
        ])
    lines.extend([
        "",
        "## Interpretation",
        "",
        "- Pairwise accuracy uses leave-both-candidates-out profiles, so the model cannot see the held-out ratings.",
        "- The headline pairwise metric is learnability-weighted; the per-level table prevents sparse challenge cases from being mistaken for ordinary prediction errors.",
        "- Raw prompt scores preserve the model output; pipeline scores include deterministic evidence grounding and contract enforcement.",
        "- Profile scoring checks schema, evidence IDs, required concepts, calibrated unknowns, and forbidden absolute claims.",
        "- Exploration quality is only structurally testable offline. Real serendipity requires post-purchase feedback.",
        "",
    ])
    write_text(path, "\n".join(lines))


def markdown_list(values: Any) -> list[str]:
    if not isinstance(values, list):
        return []
    return [f"- {value}" for value in values]


def render_current_report(
    path: Path,
    dataset: dict[str, Any],
    profile: dict[str, Any],
    recommendation: dict[str, Any],
    candidates: list[dict[str, Any]],
    model: str,
) -> None:
    by_id = {item["id"]: item for item in candidates}
    safe = recommendation.get("safe_match") or {}
    frontier = recommendation.get("frontier_pick") or {}

    def pick_lines(title: str, pick: dict[str, Any]) -> list[str]:
        candidate = by_id.get(pick.get("candidate_id"), {})
        price = candidate.get("price") or {}
        price_text = (
            f"{price.get('currency')} {price.get('amount')}"
            + (f" / {price.get('size_grams')}g" if price.get("size_grams") else "")
        )
        return [
            f"## {title}",
            "",
            f"**[{candidate.get('roaster', 'Unknown')} - {candidate.get('name', pick.get('candidate_id'))}]({candidate.get('source_url', '')})**",
            "",
            f"- 预测喜欢度：{pick.get('expected_liking')}/100；置信度：{pick.get('confidence')}",
            f"- 在售快照：{candidate.get('availability')}；标价：{price_text}",
            *[f"- 理由：{item}" for item in pick.get("reasons", [])],
            *[f"- 风险：{item}" for item in pick.get("risks", [])],
            *[f"- 冲煮观察点：{item}" for item in pick.get("brew_watchpoints", [])],
            "",
        ]

    summary = profile.get("summary") or {}
    data_quality = profile.get("data_quality") or {}
    lines = [
        "# 当前咖啡风味画像与购买建议",
        "",
        f"生成时间：{datetime.now(timezone.utc).isoformat()}  ",
        f"模型：`{model}`  ",
        f"数据：{dataset['stats']['rated_observations']} 条明确评分，"
        f"{dataset['stats']['substantive_first_person_notes']} 条第一人称实饮描述。",
        "",
        f"## {summary.get('headline', '画像摘要')}",
        "",
        summary.get("narrative", ""),
        "",
        "### 已知偏好",
        "",
        *markdown_list(profile.get("known_preferences")),
        "",
        "### 可能偏好",
        "",
        *markdown_list(profile.get("likely_preferences")),
        "",
        "### 当前未知",
        "",
        *markdown_list(profile.get("unknowns")),
        "",
        *pick_lines("高概率匹配", safe),
        *pick_lines("扩展边界", frontier),
        "## 使用边界",
        "",
        "- 官网风味词是候选咖啡的卖方描述，不等于你实际一定会喝到。",
        "- 国际库存、烘焙日和配送限制会变化，下单前需要再次确认。",
        "- 目前第一人称实饮描述很少，画像对“为什么喜欢”的置信度低于对“哪些咖啡评得高”的置信度。",
        "- 真正的探索推荐评估要在喝完后记录：实际 verdict、惊喜度、是否愿意复购、偏差原因。",
        "",
        "### 模型自报的数据限制",
        "",
        *markdown_list(data_quality.get("limitations")),
        "",
    ]
    write_text(path, "\n".join(lines))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=Path("private/coffee_taste/dataset.json"))
    parser.add_argument("--cases", type=Path, default=Path("private/coffee_taste/eval_cases.json"))
    parser.add_argument(
        "--candidates",
        type=Path,
        default=Path("private/coffee_taste/live_candidates.json"),
    )
    parser.add_argument("--config", type=Path, default=Path("config.json"))
    parser.add_argument("--model", default=os.environ.get("ARK_MODEL"))
    parser.add_argument("--base-url", default=os.environ.get("ARK_BASE_URL"))
    parser.add_argument("--api-key", default=os.environ.get("ARK_API_KEY"))
    parser.add_argument("--max-cases", type=int, default=3)
    parser.add_argument("--case-ids", nargs="*", default=[])
    parser.add_argument(
        "--versions",
        nargs="+",
        choices=VERSIONS,
        default=list(VERSIONS),
    )
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--max-output-tokens", type=int, default=4000)
    parser.add_argument(
        "--thinking",
        choices=["disabled", "enabled", "auto"],
        default="disabled",
        help="Ark thinking mode. Structured extraction defaults to disabled.",
    )
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = read_config(args.config)
    api_key = args.api_key or config_api_key(config)
    model = args.model or config.get("model") or DEFAULT_MODEL
    base_url = args.base_url or config.get("base_url") or DEFAULT_BASE_URL
    if not api_key:
        raise SystemExit("missing Ark API key")

    dataset = read_json(args.dataset)
    cases = read_json(args.cases)
    candidate_document = read_json(args.candidates)
    live_candidates = candidate_document["candidates"]
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = args.output_dir or Path(".generated/coffee_taste_eval") / run_id
    output_dir.mkdir(parents=True, exist_ok=True)

    selected_versions = tuple(args.versions)
    if args.case_ids:
        requested = set(args.case_ids)
        selected_cases = [
            case for case in cases["pairwise_cases"]
            if case["id"] in requested
        ][: max(0, args.max_cases)]
        missing_case_ids = requested - {case["id"] for case in selected_cases}
        if missing_case_ids:
            raise SystemExit(
                "unknown or excluded case ids: " + ", ".join(sorted(missing_case_ids))
            )
    else:
        selected_cases = cases["pairwise_cases"][: max(0, args.max_cases)]
    summaries: dict[str, Any] = {}
    version_outputs: dict[str, Any] = {}

    for version in selected_versions:
        profile_template = Path(f"prompts/coffee_profile_{version}.md")
        recommend_template = Path(f"prompts/coffee_recommend_{version}.md")
        version_dir = output_dir / version
        all_observations = dataset["observations"]
        valid_all_ids = {item["id"] for item in all_observations}
        full_evidence_packet = build_evidence_packet(all_observations)
        full_profile_contract = build_profile_contract(all_observations)
        full_profile_prompt = render_template(profile_template, {
            "PROFILE_CONTRACT_JSON": full_profile_contract,
            "EVIDENCE_PACKET_JSON": full_evidence_packet,
            "OBSERVATIONS_JSON": [compact_observation(item) for item in all_observations],
        })
        full_profile_result = run_model_call(
            version_dir / "full_profile.json",
            full_profile_prompt,
            api_key,
            base_url,
            model,
            args.timeout,
            args.max_output_tokens,
            args.thinking,
            args.force,
        )
        raw_full_profile = full_profile_result.get("parsed")
        full_profile = (
            ground_profile(
                raw_full_profile,
                full_profile_contract,
                keep_model_summary=(version == "v2"),
                assertions=cases["profile_assertions"],
            )
            if version in GROUNDED_VERSIONS and raw_full_profile
            else raw_full_profile
        )
        raw_full_profile_score: dict[str, Any] = {"score": 0.0}
        if raw_full_profile:
            raw_full_profile_score = score_profile(
                raw_full_profile,
                valid_all_ids,
                cases["profile_assertions"],
            )
            write_json(version_dir / "full_profile_raw_score.json", raw_full_profile_score)
        if full_profile:
            write_json(version_dir / "full_profile_grounded.json", full_profile)
            full_profile_score = score_profile(full_profile, valid_all_ids, cases["profile_assertions"])
        else:
            full_profile_score = {"score": 0.0, "error": full_profile_result.get("error")}
        write_json(version_dir / "full_profile_score.json", full_profile_score)

        pairwise_results: list[dict[str, Any]] = []
        for case in selected_cases:
            heldout_ids = set(case["candidate_entity_ids"])
            training = [
                item for item in all_observations
                if item["entity_id"] not in heldout_ids
            ]
            valid_training_ids = {item["id"] for item in training}
            case_dir = version_dir / "holdouts" / case["id"]
            training_evidence_packet = build_evidence_packet(training)
            training_profile_contract = build_profile_contract(training)
            profile_prompt = render_template(profile_template, {
                "PROFILE_CONTRACT_JSON": training_profile_contract,
                "EVIDENCE_PACKET_JSON": training_evidence_packet,
                "OBSERVATIONS_JSON": [compact_observation(item) for item in training],
            })
            profile_result = run_model_call(
                case_dir / "profile.json",
                profile_prompt,
                api_key,
                base_url,
                model,
                args.timeout,
                args.max_output_tokens,
                args.thinking,
                args.force,
            )
            raw_profile = profile_result.get("parsed")
            profile = (
                ground_profile(
                    raw_profile,
                    training_profile_contract,
                    keep_model_summary=(version == "v2"),
                    assertions=cases["profile_assertions"],
                )
                if version in GROUNDED_VERSIONS and raw_profile
                else raw_profile
            )
            raw_profile_score: dict[str, Any] = {"score": 0.0}
            if raw_profile:
                raw_profile_score = score_profile(
                    raw_profile,
                    valid_training_ids,
                    cases["profile_assertions"],
                )
                write_json(case_dir / "profile_raw_score.json", raw_profile_score)
            if profile:
                write_json(case_dir / "profile_grounded.json", profile)
            profile_score = (
                score_profile(profile, valid_training_ids, cases["profile_assertions"])
                if profile else {"score": 0.0, "error": profile_result.get("error")}
            )
            write_json(case_dir / "profile_score.json", profile_score)

            holdout_candidates = [
                holdout_candidate(find_entity(dataset, entity_id))
                for entity_id in case["candidate_entity_ids"]
            ]
            holdout_candidates = enrich_candidates_with_analogs(
                holdout_candidates,
                training,
            )
            constraints: dict[str, Any] = {"different_roasters": False}
            recommendation: dict[str, Any] | None = None
            raw_recommendation: dict[str, Any] | None = None
            recommendation_result: dict[str, Any]
            if profile:
                recommendation_prompt = render_template(recommend_template, {
                    "PROFILE_JSON": profile,
                    "CANDIDATES_JSON": holdout_candidates,
                    "CONSTRAINTS_JSON": constraints,
                    "ALLOWED_CANDIDATE_IDS_JSON": [item["id"] for item in holdout_candidates],
                    "ALLOWED_EVIDENCE_IDS_JSON": sorted(valid_training_ids),
                    "RECOMMENDATION_EVIDENCE_JSON": recommendation_evidence_packet(
                        training
                    ),
                })
                recommendation_result = run_model_call(
                    case_dir / "recommendation.json",
                    recommendation_prompt,
                    api_key,
                    base_url,
                    model,
                    args.timeout,
                    args.max_output_tokens,
                    args.thinking,
                    args.force,
                )
                raw_recommendation = recommendation_result.get("parsed")
                recommendation = (
                    ground_recommendation(
                        raw_recommendation,
                        holdout_candidates,
                        valid_training_ids,
                        constraints,
                        profile,
                    )
                    if version in GROUNDED_VERSIONS and raw_recommendation
                    else raw_recommendation
                )
                if recommendation:
                    write_json(
                        case_dir / "recommendation_grounded.json",
                        recommendation,
                    )
            else:
                recommendation_result = {"error": "profile generation failed"}
                write_json(case_dir / "recommendation.json", recommendation_result)

            candidate_ids = {item["id"] for item in holdout_candidates}
            candidate_roasters = {item["id"]: item.get("roaster") or "" for item in holdout_candidates}
            raw_recommendation_score: dict[str, Any] = {
                "score": 0.0,
                "expected_safe_ok": False,
            }
            if raw_recommendation:
                raw_recommendation_score = score_recommendation(
                    raw_recommendation,
                    candidate_ids,
                    candidate_roasters,
                    valid_training_ids,
                    case["expected_safe_entity_id"],
                    constraints,
                )
                write_json(
                    case_dir / "recommendation_raw_score.json",
                    raw_recommendation_score,
                )
            recommendation_score = (
                score_recommendation(
                    recommendation,
                    candidate_ids,
                    candidate_roasters,
                    valid_training_ids,
                    case["expected_safe_entity_id"],
                    constraints,
                    ordering_source=raw_recommendation,
                )
                if recommendation else {"score": 0.0, "expected_safe_ok": False}
            )
            write_json(case_dir / "recommendation_score.json", recommendation_score)
            pairwise_results.append({
                "case": case,
                "raw_profile_score": raw_profile_score,
                "profile_score": profile_score,
                "raw_recommendation_score": raw_recommendation_score,
                "recommendation_score": recommendation_score,
                "profile_summary_source": (profile or {}).get("summary_source"),
            })

        current_constraints = {
            "different_roasters": True,
            "purchase_scope": "Official global shops of roasters present in history",
            "roles": ["safe_match", "frontier_pick"],
        }
        current_recommendation: dict[str, Any] | None = None
        raw_current_recommendation: dict[str, Any] | None = None
        current_score: dict[str, Any] = {"score": 0.0}
        raw_current_score: dict[str, Any] = {"score": 0.0}
        current_candidates = shortlist_live_candidates(
            live_candidates,
            full_evidence_packet,
            all_observations,
        )
        current_candidates = enrich_candidates_with_analogs(
            current_candidates,
            all_observations,
        )
        if full_profile:
            current_prompt = render_template(recommend_template, {
                "PROFILE_JSON": full_profile,
                "CANDIDATES_JSON": current_candidates,
                "CONSTRAINTS_JSON": current_constraints,
                "ALLOWED_CANDIDATE_IDS_JSON": [item["id"] for item in current_candidates],
                "ALLOWED_EVIDENCE_IDS_JSON": sorted(valid_all_ids),
                "RECOMMENDATION_EVIDENCE_JSON": recommendation_evidence_packet(
                    all_observations
                ),
            })
            current_result = run_model_call(
                version_dir / "current_recommendation.json",
                current_prompt,
                api_key,
                base_url,
                model,
                args.timeout,
                args.max_output_tokens,
                args.thinking,
                args.force,
            )
            raw_current_recommendation = current_result.get("parsed")
            current_recommendation = (
                ground_recommendation(
                    raw_current_recommendation,
                    current_candidates,
                    valid_all_ids,
                    current_constraints,
                    full_profile,
                    lock_to_prior=True,
                )
                if version in GROUNDED_VERSIONS and raw_current_recommendation
                else raw_current_recommendation
            )
            if current_recommendation:
                write_json(
                    version_dir / "current_recommendation_grounded.json",
                    current_recommendation,
                )
                if raw_current_recommendation:
                    raw_current_score = score_recommendation(
                        raw_current_recommendation,
                        {item["id"] for item in current_candidates},
                        {item["id"]: item["roaster"] for item in current_candidates},
                        valid_all_ids,
                        None,
                        current_constraints,
                    )
                    write_json(
                        version_dir / "current_recommendation_raw_score.json",
                        raw_current_score,
                    )
                current_score = score_recommendation(
                    current_recommendation,
                    {item["id"] for item in current_candidates},
                    {item["id"]: item["roaster"] for item in current_candidates},
                    valid_all_ids,
                    None,
                    current_constraints,
                    ordering_source=raw_current_recommendation,
                )
        write_json(version_dir / "current_recommendation_score.json", current_score)

        profile_scores = [full_profile_score.get("score", 0.0)] + [
            item["profile_score"].get("score", 0.0) for item in pairwise_results
        ]
        raw_profile_scores = [raw_full_profile_score.get("score", 0.0)] + [
            item["raw_profile_score"].get("score", 0.0)
            for item in pairwise_results
        ]
        rec_scores = [
            item["recommendation_score"].get("score", 0.0) for item in pairwise_results
        ]
        raw_rec_scores = [
            item["raw_recommendation_score"].get("score", 0.0)
            for item in pairwise_results
        ]
        case_weights = [
            float((item["case"].get("learnability") or {}).get("weight", 1.0))
            for item in pairwise_results
        ]
        total_case_weight = sum(case_weights)
        pairwise_accuracy_unweighted = statistics.mean([
            float(item["recommendation_score"].get("expected_safe_ok", False))
            for item in pairwise_results
        ]) if pairwise_results else 0.0
        raw_pairwise_accuracy_unweighted = statistics.mean([
            float(item["raw_recommendation_score"].get("expected_safe_ok", False))
            for item in pairwise_results
        ]) if pairwise_results else 0.0
        pairwise_accuracy = (
            sum(
                weight * float(
                    item["recommendation_score"].get("expected_safe_ok", False)
                )
                for item, weight in zip(pairwise_results, case_weights)
            ) / total_case_weight
            if total_case_weight else 0.0
        )
        raw_pairwise_accuracy = (
            sum(
                weight * float(
                    item["raw_recommendation_score"].get(
                        "expected_safe_ok",
                        False,
                    )
                )
                for item, weight in zip(pairwise_results, case_weights)
            ) / total_case_weight
            if total_case_weight else 0.0
        )
        pairwise_by_learnability: dict[str, Any] = {}
        for level in ("high", "medium", "low", "unspecified"):
            level_items = [
                item for item in pairwise_results
                if (item["case"].get("learnability") or {}).get(
                    "level",
                    "unspecified",
                ) == level
            ]
            if not level_items:
                continue
            pairwise_by_learnability[level] = {
                "cases": len(level_items),
                "accuracy": round(statistics.mean([
                    float(
                        item["recommendation_score"].get(
                            "expected_safe_ok",
                            False,
                        )
                    )
                    for item in level_items
                ]), 4),
                "raw_accuracy": round(statistics.mean([
                    float(
                        item["raw_recommendation_score"].get(
                            "expected_safe_ok",
                            False,
                        )
                    )
                    for item in level_items
                ]), 4),
            }
        narrative_sources = [
            source for source in [
                (full_profile or {}).get("summary_source"),
                *[item.get("profile_summary_source") for item in pairwise_results],
            ]
            if source is not None
        ]
        narrative_model_kept_rate = (
            round(
                sum(source == "model" for source in narrative_sources)
                / len(narrative_sources),
                4,
            )
            if narrative_sources else None
        )
        regression_watch_results = [
            {
                "case_id": item["case"].get("id"),
                "level": (item["case"].get("learnability") or {}).get(
                    "level",
                    "unspecified",
                ),
                "pipeline_expected_safe_ok": bool(
                    item["recommendation_score"].get("expected_safe_ok", False)
                ),
                "raw_expected_safe_ok": bool(
                    item["raw_recommendation_score"].get("expected_safe_ok", False)
                ),
            }
            for item in pairwise_results
            if item["case"].get("regression_watch")
        ]
        evidence_scores = [
            full_profile_score.get("evidence_reference_accuracy", 0.0),
            *[
                item["profile_score"].get("evidence_reference_accuracy", 0.0)
                for item in pairwise_results
            ],
            *[
                item["recommendation_score"].get("evidence_reference_accuracy", 0.0)
                for item in pairwise_results
            ],
            current_score.get("evidence_reference_accuracy", 0.0),
        ]
        profile_avg = statistics.mean(profile_scores) if profile_scores else 0.0
        rec_contract = statistics.mean([*rec_scores, current_score.get("score", 0.0)])
        evidence_avg = statistics.mean(evidence_scores) if evidence_scores else 0.0
        raw_profile_avg = (
            statistics.mean(raw_profile_scores) if raw_profile_scores else 0.0
        )
        raw_rec_contract = statistics.mean([
            *raw_rec_scores,
            raw_current_score.get("score", 0.0),
        ])
        raw_evidence_scores = [
            raw_full_profile_score.get("evidence_reference_accuracy", 0.0),
            *[
                item["raw_profile_score"].get("evidence_reference_accuracy", 0.0)
                for item in pairwise_results
            ],
            *[
                item["raw_recommendation_score"].get(
                    "evidence_reference_accuracy",
                    0.0,
                )
                for item in pairwise_results
            ],
            raw_current_score.get("evidence_reference_accuracy", 0.0),
        ]
        raw_evidence_avg = (
            statistics.mean(raw_evidence_scores) if raw_evidence_scores else 0.0
        )
        overall = (
            profile_avg * 0.30
            + pairwise_accuracy * 0.35
            + rec_contract * 0.20
            + evidence_avg * 0.15
        )
        raw_overall = (
            raw_profile_avg * 0.30
            + raw_pairwise_accuracy * 0.35
            + raw_rec_contract * 0.20
            + raw_evidence_avg * 0.15
        )
        summary = {
            "version": version,
            "model": model,
            "cases": len(pairwise_results),
            "profile_score": round(profile_avg, 4),
            "pairwise_accuracy": round(pairwise_accuracy, 4),
            "pairwise_accuracy_unweighted": round(
                pairwise_accuracy_unweighted,
                4,
            ),
            "pairwise_by_learnability": pairwise_by_learnability,
            "regression_watch": regression_watch_results,
            "narrative_model_kept_rate": narrative_model_kept_rate,
            "recommendation_contract_score": round(rec_contract, 4),
            "evidence_reference_accuracy": round(evidence_avg, 4),
            "overall_score": round(overall, 4),
            "raw_profile_score": round(raw_profile_avg, 4),
            "raw_pairwise_accuracy": round(raw_pairwise_accuracy, 4),
            "raw_pairwise_accuracy_unweighted": round(
                raw_pairwise_accuracy_unweighted,
                4,
            ),
            "raw_recommendation_contract_score": round(raw_rec_contract, 4),
            "raw_evidence_reference_accuracy": round(raw_evidence_avg, 4),
            "raw_overall_score": round(raw_overall, 4),
            "full_profile_score": full_profile_score,
            "current_recommendation_score": current_score,
            "holdouts": pairwise_results,
        }
        write_json(version_dir / "summary.json", summary)
        summaries[version] = summary
        version_outputs[version] = {
            "profile": full_profile,
            "current_recommendation": current_recommendation,
        }

    render_evaluation_summary(
        output_dir / "evaluation_summary.md",
        model,
        len(selected_cases),
        summaries,
        selected_versions,
    )
    if (
        PRODUCT_VERSION in version_outputs
        and version_outputs[PRODUCT_VERSION]["profile"]
        and version_outputs[PRODUCT_VERSION]["current_recommendation"]
    ):
        render_current_report(
            Path("private/coffee_taste/current_profile_and_recommendations.md"),
            dataset,
            version_outputs[PRODUCT_VERSION]["profile"],
            version_outputs[PRODUCT_VERSION]["current_recommendation"],
            live_candidates,
            model,
        )
        write_json(
            Path("private/coffee_taste/current_profile.json"),
            version_outputs[PRODUCT_VERSION]["profile"],
        )
        write_json(
            Path("private/coffee_taste/current_recommendations.json"),
            version_outputs[PRODUCT_VERSION]["current_recommendation"],
        )

    write_json(output_dir / "run_summary.json", {
        "run_id": run_id,
        "model": model,
        "thinking": args.thinking,
        "dataset": str(args.dataset),
        "cases": str(args.cases),
        "live_candidates": str(args.candidates),
        "summaries": summaries,
    })
    print(json.dumps({
        "output_dir": str(output_dir),
        "summaries": {
            version: {
                key: summaries[version][key]
                for key in (
                    "overall_score",
                    "raw_overall_score",
                    "profile_score",
                    "pairwise_accuracy",
                    "recommendation_contract_score",
                    "evidence_reference_accuracy",
                )
            }
            for version in selected_versions
        },
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
