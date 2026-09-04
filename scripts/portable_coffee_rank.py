#!/usr/bin/env python3
"""Rank coffee candidates from aggregate profile statistics only.

The exported profile contains no observation rows, coffee identities, notes,
dates, or brew details. This scorer reproduces the profile-dependent component
of the journal's ``candidate_prior``. Direct-history adjustments remain
unavailable unless the private journal pipeline is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import statistics
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any


PORTABLE_SCHEMA_VERSION = 1


def normalized_text(value: Any) -> str:
    text = unicodedata.normalize("NFKC", str(value or "")).lower()
    return " ".join(text.split())


def normalized_key(value: Any) -> str:
    return normalized_text(value)


def term_matches(haystack: str, term: str) -> bool:
    normalized = normalized_text(term)
    if re.search(r"[a-z0-9]", normalized):
        return re.search(
            rf"(?<![a-z0-9]){re.escape(normalized)}(?![a-z0-9])",
            haystack,
        ) is not None
    return normalized in haystack


def matched_terms(parts: list[str], vocabulary: dict[str, list[str]]) -> list[str]:
    haystack = " | ".join(normalized_text(item) for item in parts)
    return sorted(
        key
        for key, terms in vocabulary.items()
        if any(term_matches(haystack, term) for term in terms)
    )


def normalized_rating(value: float, config: dict[str, Any]) -> float:
    minimum = float(config["rating_scale"]["min"])
    maximum = float(config["rating_scale"]["max"])
    span = maximum - minimum
    return max(0.0, min(100.0, ((float(value) - minimum) / span) * 100))


def stat_map(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {normalized_key(row["feature"]): row for row in rows}


def compact_stats(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "feature": row["feature"],
            "n": row["observations"],
            "weighted_rating": row.get("weighted_rating"),
        }
        for row in rows
    ]


def profile_digest(profile: dict[str, Any]) -> str:
    unsigned = dict(profile)
    unsigned.pop("profile_id", None)
    canonical = json.dumps(
        unsigned,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def round_tenth(value: float) -> float:
    scaled = float(value) * 10.0
    rounded = math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
    return rounded / 10.0


def scorer_contract_version() -> str:
    contract = {
        "contract_version": 2,
        "normalization": "Unicode NFKC, lowercase en_US_POSIX-equivalent, collapse whitespace",
        "term_matching": "ASCII alphanumeric boundaries; non-ASCII substring",
        "rounding": "IEEE-754 binary64 multiply by 10, then half away from zero, divide by 10",
        "ranking": "fit descending, novelty descending, canonical candidate id ascending",
        "eligibility": "confirmed field-level provenance; unresolved fields fail closed",
        "frontier": "distinct, min fit, familiar bridge, blend descending, fit descending, id ascending",
        "similar_fit": "non-chaining bands anchored at each band's highest fit",
        "scoring": scoring_config(),
    }
    canonical = json.dumps(contract, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def validate_profile(
    profile: dict[str, Any],
    *,
    scorer_version: str | None = None,
) -> None:
    if profile.get("schema_version") != PORTABLE_SCHEMA_VERSION:
        raise ValueError("unsupported portable profile schema")
    if profile.get("mode") != "portable_profile":
        raise ValueError("portable scorer requires mode=portable_profile")
    if profile.get("profile_id") != profile_digest(profile):
        raise ValueError("portable profile digest mismatch")
    if scorer_version is not None and profile.get("scorer_version") != scorer_version:
        raise ValueError("portable scorer version mismatch")


def scoring_config() -> dict[str, Any]:
    return {
        "rating_scale": {"min": 0.0, "max": 3.0},
        "fit_weights": {"sensory": 0.75, "origin": 0.15, "process": 0.10},
        "unknown_fit": 50.0,
        "quality_bonus": {
            "cap": 7.0,
            "signals": {
                "clarity_positive": 3.0,
                "cleanliness_positive": 3.0,
                "acid_sweet_balance_positive": 3.0,
                "brightness_positive": 1.5,
                "juiciness_positive": 1.0,
            },
        },
        "top_tier_bonus": {"per_family": 2.5, "cap": 5.0},
        "roaster_bonus": {"scale": 0.09, "cap": 3.0},
        "novelty": {
            "weights": {"category": 0.50, "origin": 0.25, "process": 0.25},
            "category_full_familiarity_observations": 6,
            "origin_familiarity": {"known": 80.0, "unknown": 10.0},
            "process_familiarity": {"known": 80.0, "unknown": 20.0},
        },
        "frontier": {
            "min_fit": 60.0,
            "novelty_weight": 0.55,
            "fit_weight": 0.45,
            "min_top_tier_count": 3,
            "min_category_observations": 6,
        },
        "near_tie_fit_delta": 1.5,
        "history": {
            "mode": "unavailable_without_private",
            "fit_bonus": None,
            "novelty_penalty": None,
        },
    }


def build_portable_profile(
    observations: list[dict[str, Any]],
    *,
    dataset_generated_at: str,
    scorer_version: str,
) -> dict[str, Any]:
    """Build irreversible sufficient statistics from private observations."""
    from build_coffee_taste_dataset import CATEGORY_TERMS, QUALITY_TERMS
    from evaluate_coffee_taste_prompts import (
        TOP_TIER_MIN_OBSERVATIONS,
        build_evidence_packet,
    )

    packet = build_evidence_packet(observations)
    tiers = Counter(
        item["rating"].get("label")
        for item in observations
        if item["rating"].get("score") is not None
    )
    profile: dict[str, Any] = {
        "schema_version": PORTABLE_SCHEMA_VERSION,
        "mode": "portable_profile",
        "dataset_generated_at": dataset_generated_at,
        "scorer_version": scorer_version,
        "privacy": {
            "classification": "derived_personal_preference_aggregates",
            "contains_raw_observations": False,
            "contains_coffee_identities": False,
            "contains_notes_dates_or_brew_details": False,
            "history_adjustment_available": False,
        },
        "evidence_base": {
            "rated_observations": sum(tiers.values()),
            "rating_distribution": dict(sorted(tiers.items())),
        },
        "statistics": {
            "category_stats": compact_stats(packet["category_stats"]),
            "origin_stats": compact_stats(packet["origin_stats"]),
            "process_stats": compact_stats(packet["process_stats"]),
            "roaster_stats": compact_stats(packet.get("roaster_stats", [])),
            "top_tier_families": [
                {
                    "category": row["category"],
                    "top_tier_count": row["top_tier_count"],
                }
                for row in packet["top_tier_family_stats"]
                if row["top_tier_count"] >= TOP_TIER_MIN_OBSERVATIONS
            ],
        },
        "lexicon": {
            "category_terms": {
                key: list(terms) for key, terms in sorted(CATEGORY_TERMS.items())
            },
            "quality_terms": {
                key: list(terms) for key, terms in sorted(QUALITY_TERMS.items())
            },
            "matching": "NFKC lowercase; ASCII word boundaries; CJK substring",
        },
        "scoring": scoring_config(),
    }
    profile["profile_id"] = profile_digest(profile)
    return profile


def score_candidate(
    candidate: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, Any]:
    config = profile["scoring"]
    stats = profile["statistics"]
    categories = matched_terms(
        candidate.get("descriptors", []),
        profile["lexicon"]["category_terms"],
    )
    quality_signals = matched_terms(
        candidate.get("descriptors", []),
        profile["lexicon"]["quality_terms"],
    )
    category_stats = stat_map(stats["category_stats"])
    origin_stats = stat_map(stats["origin_stats"])
    process_stats = stat_map(stats["process_stats"])
    roaster_stats = stat_map(stats.get("roaster_stats", []))

    family_breakdown = []
    family_scores = []
    for category in categories:
        row = category_stats.get(normalized_key(category))
        score = (
            normalized_rating(row["weighted_rating"], config)
            if row and row.get("weighted_rating") is not None else None
        )
        if score is not None:
            family_scores.append(score)
        family_breakdown.append({
            "category": category,
            "n": row["n"] if row else 0,
            "weighted_rating": row.get("weighted_rating") if row else None,
            "score": round_tenth(score) if score is not None else None,
        })
    sensory_fit = (
        statistics.mean(family_scores)
        if family_scores else config["unknown_fit"]
    )

    origin_row = origin_stats.get(normalized_key(candidate.get("origin")))
    process_row = process_stats.get(normalized_key(candidate.get("process")))
    origin_fit = (
        normalized_rating(origin_row["weighted_rating"], config)
        if origin_row and origin_row.get("weighted_rating") is not None
        else config["unknown_fit"]
    )
    process_fit = (
        normalized_rating(process_row["weighted_rating"], config)
        if process_row and process_row.get("weighted_rating") is not None
        else config["unknown_fit"]
    )
    weights = config["fit_weights"]
    base_fit = (
        sensory_fit * weights["sensory"]
        + origin_fit * weights["origin"]
        + process_fit * weights["process"]
    )

    quality_cfg = config["quality_bonus"]
    quality_bonus = min(
        quality_cfg["cap"],
        sum(quality_cfg["signals"].get(signal, 0.0) for signal in quality_signals),
    )
    top_tier = {row["category"] for row in stats["top_tier_families"]}
    top_cfg = config["top_tier_bonus"]
    top_tier_hits = sorted(top_tier.intersection(categories))
    top_tier_bonus = min(top_cfg["cap"], top_cfg["per_family"] * len(top_tier_hits))

    roaster_row = roaster_stats.get(normalized_key(candidate.get("roaster")))
    roaster_bonus = 0.0
    if roaster_row and roaster_row.get("weighted_rating") is not None:
        scaled = normalized_rating(roaster_row["weighted_rating"], config)
        roaster_cfg = config["roaster_bonus"]
        roaster_bonus = max(
            -roaster_cfg["cap"],
            min(roaster_cfg["cap"], (scaled - 50.0) * roaster_cfg["scale"]),
        )
    profile_fit = min(100.0, base_fit + quality_bonus + top_tier_bonus + roaster_bonus)

    novelty_cfg = config["novelty"]
    category_familiarity_scores = [
        min(
            1.0,
            category_stats[normalized_key(category)]["n"]
            / novelty_cfg["category_full_familiarity_observations"],
        ) * 100
        for category in categories
        if normalized_key(category) in category_stats
    ]
    category_familiarity = (
        statistics.mean(category_familiarity_scores)
        if category_familiarity_scores else 0.0
    )
    origin_familiarity = novelty_cfg["origin_familiarity"][
        "known" if origin_row else "unknown"
    ]
    process_familiarity = novelty_cfg["process_familiarity"][
        "known" if process_row else "unknown"
    ]
    novelty_weights = novelty_cfg["weights"]
    profile_novelty = 100 - (
        category_familiarity * novelty_weights["category"]
        + origin_familiarity * novelty_weights["origin"]
        + process_familiarity * novelty_weights["process"]
    )
    profile_novelty = max(0.0, min(100.0, profile_novelty))

    top_tier_by_category = {
        row["category"]: row["top_tier_count"]
        for row in stats["top_tier_families"]
    }
    familiar_bridges = [
        {
            "category": category,
            "top_tier_count": top_tier_by_category[category],
            "observations": category_stats[normalized_key(category)]["n"],
        }
        for category in categories
        if bridge_qualifies(
            top_tier_by_category.get(category, 0),
            category_stats.get(normalized_key(category), {}).get("n", 0),
            config,
        )
    ]

    return {
        "candidate_id": candidate["id"],
        "roaster": candidate.get("roaster"),
        "name": candidate.get("name"),
        "score_mode": "portable_profile",
        "profile_fit_score": round_tenth(profile_fit),
        "profile_novelty_score": round_tenth(profile_novelty),
        "history_adjustment": None,
        "personalized_fit_score": None,
        "personalized_novelty_score": None,
        "fit_score": round_tenth(profile_fit),
        "novelty_score": round_tenth(profile_novelty),
        "components": {
            "sensory_fit": round_tenth(sensory_fit),
            "origin_fit": round_tenth(origin_fit),
            "process_fit": round_tenth(process_fit),
            "base_fit": round_tenth(base_fit),
            "quality_claim_bonus": round_tenth(quality_bonus),
            "top_tier_affinity_bonus": round_tenth(top_tier_bonus),
            "roaster_affinity_bonus": round_tenth(roaster_bonus),
        },
        "descriptor_categories": categories,
        "family_breakdown": family_breakdown,
        "top_tier_hits": top_tier_hits,
        "familiar_bridges": familiar_bridges,
        "missing_signals": ["direct_history"],
    }


def explorer_exclusion_reason(candidate: dict[str, Any], profile: dict[str, Any]) -> str | None:
    if not candidate.get("is_confirmed"):
        return "Confirm this candidate after reviewing the extracted fields."
    if candidate.get("unresolved_fields"):
        return "Resolve uncertain score inputs before comparison."
    for field, label in (
        ("roaster", "Roaster"),
        ("name", "Full coffee name"),
        ("origin", "Origin"),
        ("process", "Process"),
    ):
        if not normalized_text(candidate.get(field)):
            return f"{label} is required."
    if not matched_terms(candidate.get("descriptors", []), profile["lexicon"]["category_terms"]):
        return "Add at least one seller flavor note recognized by the profile."
    score_fields = {"roaster", "name", "origin", "process", "flavor_notes"}
    if not score_fields.issubset(set(candidate.get("confirmed_fields", []))):
        return "Confirm every field used by the scorer."
    provenance = candidate.get("field_provenance") or {}
    if not all(provenance.get(field) in {"extracted", "userEntered"} for field in score_fields):
        return "Every score input needs visible or user-entered provenance."
    return None


def similar_fit_bands(rows: list[dict[str, Any]], threshold: float) -> list[list[str]]:
    bands: list[list[str]] = []
    anchor_fit: float | None = None
    for row in rows:
        fit = float(row["profile_fit_score"])
        if anchor_fit is None or anchor_fit - fit > threshold:
            bands.append([])
            anchor_fit = fit
        bands[-1].append(row["candidate_id"])
    return bands


def bridge_qualifies(top_tier_count: int, observations: int, config: dict[str, Any]) -> bool:
    frontier = config["frontier"]
    return (
        top_tier_count >= frontier["min_top_tier_count"]
        and observations >= frontier["min_category_observations"]
    )


def resolve_scored_rows(rows: list[dict[str, Any]], profile: dict[str, Any]) -> dict[str, Any]:
    ranked = sorted(rows, key=lambda row: (
        -row["profile_fit_score"],
        -row["profile_novelty_score"],
        row["candidate_id"],
    ))
    if not ranked:
        raise ValueError("no scorable candidates")
    best = ranked[0]
    frontier_cfg = profile["scoring"]["frontier"]
    frontier = next(iter(sorted(
        [
            row for row in ranked
            if row["candidate_id"] != best["candidate_id"]
            and row["profile_fit_score"] >= frontier_cfg["min_fit"]
            and row.get("familiar_bridges")
        ],
        key=lambda row: (
            -(row["profile_novelty_score"] * frontier_cfg["novelty_weight"]
              + row["profile_fit_score"] * frontier_cfg["fit_weight"]),
            -row["profile_fit_score"],
            row["candidate_id"],
        ),
    )), None)
    return {
        "ranking": ranked,
        "best_supported_match": best["candidate_id"],
        "frontier_pick": frontier["candidate_id"] if frontier else None,
        "similar_fit_bands": similar_fit_bands(
            ranked,
            profile["scoring"]["near_tie_fit_delta"],
        ),
    }


def compare_explorer_candidates(
    candidates: list[dict[str, Any]],
    profile: dict[str, Any],
) -> dict[str, Any]:
    rows = []
    excluded = []
    for candidate in candidates:
        reason = explorer_exclusion_reason(candidate, profile)
        if reason is None:
            rows.append(score_candidate(candidate, profile))
        else:
            excluded.append({"candidate_id": candidate["id"], "reason": reason})
    resolved = resolve_scored_rows(rows, profile)
    return {
        "score_mode": "portable_profile",
        "profile_id": profile["profile_id"],
        "scorer_version": profile["scorer_version"],
        "history_adjustment_available": False,
        "excluded": excluded,
        **resolved,
    }


def rank_candidates(
    candidates: list[dict[str, Any]],
    profile: dict[str, Any],
) -> dict[str, Any]:
    rows = [
        score_candidate(candidate, profile)
        for candidate in candidates
    ]
    if not rows:
        raise ValueError("no available candidates")
    resolved = resolve_scored_rows(rows, profile)
    return {
        "score_mode": "portable_profile",
        "profile_id": profile["profile_id"],
        "scorer_version": profile["scorer_version"],
        "history_adjustment_available": False,
        "safe_match": resolved["best_supported_match"],
        "frontier_pick": resolved["frontier_pick"],
        "similar_fit_bands": resolved["similar_fit_bands"],
        "ranking": resolved["ranking"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    scorer_version = scorer_contract_version()
    validate_profile(profile, scorer_version=scorer_version)
    candidate_document = json.loads(args.candidates.read_text())
    print(json.dumps(
        rank_candidates(candidate_document["candidates"], profile),
        ensure_ascii=False,
        indent=2,
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
