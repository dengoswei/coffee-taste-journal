#!/usr/bin/env python3
"""Rank a candidate bean list against the current profile, deterministically.

Every number comes from the deterministic prior + ground_recommendation
(lock_to_prior=True) — the same grounded path the eval harness scores. The
JSON printed to stdout includes a per-candidate breakdown (bonus components,
history match scope, matched flavor families, top-tier hits) so the caller
can explain each pick without inventing evidence.

Outputs (under private/, gitignored):
  private/coffee_taste/current_profile_and_recommendations.md
  private/coffee_taste/current_recommendations.json
"""
import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts"))

from evaluate_coffee_taste_prompts import (  # noqa: E402
    TOP_TIER_MIN_OBSERVATIONS,
    build_evidence_packet,
    build_profile_contract,
    enrich_candidates_with_analogs,
    ground_profile,
    ground_recommendation,
    render_current_report,
    score_recommendation,
    shortlist_live_candidates,
    validate_model_narrative,
)

PRIVATE = REPO / "private" / "coffee_taste"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidates",
        type=Path,
        default=PRIVATE / "live_candidates.json",
        help="Candidate list JSON ({'candidates': [...]}).",
    )
    parser.add_argument(
        "--narrative",
        type=Path,
        default=None,
        help="Optional guardrail-validated emotive summary JSON; "
        "fallback contract summary is used when omitted or invalid.",
    )
    parser.add_argument(
        "--scope",
        default="User-provided shortlist",
        help="purchase_scope string recorded in the constraints.",
    )
    args = parser.parse_args()

    dataset = json.loads((PRIVATE / "dataset.json").read_text())
    live = json.loads(args.candidates.read_text())
    observations = dataset["observations"]
    valid_ids = {item["id"] for item in observations}
    packet = build_evidence_packet(observations)
    contract = build_profile_contract(observations)
    cases_path = PRIVATE / "eval_cases.json"
    assertions = (
        json.loads(cases_path.read_text()).get("profile_assertions", {})
        if cases_path.exists() else {}
    )

    profile = ground_profile({"summary": {}}, contract, keep_model_summary=False)
    if args.narrative is not None:
        summary = json.loads(args.narrative.read_text())
        if validate_model_narrative(summary, contract, assertions) == []:
            profile = ground_profile(
                {"summary": summary}, contract,
                keep_model_summary=True, assertions=assertions,
            )

    shortlisted = shortlist_live_candidates(live["candidates"], packet, observations)
    shortlisted = enrich_candidates_with_analogs(shortlisted, observations)

    rows = []
    for candidate in shortlisted:
        prior = candidate["deterministic_prior"]
        rows.append({
            "candidate_id": candidate["id"],
            "fit_score": prior["fit_score"],
            "novelty_score": prior["novelty_score"],
            "confidence": prior.get("confidence", 0.55),
            "short_reason": "deterministic prior",
        })
    if not rows:
        print(json.dumps({"error": "no candidate passed the shortlist gate"}))
        return 1
    rows.sort(key=lambda row: -row["fit_score"])
    safe_id = rows[0]["candidate_id"]
    frontier_pool = [row for row in rows if row["candidate_id"] != safe_id]
    frontier_id = (
        max(
            frontier_pool,
            key=lambda row: row["novelty_score"] * 0.55 + row["fit_score"] * 0.45,
        )["candidate_id"]
        if frontier_pool else safe_id
    )

    raw = {
        "safe_match": {
            "candidate_id": safe_id,
            "expected_liking": int(round(rows[0]["fit_score"])),
            "confidence": rows[0]["confidence"],
            "reasons": ["generation stand-in"],
            "evidence_ids": [],
            "risks": [],
            "brew_watchpoints": [],
        },
        "frontier_pick": {
            "candidate_id": frontier_id,
            "expected_liking": 0,
            "confidence": 0.5,
            "reasons": ["generation stand-in"],
            "evidence_ids": [],
            "risks": [],
            "brew_watchpoints": [],
            "novelty_dimensions": ["stand-in"],
            "bridge_to_profile": ["stand-in"],
        },
        "ranking": rows,
        "caveats": [],
    }
    constraints = {
        "different_roasters": False,
        "purchase_scope": args.scope,
        "roles": ["safe_match", "frontier_pick"],
    }
    grounded = ground_recommendation(
        raw, shortlisted, valid_ids, constraints, profile, lock_to_prior=True,
    )
    score = score_recommendation(
        grounded,
        {item["id"] for item in shortlisted},
        {item["id"]: item["roaster"] for item in shortlisted},
        valid_ids,
        None,
        constraints,
        ordering_source=raw,
    )

    out_md = PRIVATE / "current_profile_and_recommendations.md"
    render_current_report(
        out_md, dataset, profile, grounded, shortlisted,
        "deterministic grounding (lock_to_prior)",
    )
    (PRIVATE / "current_recommendations.json").write_text(
        json.dumps({"grounded": grounded, "score": score}, ensure_ascii=False, indent=2) + "\n"
    )

    top_tier_families = {
        row["category"]
        for row in packet.get("top_tier_family_stats", [])
        if row["top_tier_count"] >= TOP_TIER_MIN_OBSERVATIONS
    }
    by_id = {item["id"]: item for item in shortlisted}
    breakdown = []
    for row in grounded["ranking"]:
        candidate = by_id[row["candidate_id"]]
        prior = candidate["deterministic_prior"]
        match = candidate.get("direct_history_match") or {}
        breakdown.append({
            "id": row["candidate_id"],
            "roaster": candidate.get("roaster"),
            "name": candidate.get("name"),
            "fit": round(row["fit_score"], 1),
            "novelty": round(row["novelty_score"], 1),
            "profile_fit": prior["profile_fit_score"],
            "profile_novelty": prior["profile_novelty_score"],
            "history_adjustment": prior["history_adjustment"],
            "descriptor_categories": candidate.get("descriptor_categories", []),
            "top_tier_hits": sorted(
                top_tier_families.intersection(
                    candidate.get("descriptor_categories", [])
                )
            ),
            "bonuses": {
                "quality_claim": prior["quality_claim_bonus"],
                "direct_history": prior["direct_history_bonus"],
                "top_tier_affinity": prior["top_tier_affinity_bonus"],
                "roaster_affinity": prior["roaster_affinity_bonus"],
            },
            "history_match": {
                "scope": match.get("match_scope"),
                "rated_observations": match.get("rated_observations", 0),
                "weighted_rating": match.get("weighted_rating"),
                "observation_ids": match.get("observation_ids", []),
            },
        })

    print(json.dumps({
        "score_mode": "private_full",
        "safe_match": grounded["safe_match"]["candidate_id"],
        "frontier_pick": grounded["frontier_pick"]["candidate_id"],
        "contract_score": score["score"],
        "grounding_adjustments": grounded["grounding_adjustments"],
        "top_tier_families": sorted(top_tier_families),
        "ranking": breakdown,
        "report": str(out_md),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
