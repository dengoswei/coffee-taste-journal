#!/usr/bin/env python3
"""Verify an approved Sol Max gate for its exact preregistered scope."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from consult_sol_max import (
    MODEL,
    REASONING_EFFORT,
    REVIEW_PROTOCOL_VERSION,
    input_manifest,
    load_preregistration,
    load_review_inputs,
    parse_review_verdict,
    protocol_manifest,
    repository_root,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify a Sol Max gate result.")
    parser.add_argument("gate", type=Path, help="Path to a .gate.json artifact.")
    parser.add_argument(
        "--scope",
        required=True,
        help="Exact downstream action or claim being authorized.",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_gate(
    gate: dict,
    *,
    gate_path: Path,
    requested_scope: str,
) -> tuple[Path, str, list[str]]:
    required = {
        "status",
        "verdict",
        "conditions",
        "report",
        "report_sha256",
        "preregistration",
        "preregistration_sha256",
        "review_protocol",
        "scope",
        "protocol_manifest",
        "model",
        "reasoning_effort",
    }
    if set(gate) != required:
        raise ValueError("Gate schema is incomplete or contains unknown fields.")
    if gate["review_protocol"] != REVIEW_PROTOCOL_VERSION:
        raise ValueError("Gate protocol does not match the verifier.")
    if gate["model"] != MODEL or gate["reasoning_effort"] != REASONING_EFFORT:
        raise ValueError("Gate model configuration is invalid.")
    if gate["scope"] != requested_scope:
        raise ValueError("Requested scope does not match the reviewed scope.")

    root = repository_root()
    current_protocol = protocol_manifest(root)
    if gate["protocol_manifest"] != current_protocol:
        raise ValueError("Gate protocol implementation is stale or changed.")

    report = Path(gate["report"])
    preregistration = Path(gate["preregistration"])
    if not report.is_file() or sha256_file(report) != gate["report_sha256"]:
        raise ValueError("Gate report is missing or its hash changed.")
    if (
        not preregistration.is_file()
        or sha256_file(preregistration) != gate["preregistration_sha256"]
    ):
        raise ValueError("Preregistration is missing or its hash changed.")

    preregistration_path, prereg = load_preregistration(
        preregistration,
        root=root,
    )
    if prereg["scope"] != requested_scope:
        raise ValueError("Preregistration scope does not match the requested scope.")
    if prereg["protocol_manifest"] != current_protocol:
        raise ValueError("Preregistration protocol implementation changed.")
    inputs = load_review_inputs(
        [Path(item["path"]) for item in prereg["inputs"]],
        root=root,
        allow_private=prereg["allow_private"],
    )
    if input_manifest(inputs) != prereg["inputs"]:
        raise ValueError("Preregistered inputs changed after review.")

    report_text = report.read_text(encoding="utf-8")
    expected_lines = [
        f"- Model: `{MODEL}`",
        f"- Reasoning effort: `{REASONING_EFFORT}`",
        f"- Review protocol: `{REVIEW_PROTOCOL_VERSION}`",
        f"- Preregistration: `{preregistration_path}`",
        f"- Preregistration SHA-256: `{gate['preregistration_sha256']}`",
        f"- Scope: {requested_scope}",
    ]
    if not all(line in report_text for line in expected_lines):
        raise ValueError("Report metadata does not match the gate.")
    review_start = report_text.find("## Decision")
    manifest_match = re.search(
        r"(?ms)^## Input Manifest\s*\n+```json\s*\n(?P<body>.*?)\n```\s*$",
        report_text[:review_start],
    )
    if not manifest_match:
        raise ValueError("Report input manifest is missing.")
    if json.loads(manifest_match.group("body")) != prereg["inputs"]:
        raise ValueError("Report input manifest does not match preregistration.")
    if review_start < 0:
        raise ValueError("Report does not contain a review decision.")
    verdict, conditions = parse_review_verdict(report_text[review_start:])
    if verdict != gate["verdict"] or conditions != gate["conditions"]:
        raise ValueError("Gate verdict does not match the report.")
    expected_status = "approved" if verdict == "approve" else "blocked"
    if gate["status"] != expected_status:
        raise ValueError("Gate status does not match the verdict.")
    return report, verdict, conditions


def main() -> int:
    args = parse_args()
    try:
        gate = json.loads(args.gate.read_text(encoding="utf-8"))
        _, verdict, conditions = validate_gate(
            gate,
            gate_path=args.gate,
            requested_scope=args.scope,
        )
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if verdict != "approve":
        print(
            json.dumps(
                {
                    "status": "blocked",
                    "gate": str(args.gate),
                    "scope": args.scope,
                    "conditions": conditions,
                }
            )
        )
        return 3

    print(
        json.dumps(
            {
                "status": "approved",
                "gate": str(args.gate),
                "scope": args.scope,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
