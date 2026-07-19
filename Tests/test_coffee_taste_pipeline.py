from __future__ import annotations

import sys
import unittest
import unittest.mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from build_coffee_taste_dataset import (
    RATING_SCORES,
    build_entity_summaries,
    category_matches,
    deduplicate,
    enrich_flomo,
    parse_app,
    quality_matches,
)
from backup_flomo import build_manifest
import evaluate_coffee_taste_prompts as evaluator
from evaluate_coffee_taste_prompts import (
    NARRATIVE_LENGTH_RANGE,
    build_profile_contract,
    direct_history_match,
    ground_profile,
    ground_recommendation,
    identity_tokens,
    normalized_key,
    score_recommendation,
    shortlist_live_candidates,
    validate_model_narrative,
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

    def test_dedupe_key_collapses_flomo_duplicates(self) -> None:
        def raw_flomo(observation_id: str) -> dict:
            return {
                "id": observation_id,
                "entity_id": "flomo_yemen_test",
                "source_ref": f"ref_{observation_id}",
                "date": "2026-03-21",
                "dedupe_key": "yemen_test_alchemy",
                "coffee": {"roaster": "R", "name": "Yemen Test", "origin": "Yemen",
                           "farm": "", "variety": "", "process": ""},
                "rating": {"label": "Great"},
                "sensory": {"descriptors": ["raisin", "date"]},
            }

        observations = deduplicate([
            enrich_flomo(raw_flomo("obs_first")),
            enrich_flomo(raw_flomo("obs_second")),
        ])
        self.assertEqual(len(observations), 1)
        kept = observations[0]
        self.assertEqual(kept["id"], "obs_first")
        self.assertEqual(
            kept["provenance_refs"],
            ["flomo:ref_obs_first", "flomo:ref_obs_second"],
        )
        self.assertIn(
            "Collapsed duplicate source entry: obs_second.",
            kept["evidence"]["limitations"],
        )

    def test_entity_summary_not_double_counted_after_dedup(self) -> None:
        first = observation("dup_a", name="Yemen Test", score=4, categories=["fruit.dried"])
        second = observation("dup_b", name="Yemen Test", score=4, categories=["fruit.dried"])
        third = observation("other", name="Yemen Test", score=3, categories=["fruit.citrus"])
        for item in (first, second, third):
            item["entity_id"] = "entity_yemen_test"
        first["dedupe_key"] = "yemen_dup"
        second["dedupe_key"] = "yemen_dup"

        summaries = build_entity_summaries(deduplicate([first, second, third]))
        self.assertEqual(len(summaries), 1)
        summary = summaries[0]
        self.assertEqual(summary["rating_count"], 2)
        self.assertEqual(summary["weighted_rating"], 3.5)

    def test_parse_app_unknown_verdict_label_degrades_gracefully(self) -> None:
        store = {
            "coffees": [{
                "id": "C0FFEE00-0000-0000-0000-000000000001",
                "roaster": "Test Roaster",
                "name": "Test Coffee",
                "origin": "Test Origin",
                "flavorNotes": ["peach"],
            }],
            "brewLogs": [{
                "id": "B0000000-0000-0000-0000-000000000001",
                "coffeeID": "C0FFEE00-0000-0000-0000-000000000001",
                "verdict": "Transcendent",
                "date": "2026-07-01T00:00:00Z",
                "tastingNote": "",
            }],
        }
        observations = parse_app(store, Path("test_store.json"))
        self.assertEqual(len(observations), 1)
        rating = observations[0]["rating"]
        self.assertEqual(rating["label"], "Transcendent")
        self.assertIsNone(rating["score"])
        self.assertFalse(rating["explicit"])
        self.assertIn(
            "Unmapped verdict label: Transcendent.",
            observations[0]["evidence"]["limitations"],
        )
        summary = build_entity_summaries(observations)[0]
        self.assertEqual(summary["rating_count"], 0)
        self.assertIsNone(summary["weighted_rating"])

    def test_app_verdict_enum_fully_mapped(self) -> None:
        # The four cases of the Swift Verdict enum in Sources/CoffeeJournalCore/Models.swift.
        for label in ("Loved", "Liked", "Ok", "Disliked"):
            self.assertIn(label, RATING_SCORES)

    def test_app_dedupe_override_sets_dedupe_key(self) -> None:
        import build_coffee_taste_dataset as builder
        store = {
            "coffees": [{
                "id": "C0FFEE00-0000-0000-0000-000000000002",
                "roaster": "Test Roaster",
                "name": "Cross Source",
                "flavorNotes": [],
            }],
            "brewLogs": [{
                "id": "B0000000-0000-0000-0000-000000000002",
                "coffeeID": "C0FFEE00-0000-0000-0000-000000000002",
                "verdict": "Loved",
                "tastingNote": "",
            }],
        }
        with unittest.mock.patch.dict(
            builder.APP_DEDUPE_OVERRIDES,
            {"B0000000-0000-0000-0000-000000000002": "cross_source_key"},
        ):
            observations = parse_app(store, Path("test_store.json"))
        self.assertEqual(observations[0]["dedupe_key"], "cross_source_key")

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

    def _raw_recommendation_with_ordering_violation(self) -> tuple[list[dict], dict]:
        candidates = [
            {
                "id": "candidate_a",
                "roaster": "A",
                "origin": "Origin A",
                "process": "Washed",
                "descriptors": ["berry"],
                "descriptor_categories": ["fruit.berry"],
                "analog_evidence": {"contrast_margin": 0.3},
            },
            {
                "id": "candidate_b",
                "roaster": "B",
                "origin": "Origin B",
                "process": "Natural",
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
                    "fit_score": 70,
                    "novelty_score": 20,
                    "confidence": 0.7,
                    "short_reason": "raw",
                },
                {
                    "candidate_id": "candidate_b",
                    "fit_score": 80,
                    "novelty_score": 40,
                    "confidence": 0.6,
                    "short_reason": "raw",
                },
            ],
            "caveats": [],
        }
        return candidates, raw

    def test_ground_recommendation_records_adjustments(self) -> None:
        candidates, raw = self._raw_recommendation_with_ordering_violation()
        grounded = ground_recommendation(
            raw,
            candidates,
            {"obs_1"},
            {"different_roasters": False},
            {"preference_axes": [{"evidence_ids": ["obs_1"]}]},
        )
        self.assertEqual(grounded["safe_match"]["candidate_id"], "candidate_a")
        self.assertTrue(grounded["grounding_adjustments"]["safe_fit_raised"])

    def test_contract_score_penalizes_raw_ordering_violation(self) -> None:
        candidates, raw = self._raw_recommendation_with_ordering_violation()
        grounded = ground_recommendation(
            raw,
            candidates,
            {"obs_1"},
            {"different_roasters": False},
            {"preference_axes": [{"evidence_ids": ["obs_1"]}]},
        )
        candidate_ids = {"candidate_a", "candidate_b"}
        roasters = {"candidate_a": "A", "candidate_b": "B"}
        tautological = score_recommendation(
            grounded, candidate_ids, roasters, {"obs_1"}, None, {},
        )
        honest = score_recommendation(
            grounded, candidate_ids, roasters, {"obs_1"}, None, {},
            ordering_source=raw,
        )
        self.assertTrue(tautological["safe_highest_fit"])
        self.assertFalse(honest["safe_highest_fit"])
        self.assertLess(honest["score"], tautological["score"])

    def test_shortlist_novelty_pool_uses_frontier_fit_gate(self) -> None:
        priors = {
            **{f"filler_{index}": (90 - index, 10) for index in range(6)},
            "gate_blocked": (57, 99),
            "gate_passed": (61, 98),
        }

        def fake_prior(candidate, evidence_packet, observations):
            fit, novelty = priors[candidate["id"]]
            return {
                **candidate,
                "deterministic_prior": {
                    "fit_score": float(fit),
                    "novelty_score": float(novelty),
                },
            }

        candidates = [
            {"id": candidate_id, "availability": "in_stock"}
            for candidate_id in priors
        ]
        with unittest.mock.patch.object(evaluator, "candidate_prior", fake_prior):
            shortlisted = shortlist_live_candidates(candidates, {}, [])
        shortlisted_ids = {item["id"] for item in shortlisted}
        self.assertIn("gate_passed", shortlisted_ids)
        self.assertNotIn("gate_blocked", shortlisted_ids)

    def test_normalized_key_applies_nfkc(self) -> None:
        self.assertEqual(normalized_key("ＥＴＨＩＯＰＩＡ"), "ethiopia")

    def test_identity_tokens_match_short_cjk_names(self) -> None:
        self.assertEqual(identity_tokens("莓果乐园"), {"莓果乐园"})
        self.assertEqual(identity_tokens("莓果 水洗"), {"莓果"})
        self.assertEqual(identity_tokens("sey"), set())

    def test_fallback_narrative_satisfies_length_spec(self) -> None:
        minimal = build_profile_contract([
            observation("plain", name="Plain", score=3, categories=["fruit.citrus"]),
        ])
        rich_observations = [
            observation(
                "rich",
                name="Rich",
                score=4,
                categories=["fruit.stone"],
                quality_signals=[
                    "clarity_positive",
                    "acid_sweet_balance_positive",
                    "cleanliness_positive",
                    "fermentation_clean_positive",
                ],
                substantive=True,
            ),
        ]
        rich_observations[0]["user_note"] = "降温后风味更清楚，冷下来更好喝。"
        rich = build_profile_contract(rich_observations)
        for contract in (minimal, rich):
            narrative = contract["fallback_summary"]["narrative"]
            self.assertGreaterEqual(len(narrative), NARRATIVE_LENGTH_RANGE[0])
            self.assertLessEqual(len(narrative), NARRATIVE_LENGTH_RANGE[1])

    VALID_NARRATIVE = (
        "你追求的是一杯主线清楚的咖啡：入口时风味自己亮起来，酸和甜互相托住而不打架。"
        "你不排斥实验性的处理方式，但要求它服务于干净的表达。"
        "至于口感与余韵的具体偏好，证据不足，还需要更多实饮记录来回答。"
    )
    NARRATIVE_ASSERTIONS = {
        "forbidden_absolute_phrases": ["只喜欢水洗", "不喜欢所有厌氧"],
        "known_preference_forbidden_terms": ["水洗", "Gesha", "瑰夏", "Panama"],
    }

    def _profile_contract(self) -> dict:
        return build_profile_contract([
            observation(
                "base",
                name="Base",
                score=3,
                categories=["fruit.citrus"],
                quality_signals=["acid_sweet_balance_positive"],
                substantive=True,
            ),
        ])

    def test_ground_profile_v2_keeps_valid_model_narrative(self) -> None:
        contract = self._profile_contract()
        profile = {
            "summary": {
                "headline": "追着清楚主线走的杯子",
                "narrative": self.VALID_NARRATIVE,
                "confidence": 0.9,
                "confidence_reasons": ["模型自述"],
            },
        }
        grounded = ground_profile(
            profile,
            contract,
            keep_model_summary=True,
            assertions=self.NARRATIVE_ASSERTIONS,
        )
        self.assertEqual(grounded["summary_source"], "model")
        self.assertEqual(grounded["narrative_violations"], [])
        self.assertEqual(grounded["summary"]["narrative"], self.VALID_NARRATIVE)
        fallback_confidence = contract["fallback_summary"]["confidence"]
        self.assertEqual(grounded["summary"]["confidence"], fallback_confidence)

    def test_narrative_validator_rejects_unhedged_unknown_dimension(self) -> None:
        summary = {
            "headline": "标题",
            "narrative": (
                "你喜欢中浅烘焙带来的轻盈口感和绵长余韵，苦味也控制得当，"
                "整体表达清楚、酸甜协调，是一杯让人放松的咖啡，每次冲煮都值得认真对待，"
                "无论清晨还是午后都能带来足够的愉悦感受。"
            ),
        }
        violations = validate_model_narrative(
            summary,
            self._profile_contract(),
            self.NARRATIVE_ASSERTIONS,
        )
        self.assertIn("unhedged_undersampled_dimension", violations)

    def test_narrative_validator_rejects_invented_family(self) -> None:
        summary = {
            "headline": "标题",
            "narrative": (
                "你最偏爱的是草莓和蓝莓那样明亮的莓果风味，一入口就能认出来，"
                "这种熟悉的甜香贯穿始终，让每一杯都像是一次小小的果园漫步，"
                "值得反复回味，也值得为它认真挑选下一支豆子来延续。"
            ),
        }
        contract = self._profile_contract()
        self.assertEqual(contract["likely_sensory_families"], [])
        violations = validate_model_narrative(
            summary,
            contract,
            self.NARRATIVE_ASSERTIONS,
        )
        self.assertIn("invented_flavor_family", violations)

    def test_ground_profile_v2_falls_back_and_records_violations(self) -> None:
        contract = self._profile_contract()
        profile = {
            "summary": {
                "headline": "",
                "narrative": "太短。",
                "confidence": 0.9,
            },
        }
        grounded = ground_profile(
            profile,
            contract,
            keep_model_summary=True,
            assertions=self.NARRATIVE_ASSERTIONS,
        )
        self.assertEqual(grounded["summary_source"], "fallback")
        self.assertIn("narrative_length_out_of_range", grounded["narrative_violations"])
        self.assertIn("headline_missing_or_too_long", grounded["narrative_violations"])
        self.assertEqual(grounded["summary"], contract["fallback_summary"])

    def _tiered_observations(self) -> list[dict]:
        return [
            observation("great_a", name="Great A", score=4, categories=["fruit.dried", "fruit.tropical"]),
            observation("great_b", name="Great B", score=4, categories=["fruit.dried", "fruit.berry"]),
            observation("great_c", name="Great C", score=4, categories=["fruit.berry"]),
            observation("good_a", name="Good A", score=3, categories=["fruit.citrus"]),
            observation("ok_a", name="Ok A", score=2, categories=["fruit.pome"]),
        ]

    def test_top_tier_signal_requires_multiple_great_observations(self) -> None:
        contract = build_profile_contract(self._tiered_observations())
        signal_categories = {
            signal["category"] for signal in contract["top_tier_signals"]
        }
        self.assertEqual(signal_categories, {"fruit.dried", "fruit.berry"})
        dried = next(
            signal for signal in contract["top_tier_signals"]
            if signal["category"] == "fruit.dried"
        )
        self.assertEqual(dried["top_tier_count"], 2)
        self.assertEqual(dried["top_tier_total"], 3)
        self.assertEqual(dried["evidence_ids"], ["great_a", "great_b"])
        self.assertIn(dried["statement"], contract["likely_preferences_allowed"])
        # fruit.tropical appears in only one Great observation: no signal.
        self.assertNotIn("fruit.tropical", signal_categories)

    def test_narrative_may_mention_top_tier_family(self) -> None:
        contract = build_profile_contract(self._tiered_observations())
        summary = {
            "headline": "被果干浓缩感抓住的杯子",
            "narrative": (
                "最打动你的杯子有一条共同的线：果干与莓果式的浓缩风味，"
                "像蓝莓与晒干的浆果被时间收拢成的一小口精华，评分最高的几支都指向它。"
                "这主要来自评分集中度而非文字确认，口感与余韵的具体偏好证据不足，"
                "还需要更多实饮记录。"
            ),
            "confidence": 0.5,
        }
        violations = validate_model_narrative(
            summary,
            contract,
            self.NARRATIVE_ASSERTIONS,
        )
        self.assertEqual(violations, [])

    def test_candidate_prior_top_tier_bonus_capped(self) -> None:
        observations = self._tiered_observations()
        packet = evaluator.build_evidence_packet(observations)
        single = evaluator.candidate_prior(
            {"id": "single", "descriptors": ["raisin"], "origin": "", "process": ""},
            packet,
            observations,
        )["deterministic_prior"]
        double = evaluator.candidate_prior(
            {"id": "double", "descriptors": ["raisin", "blueberry"], "origin": "", "process": ""},
            packet,
            observations,
        )["deterministic_prior"]
        none = evaluator.candidate_prior(
            {"id": "none", "descriptors": ["green apple"], "origin": "", "process": ""},
            packet,
            observations,
        )["deterministic_prior"]
        self.assertEqual(single["top_tier_affinity_bonus"], 2.5)
        self.assertEqual(double["top_tier_affinity_bonus"], 5.0)
        self.assertEqual(none["top_tier_affinity_bonus"], 0.0)

    def test_candidate_prior_roaster_bonus_only_with_history(self) -> None:
        observations = self._tiered_observations()
        for item in observations:
            item["coffee"]["roaster"] = "Loved Roaster" if item["rating"]["score"] == 4 else "Meh Roaster"
        packet = evaluator.build_evidence_packet(observations)

        def prior(roaster: str) -> dict:
            return evaluator.candidate_prior(
                {"id": "cand", "roaster": roaster, "descriptors": ["peach"], "origin": "", "process": ""},
                packet,
                observations,
            )["deterministic_prior"]

        self.assertEqual(prior("Unknown Roaster")["roaster_affinity_bonus"], 0.0)
        self.assertGreater(prior("Loved Roaster")["roaster_affinity_bonus"], 0.0)
        self.assertLessEqual(prior("Loved Roaster")["roaster_affinity_bonus"], 3.0)
        self.assertLess(prior("Meh Roaster")["roaster_affinity_bonus"], 3.0)

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
