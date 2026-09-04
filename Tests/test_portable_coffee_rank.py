from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from build_coffee_taste_dataset import RATING_LABELS
import evaluate_coffee_taste_prompts as evaluator
from portable_coffee_rank import (
    build_portable_profile,
    score_candidate,
    validate_profile,
)


def observation(
    observation_id: str,
    *,
    name: str,
    roaster: str,
    origin: str,
    process: str,
    score: int,
    categories: list[str],
) -> dict:
    return {
        "id": observation_id,
        "entity_id": f"entity_{observation_id}",
        "source": "test",
        "source_ref": f"private:{observation_id}",
        "date": "2026-01-01",
        "coffee": {
            "roaster": roaster,
            "name": name,
            "origin": origin,
            "farm": "Private Farm",
            "variety": "Private Variety",
            "process": process,
        },
        "rating": {
            "label": RATING_LABELS[score],
            "score": score,
            "explicit": True,
        },
        "sensory": {
            "descriptors": [],
            "descriptor_origin": "test",
            "descriptor_categories": categories,
            "quality_signals": [],
            "claimed_quality_signals": [],
        },
        "user_note": "private first-person note",
        "context": {"brew_method": "private method"},
        "evidence": {
            "rating_weight": 1.0,
            "descriptor_weight": 1.0,
            "substantive_first_person_note": True,
            "limitations": [],
        },
        "provenance_refs": [f"private:{observation_id}"],
    }


class PortableCoffeeRankTests(unittest.TestCase):
    def setUp(self) -> None:
        self.observations = [
            observation(
                "secret_citrus",
                name="Secret Citrus Coffee",
                roaster="Known Roaster",
                origin="Ethiopia",
                process="Washed",
                score=3,
                categories=["fruit.citrus"],
            ),
            observation(
                "secret_berry",
                name="Secret Berry Coffee",
                roaster="Known Roaster",
                origin="Ethiopia",
                process="Natural",
                score=2,
                categories=["fruit.berry"],
            ),
            observation(
                "secret_lower",
                name="Secret Lower Coffee",
                roaster="Other Roaster",
                origin="Colombia",
                process="Washed",
                score=1,
                categories=["floral"],
            ),
        ]
        self.profile = build_portable_profile(
            self.observations,
            dataset_generated_at="2026-07-25T00:00:00+00:00",
            scorer_version="test-scorer",
        )

    def test_export_contains_sufficient_statistics_but_no_raw_rows(self) -> None:
        serialized = json.dumps(self.profile, ensure_ascii=False)
        forbidden_keys = {
            "observations",
            "coffee",
            "source_ref",
            "date",
            "user_note",
            "context",
            "evidence",
            "provenance_refs",
        }

        def keys(value: object) -> set[str]:
            if isinstance(value, dict):
                return set(value).union(*(keys(item) for item in value.values()))
            if isinstance(value, list):
                return set().union(*(keys(item) for item in value))
            return set()

        self.assertEqual(self.profile["mode"], "portable_profile")
        self.assertIn("category_stats", self.profile["statistics"])
        self.assertIn("origin_stats", self.profile["statistics"])
        self.assertIn("process_stats", self.profile["statistics"])
        self.assertIn("roaster_stats", self.profile["statistics"])
        self.assertNotIn("observations", self.profile)
        self.assertNotIn("secret_citrus", serialized)
        self.assertNotIn("Secret Citrus Coffee", serialized)
        self.assertNotIn("private first-person note", serialized)
        self.assertNotIn("private method", serialized)
        self.assertNotIn("2026-01-01", serialized)
        self.assertEqual(forbidden_keys.intersection(keys(self.profile)), set())

    def test_portable_profile_fit_matches_private_profile_component(self) -> None:
        candidate = {
            "id": "candidate_new",
            "roaster": "Known Roaster",
            "name": "Unseen Coffee",
            "origin": "Ethiopia",
            "farm": "Unseen Farm",
            "variety": "74158",
            "process": "Washed",
            "descriptors": ["orange", "strawberry"],
        }
        private = evaluator.candidate_prior(
            candidate,
            evaluator.build_evidence_packet(self.observations),
            self.observations,
        )["deterministic_prior"]
        portable = score_candidate(candidate, self.profile)

        self.assertEqual(portable["score_mode"], "portable_profile")
        self.assertEqual(portable["profile_fit_score"], private["profile_fit_score"])
        self.assertEqual(
            portable["profile_novelty_score"],
            private["profile_novelty_score"],
        )
        self.assertIsNone(portable["history_adjustment"])
        self.assertIsNone(portable["personalized_fit_score"])

    def test_private_history_changes_personalized_not_profile_fit(self) -> None:
        candidate = {
            "id": "candidate_known",
            "roaster": "Known Roaster",
            "name": "Secret Citrus Coffee",
            "origin": "Ethiopia",
            "farm": "Private Farm",
            "variety": "Private Variety",
            "process": "Washed",
            "descriptors": ["orange"],
        }
        private = evaluator.candidate_prior(
            candidate,
            evaluator.build_evidence_packet(self.observations),
            self.observations,
        )["deterministic_prior"]
        portable = score_candidate(candidate, self.profile)

        self.assertEqual(portable["profile_fit_score"], private["profile_fit_score"])
        self.assertGreater(private["fit_score"], portable["profile_fit_score"])
        self.assertIsNone(portable["history_adjustment"])

    def test_exported_skill_is_self_contained_and_scorer_bound(self) -> None:
        exporter_path = (
            ROOT / ".claude" / "skills" / "coffee-taste" / "scripts"
            / "export_portable_skill.py"
        )
        spec = importlib.util.spec_from_file_location(
            "export_portable_skill",
            exporter_path,
        )
        assert spec and spec.loader
        exporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exporter)

        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "gos-coffee-taste"
            result = exporter.export_skill(
                {
                    "generated_at": "2026-07-25T00:00:00+00:00",
                    "observations": self.observations,
                },
                out,
            )
            expected = {
                "SKILL.md",
                "profile-snapshot.md",
                "profile-prior.json",
                "references/scoring-method.md",
                "references/prestige-regions-estates.md",
                "scripts/rank_candidates.py",
            }
            self.assertEqual(set(result["files"]), expected)
            exported = json.loads((out / "profile-prior.json").read_text())
            self.assertEqual(exported["scorer_version"], result["scorer_version"])
            copied_hash = hashlib.sha256(
                (out / "scripts" / "rank_candidates.py").read_bytes()
            ).hexdigest()
            self.assertEqual(exported["scorer_version"], copied_hash)
            self.assertFalse(exported["privacy"]["contains_raw_observations"])
            self.assertFalse(exported["privacy"]["history_adjustment_available"])

    def test_profile_digest_rejects_tampering(self) -> None:
        validate_profile(self.profile)
        tampered = json.loads(json.dumps(self.profile))
        tampered["scoring"]["fit_weights"]["sensory"] = 0.5
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            validate_profile(tampered)


if __name__ == "__main__":
    unittest.main()
