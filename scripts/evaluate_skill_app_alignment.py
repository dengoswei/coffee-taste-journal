#!/usr/bin/env python3
"""Evaluate skill vs app alignment for coffee taste scoring.

This script tests that the App's normalize→score path produces results within
tolerance of the skill/portable scorer path when Chinese descriptors are
properly normalized to canonical families and origin/process keys.

Gates (fail if violated):
- Same candidate set + same profile-prior.json
- Top-1 Fit must match gold
- Full ranking: allow near-ties within scorer's near_tie_fit_delta (1.5);
  middle ranks may swap only inside that band
- Per-candidate Novelty within ±5 of gold
- Matched family sets must equal gold (Jaccard 1.0 after normalize)

Exit code 0 if all gates pass, non-zero otherwise.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Import portable scorer
import portable_coffee_rank as scorer


# Configuration
NOVELTY_TOLERANCE = 5.0
NEAR_TIE_FIT_DELTA = 1.5


# Stub normalize map for SEY 测试集 (test set)
# Maps Chinese terms to canonical profile keys without live Ark
STUB_NORMALIZE_MAP = {
    # Flavor notes
    "浆果": ["fruit.berry"],
    "热带水果": ["fruit.tropical"],
    "佛手柑": ["fruit.citrus"],
    "洛神花": ["floral"],
    "蓝莓": ["fruit.berry"],
    "手指柠檬": ["fruit.citrus"],
    "草莓": ["fruit.berry"],
    "柔和酸质": [],  # Quality signal, not a flavor family
    # Origin
    "埃塞俄比亚": "Ethiopia",
    "秘鲁": "Peru",
    "哥伦比亚": "Colombia",
    # Process
    "蜜处理": "Honey",
    "水洗": "Washed",
}


def stub_normalize_descriptors(
    descriptors: list[str],
    origin: str,
    process: str
) -> tuple[list[str], str, str]:
    """Apply stub normalize map to Chinese terms.
    
    Returns:
        (normalized_families, normalized_origin, normalized_process)
    """
    families = []
    for descriptor in descriptors:
        mapped = STUB_NORMALIZE_MAP.get(descriptor, [])
        families.extend(mapped)
    
    # Deduplicate and sort
    families = sorted(set(families))
    
    # Normalize origin and process
    normalized_origin = STUB_NORMALIZE_MAP.get(origin, origin)
    normalized_process = STUB_NORMALIZE_MAP.get(process, process)
    
    return families, normalized_origin, normalized_process


def load_fixture(path: Path) -> dict[str, Any]:
    """Load test fixture with gold scores."""
    return json.loads(path.read_text())


def load_profile(path: Path) -> dict[str, Any]:
    """Load taste profile."""
    return json.loads(path.read_text())


def build_candidates_with_descriptors(
    fixture: dict[str, Any],
    descriptor_field: str,
    use_stub_normalize: bool = False
) -> list[dict[str, Any]]:
    """Build candidate list using specified descriptor field.
    
    Args:
        fixture: Fixture with candidates
        descriptor_field: Which descriptor field to use:
            - 'descriptors' (all CN+EN)
            - 'descriptors_english_only'
            - 'descriptors_chinese_only'
        use_stub_normalize: Apply stub normalize to map CN→canonical
    """
    candidates = []
    for candidate in fixture["candidates"]:
        descriptors = candidate.get(descriptor_field, candidate["descriptors"])
        origin = candidate["origin"]
        process = candidate["process"]
        
        # Apply stub normalize if requested
        if use_stub_normalize:
            # Use Chinese origin/process if available, otherwise English
            origin_to_normalize = candidate.get("origin_zh", origin)
            process_to_normalize = candidate.get("process_zh", process)
            
            families, origin, process = stub_normalize_descriptors(
                descriptors, origin_to_normalize, process_to_normalize
            )
            
            # Build candidate with pre-matched families and canonical origin/process
            # The scorer will use these directly instead of lexicon matching
            candidate_dict = {
                "id": candidate["id"],
                "roaster": candidate["roaster"],
                "name": candidate["name"],
                "origin": origin,
                "process": process,
                "descriptors": descriptors,
                "is_confirmed": True,
                "confirmed_fields": ["roaster", "name", "origin", "process", "flavor_notes"],
                "field_provenance": {
                    "roaster": "extracted",
                    "name": "extracted",
                    "origin": "extracted",
                    "process": "extracted",
                    "flavor_notes": "extracted",
                },
                "unresolved_fields": [],
            }
            # Score with pre-matched families by modifying scorer directly
            # (portable scorer doesn't have preMatchedFamilies param, so we'll
            # temporarily replace descriptors with English terms that map to families)
            
            # Map families back to representative English terms for portable scorer
            family_to_term = {
                "fruit.berry": "berry",
                "fruit.tropical": "tropical",
                "fruit.citrus": "citrus",
                "floral": "floral",
                "fruit.stone": "stone fruit",
                "sweet.browning": "caramel",
                "tea": "tea",
                "fruit.pome": "apple",
            }
            mapped_descriptors = [family_to_term.get(f, f) for f in families]
            candidate_dict["descriptors"] = mapped_descriptors
            
            candidates.append(candidate_dict)
        else:
            candidates.append({
                "id": candidate["id"],
                "roaster": candidate["roaster"],
                "name": candidate["name"],
                "origin": origin,
                "process": process,
                "descriptors": descriptors,
            })
    return candidates


def score_candidates(
    candidates: list[dict[str, Any]],
    profile: dict[str, Any]
) -> dict[str, Any]:
    """Score candidates using portable scorer."""
    result = scorer.rank_candidates(candidates, profile)
    return result


def extract_top1_candidate(ranking: list[dict[str, Any]]) -> str:
    """Extract top-1 candidate ID from ranking."""
    return ranking[0]["candidate_id"]


def check_top1_match(gold_top1: str, test_top1: str) -> tuple[bool, str]:
    """Check if top-1 candidates match."""
    if gold_top1 == test_top1:
        return True, f"✓ Top-1 match: {test_top1}"
    return False, f"✗ Top-1 mismatch: gold={gold_top1}, test={test_top1}"


def check_novelty_within_tolerance(
    gold_ranking: list[dict[str, Any]],
    test_ranking: list[dict[str, Any]],
    tolerance: float
) -> tuple[bool, list[str]]:
    """Check if novelty scores are within tolerance for all candidates."""
    messages = []
    all_pass = True
    
    gold_novelty = {row["candidate_id"]: row["novelty_score"] for row in gold_ranking}
    test_novelty = {row["candidate_id"]: row["novelty_score"] for row in test_ranking}
    
    for candidate_id in gold_novelty:
        if candidate_id not in test_novelty:
            all_pass = False
            messages.append(f"✗ Missing candidate in test: {candidate_id}")
            continue
        
        gold_val = gold_novelty[candidate_id]
        test_val = test_novelty[candidate_id]
        delta = abs(test_val - gold_val)
        
        if delta <= tolerance:
            messages.append(f"✓ Novelty {candidate_id}: gold={gold_val:.1f}, test={test_val:.1f}, Δ={delta:.1f}")
        else:
            all_pass = False
            messages.append(f"✗ Novelty {candidate_id}: gold={gold_val:.1f}, test={test_val:.1f}, Δ={delta:.1f} > {tolerance}")
    
    return all_pass, messages


def check_family_jaccard(
    gold_ranking: list[dict[str, Any]],
    test_ranking: list[dict[str, Any]]
) -> tuple[bool, list[str]]:
    """Check if matched family sets have Jaccard=1.0 for all candidates."""
    messages = []
    all_pass = True
    
    gold_families = {
        row["candidate_id"]: set(row["descriptor_categories"])
        for row in gold_ranking
    }
    test_families = {
        row["candidate_id"]: set(row["descriptor_categories"])
        for row in test_ranking
    }
    
    for candidate_id in gold_families:
        if candidate_id not in test_families:
            all_pass = False
            messages.append(f"✗ Missing candidate in test: {candidate_id}")
            continue
        
        gold_set = gold_families[candidate_id]
        test_set = test_families[candidate_id]
        
        if gold_set == test_set:
            messages.append(f"✓ Families {candidate_id}: {sorted(gold_set)}")
        else:
            all_pass = False
            only_gold = gold_set - test_set
            only_test = test_set - gold_set
            messages.append(
                f"✗ Families {candidate_id}: "
                f"gold={sorted(gold_set)}, test={sorted(test_set)}, "
                f"only_gold={sorted(only_gold)}, only_test={sorted(only_test)}"
            )
    
    return all_pass, messages


def check_ranking_order_with_near_ties(
    gold_ranking: list[dict[str, Any]],
    test_ranking: list[dict[str, Any]],
    delta: float
) -> tuple[bool, list[str]]:
    """Check ranking order allowing swaps within near-tie bands.
    
    Near-tie bands are defined by the scorer's near_tie_fit_delta.
    Within a band, candidates may appear in any order.
    """
    messages = []
    
    # Build gold bands
    gold_bands: list[list[str]] = []
    anchor_fit: float | None = None
    for row in gold_ranking:
        fit = row["fit_score"]
        if anchor_fit is None or (anchor_fit - fit) > delta:
            gold_bands.append([])
            anchor_fit = fit
        gold_bands[-1].append(row["candidate_id"])
    
    # Build test bands
    test_bands: list[list[str]] = []
    anchor_fit = None
    for row in test_ranking:
        fit = row["fit_score"]
        if anchor_fit is None or (anchor_fit - fit) > delta:
            test_bands.append([])
            anchor_fit = fit
        test_bands[-1].append(row["candidate_id"])
    
    # Check bands match
    if len(gold_bands) != len(test_bands):
        messages.append(
            f"✗ Band count mismatch: gold={len(gold_bands)}, test={len(test_bands)}"
        )
        messages.append(f"  Gold bands: {gold_bands}")
        messages.append(f"  Test bands: {test_bands}")
        return False, messages
    
    all_pass = True
    for i, (gold_band, test_band) in enumerate(zip(gold_bands, test_bands)):
        if set(gold_band) == set(test_band):
            messages.append(f"✓ Band {i+1}: {sorted(gold_band)}")
        else:
            all_pass = False
            messages.append(
                f"✗ Band {i+1} mismatch: gold={sorted(gold_band)}, test={sorted(test_band)}"
            )
    
    return all_pass, messages


def run_alignment_test(
    fixture_path: Path,
    profile_path: Path,
    *,
    test_descriptor_field: str = "descriptors_chinese_only",
    gold_descriptor_field: str = "descriptors_english_only",
    use_stub_normalize: bool = False,
    verbose: bool = False
) -> int:
    """Run alignment test comparing gold vs test scoring paths.
    
    Returns:
        0 if all gates pass, 1 otherwise
    """
    print(f"Loading fixture: {fixture_path}")
    fixture = load_fixture(fixture_path)
    
    print(f"Loading profile: {profile_path}")
    profile = load_profile(profile_path)
    
    # Validate profile matches fixture
    expected_profile_id = fixture["recommendation_snapshot"]["profile_id"]
    if profile["profile_id"] != expected_profile_id:
        print(f"✗ Profile ID mismatch: expected={expected_profile_id}, got={profile['profile_id']}")
        return 1
    
    print(f"\n{'='*80}")
    print(f"GOLD PATH: Scoring with {gold_descriptor_field}")
    print(f"{'='*80}")
    
    # Score gold path (English descriptors)
    gold_candidates = build_candidates_with_descriptors(
        fixture, gold_descriptor_field, use_stub_normalize=False
    )
    gold_result = score_candidates(gold_candidates, profile)
    gold_ranking = gold_result["ranking"]
    
    if verbose:
        print(f"\nGold ranking ({len(gold_ranking)} candidates):")
        for i, row in enumerate(gold_ranking, 1):
            print(f"  {i}. {row['candidate_id']}: Fit={row['fit_score']:.1f}, Novelty={row['novelty_score']:.1f}")
            print(f"     Families: {row['descriptor_categories']}")
    
    print(f"\n{'='*80}")
    stub_status = "WITH STUB NORMALIZE" if use_stub_normalize else "WITHOUT NORMALIZE"
    print(f"TEST PATH: Scoring with {test_descriptor_field} {stub_status}")
    print(f"{'='*80}")
    
    # Score test path (Chinese descriptors - with or without stub normalize)
    test_candidates = build_candidates_with_descriptors(
        fixture, test_descriptor_field, use_stub_normalize=use_stub_normalize
    )
    test_result = score_candidates(test_candidates, profile)
    test_ranking = test_result["ranking"]
    
    if verbose:
        print(f"\nTest ranking ({len(test_ranking)} candidates):")
        for i, row in enumerate(test_ranking, 1):
            print(f"  {i}. {row['candidate_id']}: Fit={row['fit_score']:.1f}, Novelty={row['novelty_score']:.1f}")
            print(f"     Families: {row['descriptor_categories']}")
    
    print(f"\n{'='*80}")
    print("GATE CHECKS")
    print(f"{'='*80}\n")
    
    gates_pass = True
    
    # Gate 1: Top-1 match
    print("Gate 1: Top-1 Fit Match")
    gold_top1 = extract_top1_candidate(gold_ranking)
    test_top1 = extract_top1_candidate(test_ranking)
    gate1_pass, gate1_msg = check_top1_match(gold_top1, test_top1)
    print(f"  {gate1_msg}")
    if not gate1_pass:
        gates_pass = False
    print()
    
    # Gate 2: Novelty tolerance
    print(f"Gate 2: Novelty within ±{NOVELTY_TOLERANCE}")
    gate2_pass, gate2_msgs = check_novelty_within_tolerance(
        gold_ranking, test_ranking, NOVELTY_TOLERANCE
    )
    for msg in gate2_msgs:
        print(f"  {msg}")
    if not gate2_pass:
        gates_pass = False
    print()
    
    # Gate 3: Family Jaccard
    print("Gate 3: Family sets Jaccard = 1.0")
    gate3_pass, gate3_msgs = check_family_jaccard(gold_ranking, test_ranking)
    for msg in gate3_msgs:
        print(f"  {msg}")
    if not gate3_pass:
        gates_pass = False
    print()
    
    # Gate 4: Ranking order with near-ties
    print(f"Gate 4: Ranking order (near-tie delta = {NEAR_TIE_FIT_DELTA})")
    gate4_pass, gate4_msgs = check_ranking_order_with_near_ties(
        gold_ranking, test_ranking, NEAR_TIE_FIT_DELTA
    )
    for msg in gate4_msgs:
        print(f"  {msg}")
    if not gate4_pass:
        gates_pass = False
    print()
    
    # Final verdict
    print(f"{'='*80}")
    if gates_pass:
        print("✓ ALL GATES PASSED")
        print(f"{'='*80}\n")
        return 0
    else:
        print("✗ SOME GATES FAILED")
        print(f"{'='*80}\n")
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixture",
        type=Path,
        default=Path("eval/coffee_taste/sey_candidates_2026-09-04.json"),
        help="Path to test fixture with gold scores (测试集)"
    )
    parser.add_argument(
        "--profile",
        type=Path,
        default=Path("Sources/CoffeeJournalApp/Resources/TasteProfile/profile-prior.json"),
        help="Path to taste profile"
    )
    parser.add_argument(
        "--test-descriptor-field",
        default="descriptors_chinese_only",
        help="Descriptor field for test path (default: descriptors_chinese_only)"
    )
    parser.add_argument(
        "--gold-descriptor-field",
        default="descriptors_english_only",
        help="Descriptor field for gold path (default: descriptors_english_only)"
    )
    parser.add_argument(
        "--stub-normalize",
        action="store_true",
        help="Apply stub normalize (CN→canonical map) to test path for CI testing without live Ark"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )
    args = parser.parse_args()
    
    return run_alignment_test(
        args.fixture,
        args.profile,
        test_descriptor_field=args.test_descriptor_field,
        gold_descriptor_field=args.gold_descriptor_field,
        use_stub_normalize=args.stub_normalize,
        verbose=args.verbose
    )


if __name__ == "__main__":
    sys.exit(main())
