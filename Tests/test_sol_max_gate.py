from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from consult_sol_max import (
    MODEL,
    REASONING_EFFORT,
    REVIEW_PROTOCOL_VERSION,
    input_manifest,
    load_review_inputs,
    protocol_manifest,
)
from verify_sol_max_gate import validate_gate


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SolMaxGateTests(unittest.TestCase):
    def test_gate_validation_detects_preregistration_mutation(self) -> None:
        generated = ROOT / ".generated"
        generated.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=generated) as directory:
            temp = Path(directory)
            inputs = load_review_inputs(
                [Path("AGENTS.md")],
                root=ROOT,
                allow_private=False,
            )
            preregistration = temp / "review.json"
            scope = "adopt internal regression baseline"
            implementation = protocol_manifest(ROOT)
            preregistration.write_text(
                json.dumps(
                    {
                        "review_protocol": REVIEW_PROTOCOL_VERSION,
                        "created_at": "2026-07-17T02:00:00+08:00",
                        "topic": "test",
                        "question": "Is the gate valid?",
                        "scope": scope,
                        "acceptance_criteria": "Approve only if evidence matches.",
                        "allow_private": False,
                        "inputs": input_manifest(inputs),
                        "protocol_manifest": implementation,
                    }
                ),
                encoding="utf-8",
            )
            preregistration_hash = sha256_file(preregistration)
            review = "\n\n".join(
                [
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
                + [
                    "## Ship Gate\n"
                    "VERDICT: APPROVE\n"
                    "CONDITIONS:\n"
                    "- None"
                ]
            )
            report = temp / "review.md"
            report.write_text(
                "# Sol Max Review\n\n"
                f"- Model: `{MODEL}`\n"
                f"- Reasoning effort: `{REASONING_EFFORT}`\n"
                f"- Review protocol: `{REVIEW_PROTOCOL_VERSION}`\n"
                f"- Preregistration: `{preregistration}`\n"
                f"- Preregistration SHA-256: `{preregistration_hash}`\n"
                f"- Scope: {scope}\n\n"
                "## Input Manifest\n\n"
                "```json\n"
                f"{json.dumps(input_manifest(inputs), indent=2)}\n"
                "```\n\n"
                f"{review}\n",
                encoding="utf-8",
            )
            gate_path = temp / "review.gate.json"
            gate = {
                "status": "approved",
                "verdict": "approve",
                "conditions": ["None"],
                "report": str(report),
                "report_sha256": sha256_file(report),
                "preregistration": str(preregistration),
                "preregistration_sha256": preregistration_hash,
                "review_protocol": REVIEW_PROTOCOL_VERSION,
                "scope": scope,
                "protocol_manifest": implementation,
                "model": MODEL,
                "reasoning_effort": REASONING_EFFORT,
            }
            gate_path.write_text(json.dumps(gate), encoding="utf-8")
            validate_gate(
                gate,
                gate_path=gate_path,
                requested_scope=scope,
            )

            with self.assertRaisesRegex(ValueError, "reviewed scope"):
                validate_gate(
                    gate,
                    gate_path=gate_path,
                    requested_scope="ship unrelated production feature",
                )

            mismatched_gate = {
                **gate,
                "status": "blocked",
                "verdict": "do_not_approve",
                "conditions": ["Fix the gate"],
            }
            with self.assertRaisesRegex(ValueError, "does not match the report"):
                validate_gate(
                    mismatched_gate,
                    gate_path=gate_path,
                    requested_scope=scope,
                )

            preregistration.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash changed"):
                validate_gate(
                    gate,
                    gate_path=gate_path,
                    requested_scope=scope,
                )


if __name__ == "__main__":
    unittest.main()
