from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from consult_sol_max import (
    MODEL,
    REQUIRED_HEADINGS,
    REASONING_EFFORT,
    build_codex_command,
    build_review_prompt,
    load_review_inputs,
    parse_review_verdict,
)


class SolMaxConsultationTests(unittest.TestCase):
    def test_prompt_requires_independent_prompt_judge_and_taste_review(self) -> None:
        prompt = build_review_prompt(
            topic="prompt-and-judge-design",
            question="Should v1 become the baseline?",
            scope="adopt v1 as the internal regression baseline",
            acceptance_criteria="Approve only if leakage and circularity are bounded.",
            inputs=[(Path("prompts/test.md"), "Use evidence.")],
        )
        self.assertIn("generator-judge circularity", prompt)
        self.assertIn("seller claims", prompt)
        self.assertIn("## Ship Gate", prompt)
        self.assertIn("SOURCE: prompts/test.md", prompt)
        self.assertIn("Precommitted acceptance criteria", prompt)

    def test_command_uses_sol_max_read_only_ephemeral_session(self) -> None:
        command = build_codex_command(
            codex_bin=Path("/tmp/codex"),
            root=ROOT,
            output_path=ROOT / ".generated/review.md",
        )
        self.assertIn(MODEL, command)
        self.assertIn(f'model_reasoning_effort="{REASONING_EFFORT}"', command)
        self.assertIn("read-only", command)
        self.assertIn("--ephemeral", command)
        self.assertEqual(command[-1], "-")

    def test_private_inputs_require_explicit_override(self) -> None:
        with self.assertRaisesRegex(ValueError, "--allow-private"):
            load_review_inputs(
                [Path("private/coffee_taste/dataset.json")],
                root=ROOT,
                allow_private=False,
            )

    def test_tracked_input_is_loaded(self) -> None:
        loaded = load_review_inputs(
            [Path("prompts/coffee_profile_v1.md")],
            root=ROOT,
            allow_private=False,
        )
        self.assertEqual(loaded[0][0], Path("prompts/coffee_profile_v1.md"))
        self.assertIn("evidence-grounded", loaded[0][1])

    def test_all_generated_inputs_require_explicit_private_override(self) -> None:
        with self.assertRaisesRegex(ValueError, "generated artifact"):
            load_review_inputs(
                [
                    Path(
                        ".generated/coffee_taste_eval/20260717-010156/"
                        "v1/profile.raw.json"
                    )
                ],
                root=ROOT,
                allow_private=False,
            )

    def test_verdict_parser_requires_structured_ship_gate(self) -> None:
        sections = [
            f"## {heading}\nContent"
            for heading in (
                "Decision",
                "Evidence",
                "Strongest Objections",
                "Prompt Risks",
                "Judge Risks",
                "Taste And Design Risks",
                "Recommended Experiments",
                "Disagreements And Unknowns",
            )
        ]
        review = "\n\n".join(
            sections
            + [
                "## Ship Gate\n"
                "VERDICT: APPROVE WITH CONDITIONS\n"
                "CONDITIONS:\n"
                "- Add a sealed evaluation set\n"
            ]
        )
        verdict, conditions = parse_review_verdict(review)
        self.assertEqual(verdict, "approve_with_conditions")
        self.assertEqual(conditions, ["Add a sealed evaluation set"])

    def test_verdict_parser_rejects_conflicting_verdicts(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: APPROVE",
                "VERDICT: DO NOT APPROVE",
                "CONDITIONS:",
                "- None",
            ]
        )
        with self.assertRaisesRegex(ValueError, "line-bounded CONDITIONS"):
            parse_review_verdict(review)

    def test_verdict_parser_rejects_trailing_non_bullet_text(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: APPROVE",
                "CONDITIONS:",
                "- None",
                "Additional blocking caveat.",
            ]
        )
        with self.assertRaisesRegex(ValueError, "Every line after CONDITIONS"):
            parse_review_verdict(review)

    def test_verdict_parser_rejects_content_between_verdict_and_conditions(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: APPROVE",
                "Ignored text",
                "CONDITIONS:",
                "- None",
            ]
        )
        with self.assertRaisesRegex(ValueError, "line-bounded CONDITIONS"):
            parse_review_verdict(review)

    def test_verdict_parser_allows_one_blank_line_after_heading(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "",
                "VERDICT: APPROVE",
                "CONDITIONS:",
                "- None",
            ]
        )
        verdict, conditions = parse_review_verdict(review)
        self.assertEqual(verdict, "approve")
        self.assertEqual(conditions, ["None"])

    def test_blocked_verdict_rejects_mixed_none_condition(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: DO NOT APPROVE",
                "CONDITIONS:",
                "- None",
                "- Add a regression test",
            ]
        )
        with self.assertRaisesRegex(ValueError, "concrete conditions"):
            parse_review_verdict(review)

    def test_blocked_verdict_rejects_none_token_inside_condition(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: DO NOT APPROVE",
                "CONDITIONS:",
                "- None is not a concrete condition",
            ]
        )
        with self.assertRaisesRegex(ValueError, "without None"):
            parse_review_verdict(review)

    def test_verdict_parser_rejects_trailing_blank_line(self) -> None:
        review = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
            + [
                "## Ship Gate",
                "VERDICT: APPROVE",
                "CONDITIONS:",
                "- None",
                "",
                "",
            ]
        )
        with self.assertRaisesRegex(ValueError, "trailing blank line"):
            parse_review_verdict(review)

    def test_verdict_parser_rejects_malformed_gate_table(self) -> None:
        prefix = "\n".join(
            [f"## {heading}\nContent" for heading in REQUIRED_HEADINGS[:-1]]
        )
        invalid_gates = {
            "two heading blanks": (
                "## Ship Gate\n\n\nVERDICT: APPROVE\nCONDITIONS:\n- None"
            ),
            "duplicate verdict": (
                "## Ship Gate\nVERDICT: APPROVE\nVERDICT: APPROVE\n"
                "CONDITIONS:\n- None"
            ),
            "duplicate conditions": (
                "## Ship Gate\nVERDICT: APPROVE\nCONDITIONS:\n"
                "CONDITIONS:\n- None"
            ),
            "extra heading": (
                "## Ship Gate\nVERDICT: APPROVE\nCONDITIONS:\n"
                "- None\n## Extra"
            ),
            "invalid approval condition": (
                "## Ship Gate\nVERDICT: APPROVE\nCONDITIONS:\n- Looks good"
            ),
            "blank between bullets": (
                "## Ship Gate\nVERDICT: DO NOT APPROVE\nCONDITIONS:\n"
                "- Fix one\n\n- Fix two"
            ),
        }
        for label, gate in invalid_gates.items():
            with self.subTest(label=label):
                with self.assertRaises(ValueError):
                    parse_review_verdict(f"{prefix}\n{gate}")


if __name__ == "__main__":
    unittest.main()
