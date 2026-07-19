from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from build_coffee_taste_dataset import category_matches, quality_matches
from backup_flomo import build_manifest
from evaluate_coffee_taste_prompts import (
    build_profile_contract,
    direct_history_match,
    ground_recommendation,
    shortlist_live_candidates,
)


def observation(
    observation_id: str,
    *,
    name: str,
    score: int,
    categories: list[str],
    quality_signals: list[str] | None = None,
    substantive: bool = False,
) -> dict:
    return {
        "id": observation_id,
        "entity_id": f"entity_{observation_id}",
        "source": "test",
        "date": "2026-01-01",
        "coffee": {
            "roaster": "Test",
            "name": name,
            "origin": "Test Origin",
            "farm": "",
            "variety": "Test Variety",
            "process": "Washed",
        },
        "rating": {
            "label": "Liked" if score >= 3 else "Ok",
            "score": score,
            "explicit": True,
        },
        "sensory": {
            "descriptors": [],
            "descriptor_origin": "test",
            "descriptor_categories": categories,
            "quality_signals": quality_signals or [],
            "claimed_quality_signals": [],
        },
        "user_note": "test note" if substantive else "",
        "context": {},
        "evidence": {
            "rating_weight": 1.0,
            "descriptor_weight": 1.0,
            "substantive_first_person_note": substantive,
            "limitations": [],
        },
        "provenance_refs": [f"test:{observation_id}"],
    }


class CoffeeTastePipelineTests(unittest.TestCase):
    def test_flomo_manifest_records_completeness_without_credentials(self) -> None:
        memos = [
            {
                "slug": "memo-1",
                "created_at": "2026-01-01 00:00:00",
                "updated_at": "2026-01-02 00:00:00",
                "deleted_at": None,
                "content": "test",
                "files": [],
            },
            {
                "slug": "memo-2",
                "created_at": "2026-01-03 00:00:00",
                "updated_at": "2026-01-04 00:00:00",
                "deleted_at": None,
                "content": "test",
                "files": [],
            },
        ]
        media = [
            {
                "downloads": {
                    "original": {"bytes": 10},
                    "thumbnail": {"bytes": 3},
                }
            }
        ]
        manifest = build_manifest(
            memos,
            page_count=1,
            media_records=media,
            created_at="2026-01-05T00:00:00+08:00",
        )
        self.assertEqual(manifest["memos"]["count"], 2)
        self.assertEqual(manifest["memos"]["unique_slug_count"], 2)
        self.assertEqual(manifest["media"]["original_download_count"], 1)
        self.assertFalse(manifest["source"]["authorization_persisted"])
        self.assertNotIn("authorization", manifest["source"])

    def test_english_terms_use_word_boundaries(self) -> None:
        descriptors = [
            "pineapple",
            "marzipan",
            "creamy texture",
            "clarity",
            "sweetness",
            "balanced acidity",
        ]
        self.assertEqual(
            category_matches(descriptors),
            ["cocoa_nut", "fruit.tropical"],
        )
        self.assertNotIn("fruit.pome", category_matches(descriptors))
        self.assertNotIn("sweet.browning", category_matches(descriptors))
        self.assertEqual(
            category_matches(["green apple", "golden raisin", "rock melon"]),
            ["fruit.dried", "fruit.melon", "fruit.pome"],
        )
        self.assertIn("acid_sweet_balance_positive", quality_matches(descriptors))

    def test_profile_contract_limits_known_preferences_to_direct_notes(self) -> None:
        observations = [
            observation(
                "clear_acid",
                name="Coffee A",
                score=3,
                categories=["fruit.citrus"],
                quality_signals=[
                    "clarity_positive",
                    "acid_sweet_balance_positive",
                ],
                substantive=True,
            ),
            observation(
                "clear_clean",
                name="Coffee B",
                score=4,
                categories=["fruit.stone"],
                quality_signals=[
                    "clarity_positive",
                    "cleanliness_positive",
                    "fermentation_clean_positive",
                ],
                substantive=True,
            ),
            observation(
                "lower",
                name="Coffee C",
                score=2,
                categories=["fruit.berry"],
            ),
        ]
        contract = build_profile_contract(observations)
        statements = {
            item["statement"]
            for item in contract["known_preferences_allowed"]
        }
        self.assertEqual(len(statements), 3)
        self.assertTrue(all("Washed" not in item for item in statements))
        self.assertEqual(
            contract["required_structure"]["mouthfeel"],
            "证据不足",
        )
        self.assertIn("偏好的烘焙度", contract["required_unknowns"])

    def test_identity_matching_does_not_use_substrings(self) -> None:
        history = [
            observation(
                "salto",
                name="El Salto Dona Eira",
                score=3,
                categories=["fruit.citrus"],
            ),
            observation(
                "heza",
                name="Heza Gishubi",
                score=3,
                categories=["fruit.berry"],
            ),
        ]
        false_match = direct_history_match(
            {"name": "Alto Naranjal", "farm": ""},
            history,
        )
        true_match = direct_history_match(
            {"name": "Heza", "farm": ""},
            history,
        )
        self.assertEqual(false_match["rated_observations"], 0)
        self.assertEqual(true_match["rated_observations"], 1)
        self.assertEqual(true_match["matched_tokens"], ["heza"])

    def test_live_shortlist_excludes_unavailable_candidates(self) -> None:
        candidates = [
            {
                "id": "available",
                "roaster": "A",
                "name": "Available",
                "origin": "Origin A",
                "process": "Washed",
                "descriptors": ["peach"],
                "availability": "in_stock_verified_2026-07-17",
            },
            {
                "id": "sold_out",
                "roaster": "B",
                "name": "Sold Out",
                "origin": "Origin B",
                "process": "Natural",
                "descriptors": ["berry"],
                "availability": "sold_out_verified_2026-07-17",
            },
        ]
        evidence_packet = {
            "category_stats": [],
            "origin_stats": [],
            "process_stats": [],
        }
        shortlisted = shortlist_live_candidates(
            candidates,
            evidence_packet,
            [],
        )
        self.assertEqual(
            [candidate["id"] for candidate in shortlisted],
            ["available"],
        )

    def test_negative_analog_margin_cannot_remain_safe(self) -> None:
        candidates = [
            {
                "id": "candidate_a",
                "roaster": "A",
                "origin": "Origin A",
                "process": "Unknown",
                "descriptors": ["berry"],
                "descriptor_categories": ["fruit.berry"],
                "analog_evidence": {"contrast_margin": -0.1},
            },
            {
                "id": "candidate_b",
                "roaster": "B",
                "origin": "Origin B",
                "process": "Washed",
                "descriptors": ["peach"],
                "descriptor_categories": ["fruit.stone"],
                "analog_evidence": {"contrast_margin": 0.2},
            },
        ]
        raw = {
            "safe_match": {
                "candidate_id": "candidate_a",
                "expected_liking": 80,
                "confidence": 0.7,
                "reasons": ["raw"],
                "evidence_ids": ["obs_1"],
                "risks": [],
                "brew_watchpoints": [],
            },
            "frontier_pick": {
                "candidate_id": "candidate_b",
                "expected_liking": 70,
                "confidence": 0.6,
                "reasons": ["raw"],
                "evidence_ids": ["obs_1"],
                "risks": [],
                "brew_watchpoints": [],
                "novelty_dimensions": ["test"],
                "bridge_to_profile": ["test"],
            },
            "ranking": [
                {
                    "candidate_id": "candidate_a",
                    "fit_score": 80,
                    "novelty_score": 20,
                    "confidence": 0.7,
                    "short_reason": "raw",
                },
                {
                    "candidate_id": "candidate_b",
                    "fit_score": 70,
                    "novelty_score": 40,
                    "confidence": 0.6,
                    "short_reason": "raw",
                },
            ],
            "caveats": [],
        }
        profile = {
            "preference_axes": [
                {"evidence_ids": ["obs_1"]},
            ],
        }
        grounded = ground_recommendation(
            raw,
            candidates,
            {"obs_1"},
            {"different_roasters": False},
            profile,
        )
        self.assertEqual(
            grounded["safe_match"]["candidate_id"],
            "candidate_b",
        )
        self.assertIn(
            "混合排序器否决了原始安全款",
            grounded["caveats"][-1],
        )


if __name__ == "__main__":
    unittest.main()
