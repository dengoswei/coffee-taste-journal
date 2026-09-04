#!/usr/bin/env python3
"""Export the aggregate-only taste profile used by the iOS comparison scorer."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from portable_coffee_rank import (
    build_portable_profile,
    bridge_qualifies,
    compare_explorer_candidates,
    explorer_exclusion_reason,
    normalized_text,
    profile_digest,
    resolve_scored_rows,
    round_tenth,
    scorer_contract_version,
    similar_fit_bands,
)


ROOT = Path(__file__).resolve().parents[1]
PRIVATE_DATASET = ROOT / "private" / "coffee_taste" / "dataset.json"
REFERENCE_SCORER = ROOT / "scripts" / "portable_coffee_rank.py"
SWIFT_SCORER = ROOT / "Sources" / "CoffeeJournalCore" / "BeanExplorerScoring.swift"
DEFAULT_OUT = ROOT / "Sources" / "CoffeeJournalApp" / "Resources" / "TasteProfile"
GENERATED_SWIFT = ROOT / "Sources" / "CoffeeJournalApp" / "BeanExplorerGeneratedContract.swift"


FIXTURE_CANDIDATES = [
    {
        "id": "fixture-colombia-washed",
        "roaster": "Fixture Roaster A",
        "name": "Citrus Lot",
        "origin": "Colombia",
        "process": "Washed",
        "descriptors": ["orange", "nectarine", "clean"],
    },
    {
        "id": "fixture-ethiopia-natural",
        "roaster": "Fixture Roaster B",
        "name": "Berry Lot",
        "origin": "Ethiopia",
        "process": "Natural",
        "descriptors": ["blueberry", "jasmine"],
    },
    {
        "id": "fixture-unknown-experimental",
        "roaster": "Fixture Roaster C",
        "name": "Tropical Lot",
        "origin": "Ecuador",
        "process": "Experimental",
        "descriptors": ["mango", "cardamom"],
    },
]


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def pretty_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def role_fixture(name: str, rows: list[dict], profile: dict) -> dict:
    resolved = resolve_scored_rows(rows, profile)
    return {
        "name": name,
        "rows": rows,
        "expected_ranking": [row["candidate_id"] for row in resolved["ranking"]],
        "expected_best": resolved["best_supported_match"],
        "expected_frontier": resolved["frontier_pick"],
        "expected_bands": resolved["similar_fit_bands"],
    }


def export(out: Path) -> dict[str, object]:
    dataset = json.loads(PRIVATE_DATASET.read_text())
    scorer_version = scorer_contract_version()
    profile = build_portable_profile(
        dataset["observations"],
        dataset_generated_at=dataset["generated_at"],
        scorer_version=scorer_version,
    )

    # Small-cell roaster history stays private in the first app release. The
    # JSON still carries the exact zero-effect configuration used by the
    # reference scorer, so Swift/Python parity does not require copied weights.
    profile["statistics"]["roaster_stats"] = []
    profile["privacy"]["roaster_affinity_available"] = False
    profile["scoring"]["near_tie_fit_delta"] = 1.5
    profile["lexicon_version"] = sha256(canonical_bytes(profile["lexicon"]))
    profile["profile_id"] = profile_digest(profile)

    state = {
        "is_confirmed": True,
        "confirmed_fields": ["roaster", "name", "origin", "process", "flavor_notes"],
        "field_provenance": {
            "roaster": "userEntered",
            "name": "userEntered",
            "origin": "userEntered",
            "process": "userEntered",
            "flavor_notes": "userEntered",
        },
        "unresolved_fields": [],
    }
    stateful_candidates = [{**candidate, **state} for candidate in FIXTURE_CANDIDATES]
    comparison = compare_explorer_candidates(stateful_candidates, profile)
    null_frontier_candidates = [
        {**stateful_candidates[0], "id": "tea-a", "name": "Tea A", "descriptors": ["black tea"]},
        {**stateful_candidates[1], "id": "tea-b", "name": "Tea B", "descriptors": ["oolong"]},
    ]
    null_frontier = compare_explorer_candidates(null_frontier_candidates, profile)
    eligibility_candidates = [
        stateful_candidates[0],
        {**stateful_candidates[0], "id": "unconfirmed", "is_confirmed": False},
        {**stateful_candidates[0], "id": "unresolved", "unresolved_fields": ["origin"]},
        {**stateful_candidates[0], "id": "missing-provenance", "field_provenance": {}},
        {**stateful_candidates[0], "id": "unknown-note", "descriptors": ["silky"]},
    ]
    fixtures = {
        "schema_version": 1,
        "profile_id": profile["profile_id"],
        "scorer_version": scorer_version,
        "score_cases": [
            {
                "candidate": candidate,
                "expected": next(
                    row for row in comparison["ranking"]
                    if row["candidate_id"] == candidate["id"]
                ),
            }
            for candidate in stateful_candidates
        ],
        "comparison_cases": [
            {
                "name": "distinct_frontier_and_ordering",
                "candidates": stateful_candidates,
                "expected_ranking": [row["candidate_id"] for row in comparison["ranking"]],
                "expected_best": comparison["best_supported_match"],
                "expected_frontier": comparison["frontier_pick"],
                "expected_bands": comparison["similar_fit_bands"],
                "expected_bridges": {
                    row["candidate_id"]: row["familiar_bridges"]
                    for row in comparison["ranking"]
                },
            },
            {
                "name": "nullable_frontier_without_bridge",
                "candidates": null_frontier_candidates,
                "expected_ranking": [row["candidate_id"] for row in null_frontier["ranking"]],
                "expected_best": null_frontier["best_supported_match"],
                "expected_frontier": null_frontier["frontier_pick"],
                "expected_bands": null_frontier["similar_fit_bands"],
                "expected_bridges": {
                    row["candidate_id"]: row["familiar_bridges"]
                    for row in null_frontier["ranking"]
                },
            },
        ],
        "eligibility_cases": [
            {
                "candidate": candidate,
                "expected_reason": explorer_exclusion_reason(candidate, profile),
            }
            for candidate in eligibility_candidates
        ],
        "normalization_cases": [
            {"input": value, "expected": normalized_text(value)}
            for value in [" ＣＯＬＯＭＢＩＡ　Washed ", "CAFÉ", "Straße", "果  香"]
        ],
        "rounding_cases": [
            {"input": value, "expected": round_tenth(value)}
            for value in [1.24, 1.25, -1.25, 72.85]
        ],
        "band_cases": [{
            "fits": [80.0, 79.0, 78.0, 76.5],
            "expected": similar_fit_bands([
                {"candidate_id": f"band-{index}", "profile_fit_score": fit}
                for index, fit in enumerate([80.0, 79.0, 78.0, 76.5])
            ], 1.5),
        }],
        "bridge_boundary_cases": [
            {
                "top_tier_count": top_count,
                "observations": observations,
                "expected": bridge_qualifies(top_count, observations, profile["scoring"]),
            }
            for top_count, observations in [(3, 6), (2, 6), (3, 5), (4, 7)]
        ],
        "role_cases": [],
    }
    synthetic_role_rows = [
        (
            "fit_then_novelty_then_id",
            [
                {"candidate_id": "b", "profile_fit_score": 70.0, "profile_novelty_score": 20.0, "familiar_bridges": [{}]},
                {"candidate_id": "a", "profile_fit_score": 70.0, "profile_novelty_score": 20.0, "familiar_bridges": [{}]},
                {"candidate_id": "c", "profile_fit_score": 70.0, "profile_novelty_score": 30.0, "familiar_bridges": [{}]},
            ],
        ),
        (
            "frontier_blend_tie_uses_fit",
            [
                {"candidate_id": "best", "profile_fit_score": 90.0, "profile_novelty_score": 0.0, "familiar_bridges": [{}]},
                {"candidate_id": "lower-fit", "profile_fit_score": 60.0, "profile_novelty_score": 60.0, "familiar_bridges": [{}]},
                {"candidate_id": "higher-fit", "profile_fit_score": 71.0, "profile_novelty_score": 51.0, "familiar_bridges": [{}]},
            ],
        ),
        (
            "frontier_fit_threshold_is_inclusive",
            [
                {"candidate_id": "best", "profile_fit_score": 90.0, "profile_novelty_score": 0.0, "familiar_bridges": [{}]},
                {"candidate_id": "threshold", "profile_fit_score": 60.0, "profile_novelty_score": 100.0, "familiar_bridges": [{}]},
            ],
        ),
        (
            "frontier_is_null_without_bridge",
            [
                {"candidate_id": "best", "profile_fit_score": 90.0, "profile_novelty_score": 0.0, "familiar_bridges": [{}]},
                {"candidate_id": "no-bridge", "profile_fit_score": 80.0, "profile_novelty_score": 100.0, "familiar_bridges": []},
            ],
        ),
    ]
    fixtures["role_cases"] = [
        role_fixture(name, rows, profile)
        for name, rows in synthetic_role_rows
    ]

    out.mkdir(parents=True, exist_ok=True)
    profile_data = pretty_bytes(profile)
    fixture_data = pretty_bytes(fixtures)
    (out / "profile-prior.json").write_bytes(profile_data)
    (out / "profile-parity-fixtures.json").write_bytes(fixture_data)

    manifest = {
        "schema_version": 1,
        "profile_id": profile["profile_id"],
        "scorer_version": scorer_version,
        "lexicon_version": profile["lexicon_version"],
        "swift_scorer_source_sha256": sha256(SWIFT_SCORER.read_bytes()),
        "python_scorer_source_sha256": sha256(REFERENCE_SCORER.read_bytes()),
        "files": {
            "profile-prior.json": sha256(profile_data),
            "profile-parity-fixtures.json": sha256(fixture_data),
        },
    }
    manifest_data = pretty_bytes(manifest)
    (out / "manifest.json").write_bytes(manifest_data)

    swift_contract = f'''// Generated by scripts/export_app_taste_profile.py. Do not edit by hand.
import Foundation

enum BeanExplorerGeneratedContract {{
    static let profileID = "{profile["profile_id"]}"
    static let scorerVersion = "{scorer_version}"
    static let lexiconVersion = "{profile["lexicon_version"]}"
    static let manifestSHA256 = "{sha256(manifest_data)}"
    static let profileSHA256 = "{manifest["files"]["profile-prior.json"]}"
    static let fixtureSHA256 = "{manifest["files"]["profile-parity-fixtures.json"]}"
    static let swiftScorerSourceSHA256 = "{manifest["swift_scorer_source_sha256"]}"
    static let pythonScorerSourceSHA256 = "{manifest["python_scorer_source_sha256"]}"
}}
'''
    GENERATED_SWIFT.write_text(swift_contract)
    return {
        "out": str(out),
        "profile_id": profile["profile_id"],
        "rated_observations": profile["evidence_base"]["rated_observations"],
        "files": manifest["files"],
        "manifest_sha256": sha256(manifest_data),
        "swift_contract": str(GENERATED_SWIFT),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    print(json.dumps(export(args.out), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
