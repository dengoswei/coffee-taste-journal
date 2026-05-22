#!/usr/bin/env python3
"""Batch-evaluate Ark VLM models for Coffee Journal Add Bean extraction."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Any


MODELS = [
    "doubao-seed-1-6-flash-250828",
    "doubao-seed-1-6-251015",
    "doubao-seed-1-8-251228",
]

FIELD_WEIGHTS = {
    "coffee.roaster": 2.0,
    "coffee.origin": 2.0,
    "coffee.variety": 2.0,
    "coffee.process": 2.0,
    "coffee.flavor_notes": 2.0,
    "bag.roast_date": 1.0,
    "bag.total_grams": 1.0,
    "coffee.name": 0.75,
    "coffee.farm": 0.75,
}


def load_probe_module() -> Any:
    path = Path(__file__).with_name("coffee_bag_vlm_probe.py")
    spec = importlib.util.spec_from_file_location("coffee_bag_vlm_probe", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def normalize_string(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).casefold().replace("&", " and ")
    keep = []
    for char in text:
        keep.append(char if char.isalnum() else " ")
    return " ".join("".join(keep).split())


def normalize_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        parts = [part.strip() for part in value.replace(";", ",").split(",")]
    elif isinstance(value, list):
        parts = [str(part).strip() for part in value]
    else:
        parts = [str(value).strip()]
    return [normalize_string(part) for part in parts if normalize_string(part)]


def get_path(value: dict[str, Any], path: str) -> Any:
    current: Any = value
    for part in path.split("."):
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return current


def score_scalar(expected: Any, actual: Any) -> float:
    if expected is None:
        return 1.0 if actual in (None, "", []) else 0.0
    if actual is None:
        return 0.0
    if isinstance(expected, (int, float)):
        try:
            return 1.0 if math.isclose(float(expected), float(actual), rel_tol=0, abs_tol=0.01) else 0.0
        except (TypeError, ValueError):
            return 0.0
    expected_norm = normalize_string(expected)
    actual_norm = normalize_string(actual)
    if expected_norm == actual_norm:
        return 1.0
    if expected_norm and actual_norm and (expected_norm in actual_norm or actual_norm in expected_norm):
        return 0.5
    return 0.0


def score_flavor_notes(expected: Any, actual: Any) -> float:
    expected_set = set(normalize_list(expected))
    actual_set = set(normalize_list(actual))
    if not expected_set:
        return 1.0 if not actual_set else 0.0
    if not actual_set:
        return 0.0
    overlap = len(expected_set & actual_set)
    precision = overlap / len(actual_set)
    recall = overlap / len(expected_set)
    if precision + recall == 0:
        return 0.0
    return 2 * precision * recall / (precision + recall)


def score_farm(expected: Any, actual: Any) -> float:
    if expected is None:
        return 1.0 if actual in (None, "", []) else 0.0
    expected_parts = set(normalize_list(expected))
    actual_parts = set(normalize_list(actual))
    if not actual_parts:
        return 0.0
    if expected_parts & actual_parts:
        return 1.0
    expected_joined = normalize_string(expected)
    actual_joined = normalize_string(actual)
    if expected_joined in actual_joined or actual_joined in expected_joined:
        return 0.75
    return 0.0


def score_case(expected: dict[str, Any], parsed: dict[str, Any] | None) -> dict[str, Any]:
    if parsed is None:
        weighted_total = sum(FIELD_WEIGHTS.values())
        return {
            "weighted_score": 0.0,
            "weighted_total": weighted_total,
            "accuracy": 0.0,
            "field_scores": [
                {"field": field, "weight": weight, "score": 0.0, "expected": get_path(expected, field), "actual": None}
                for field, weight in FIELD_WEIGHTS.items()
            ],
        }

    field_scores = []
    weighted_score = 0.0
    weighted_total = 0.0
    for field, weight in FIELD_WEIGHTS.items():
        expected_value = get_path(expected, field)
        actual_value = get_path(parsed, field)
        if field == "coffee.flavor_notes":
            score = score_flavor_notes(expected_value, actual_value)
        elif field == "coffee.farm":
            score = score_farm(expected_value, actual_value)
        else:
            score = score_scalar(expected_value, actual_value)
        weighted_score += score * weight
        weighted_total += weight
        field_scores.append({
            "field": field,
            "weight": weight,
            "score": round(score, 4),
            "expected": expected_value,
            "actual": actual_value,
        })
    return {
        "weighted_score": round(weighted_score, 4),
        "weighted_total": round(weighted_total, 4),
        "accuracy": round(weighted_score / weighted_total, 4) if weighted_total else 0.0,
        "field_scores": field_scores,
    }


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = math.ceil((pct / 100) * len(ordered)) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def run_command(args: list[str]) -> None:
    subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def convert_with_qlmanage(source: Path, output: Path, max_side: int, quality: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        run_command(["/usr/bin/qlmanage", "-t", "-s", str(max_side), "-o", str(tmp_path), str(source)])
        candidates = list(tmp_path.glob(f"{source.name}.*")) + list(tmp_path.glob("*.png")) + list(tmp_path.glob("*.jpg"))
        if not candidates:
            raise RuntimeError(f"qlmanage did not produce a preview for {source}")
        preview = max(candidates, key=lambda path: path.stat().st_size)
        run_command([
            "/usr/bin/sips",
            "-s", "format", "jpeg",
            "-s", "formatOptions", str(quality),
            str(preview),
            "--out", str(output),
        ])


def convert_with_sips(source: Path, output: Path, max_side: int, quality: int) -> None:
    run_command([
        "/usr/bin/sips",
        "--resampleHeightWidthMax", str(max_side),
        "-s", "format", "jpeg",
        "-s", "formatOptions", str(quality),
        str(source),
        "--out", str(output),
    ])


def prepare_image(source: Path, output: Path, max_side: int, quality: int, force: bool) -> None:
    if output.exists() and not force:
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        if source.suffix.casefold() in {".heic", ".heif"}:
            convert_with_qlmanage(source, output, max_side, quality)
        else:
            convert_with_sips(source, output, max_side, quality)
    except Exception:
        convert_with_qlmanage(source, output, max_side, quality)
    if not output.exists() or output.stat().st_size < 10_000:
        raise RuntimeError(f"prepared image looks invalid: {output}")


def build_probe_args(probe: Any, config: dict[str, Any], model: str, image: Path, args: argparse.Namespace) -> SimpleNamespace:
    return SimpleNamespace(
        images=[image],
        image_urls=[],
        config=str(args.config),
        api_key=probe.config_api_key(config),
        model=model,
        base_url=probe.config_string(config, "base_url") or probe.DEFAULT_BASE_URL,
        temperature=0.0,
        max_tokens=args.max_tokens,
        timeout=args.timeout,
        api="responses",
        detail=args.detail,
        prompt_mode=args.prompt_mode,
        json_mode=False,
        auto_orientation=True,
    )


def call_model(probe: Any, probe_args: SimpleNamespace) -> dict[str, Any]:
    response = probe.call_responses(probe_args, probe.build_responses_payload(probe_args))
    text = None
    parsed = None
    error = None
    try:
        text = probe.extract_responses_text(response)
        parsed = probe.parse_json_object(text)
    except Exception as exc:
        error = str(exc)
    return {
        "response_status": response["status"],
        "elapsed_ms": response["elapsed_ms"],
        "usage": response["body"].get("usage"),
        "raw_content": text,
        "response_body": response["body"] if error else None,
        "parsed": parsed,
        "error": error,
    }


def estimate_cost(config: dict[str, Any], model: str, usage: dict[str, Any] | None) -> dict[str, Any] | None:
    if not usage:
        return None
    pricing = config.get("pricing")
    if not isinstance(pricing, dict) or model not in pricing:
        return {
            "input_tokens": usage.get("input_tokens"),
            "output_tokens": usage.get("output_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "estimated_cost": None,
            "currency": None,
            "note": "No pricing configured. Add config.json pricing[model] with input_per_million and output_per_million.",
        }
    model_price = pricing[model]
    input_tokens = usage.get("input_tokens") or 0
    output_tokens = usage.get("output_tokens") or 0
    input_cost = input_tokens / 1_000_000 * float(model_price.get("input_per_million", 0))
    output_cost = output_tokens / 1_000_000 * float(model_price.get("output_per_million", 0))
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": usage.get("total_tokens"),
        "estimated_cost": round(input_cost + output_cost, 8),
        "currency": model_price.get("currency", "CNY"),
    }


def summarize_model(model: str, results: list[dict[str, Any]]) -> dict[str, Any]:
    latencies = [result["elapsed_ms"] for result in results if result.get("elapsed_ms") is not None]
    accuracies = [result["score"]["accuracy"] for result in results if result.get("score")]
    valid_count = sum(1 for result in results if result.get("parsed") is not None)
    total_tokens = sum(((result.get("usage") or {}).get("total_tokens") or 0) for result in results)
    costs = [((result.get("cost") or {}).get("estimated_cost")) for result in results]
    known_costs = [cost for cost in costs if isinstance(cost, (int, float))]
    field_totals: dict[str, list[float]] = {}
    for result in results:
        for field_score in result.get("score", {}).get("field_scores", []):
            field_totals.setdefault(field_score["field"], []).append(field_score["score"])
    return {
        "model": model,
        "cases": len(results),
        "json_validity": round(valid_count / len(results), 4) if results else 0.0,
        "weighted_accuracy": round(sum(accuracies) / len(accuracies), 4) if accuracies else 0.0,
        "field_accuracy": {
            field: round(sum(values) / len(values), 4)
            for field, values in sorted(field_totals.items())
        },
        "latency_ms": {
            "avg": round(sum(latencies) / len(latencies), 1) if latencies else None,
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
        },
        "total_tokens": total_tokens,
        "estimated_cost": round(sum(known_costs), 8) if known_costs else None,
    }


def summarize_variant(results: list[dict[str, Any]]) -> dict[str, Any]:
    latencies = [result["elapsed_ms"] for result in results if result.get("elapsed_ms") is not None]
    accuracies = [result["score"]["accuracy"] for result in results if result.get("score")]
    valid_count = sum(1 for result in results if result.get("parsed") is not None)
    total_tokens = sum(((result.get("usage") or {}).get("total_tokens") or 0) for result in results)
    input_tokens = sum(((result.get("usage") or {}).get("input_tokens") or 0) for result in results)
    output_tokens = sum(((result.get("usage") or {}).get("output_tokens") or 0) for result in results)
    prepared_sizes = [Path(result["prepared_image"]).stat().st_size for result in results if Path(result["prepared_image"]).exists()]
    return {
        "cases": len(results),
        "json_validity": round(valid_count / len(results), 4) if results else 0.0,
        "weighted_accuracy": round(sum(accuracies) / len(accuracies), 4) if accuracies else 0.0,
        "latency_ms": {
            "avg": round(sum(latencies) / len(latencies), 1) if latencies else None,
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
        },
        "tokens": {
            "input": input_tokens,
            "output": output_tokens,
            "total": total_tokens,
        },
        "prepared_image_bytes": {
            "avg": round(sum(prepared_sizes) / len(prepared_sizes), 1) if prepared_sizes else None,
            "min": min(prepared_sizes) if prepared_sizes else None,
            "max": max(prepared_sizes) if prepared_sizes else None,
        },
    }


def markdown_report(summary: dict[str, Any], results: list[dict[str, Any]]) -> str:
    lines = ["# Coffee Bag VLM Evaluation Report", ""]
    settings = summary.get("settings")
    if settings:
        lines += ["## Settings", ""]
        lines += [
            f"- Image detail: `{settings['detail']}`",
            f"- Prompt mode: `{settings['prompt_mode']}`",
            f"- Max side: `{settings['max_side']}`",
            f"- JPEG quality: `{settings['jpeg_quality']}`",
            f"- Max output tokens: `{settings['max_tokens']}`",
            "",
        ]
    variant = summary.get("variant")
    if variant:
        lines += ["## Variant Summary", ""]
        lines += [
            f"- Weighted accuracy: `{variant['weighted_accuracy']:.4f}`",
            f"- JSON validity: `{variant['json_validity']:.4f}`",
            f"- Avg latency ms: `{variant['latency_ms']['avg']}`",
            f"- p95 latency ms: `{variant['latency_ms']['p95']}`",
            f"- Total tokens: `{variant['tokens']['total']}`",
            "",
        ]
    recommendation = summary.get("recommendation")
    if recommendation:
        lines += [f"Recommended model: `{recommendation}`", ""]
    lines += ["## Model Summary", ""]
    lines += ["| model | weighted accuracy | JSON valid | avg latency ms | p95 latency ms | total tokens | estimated cost |"]
    lines += ["|---|---:|---:|---:|---:|---:|---:|"]
    for item in summary["models"]:
        lines.append(
            f"| `{item['model']}` | {item['weighted_accuracy']:.4f} | {item['json_validity']:.4f} | "
            f"{item['latency_ms']['avg']} | {item['latency_ms']['p95']} | {item['total_tokens']} | {item['estimated_cost']} |"
        )
    lines += ["", "## Per-Case Results", ""]
    lines += ["| case | model | accuracy | latency ms | tokens | notable misses |"]
    lines += ["|---|---|---:|---:|---:|---|"]
    for result in results:
        misses = []
        for field_score in result.get("score", {}).get("field_scores", []):
            if field_score["score"] < 1:
                misses.append(f"{field_score['field']}={field_score['score']}")
        usage = result.get("usage") or {}
        lines.append(
            f"| {result['case_id']} | `{result['model']}` | {result['score']['accuracy']:.4f} | "
            f"{result.get('elapsed_ms')} | {usage.get('total_tokens')} | {', '.join(misses[:5])} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", type=Path, default=Path("eval/coffee_bag_expected_labels.json"))
    parser.add_argument("--config", type=Path, default=Path("config.json"))
    parser.add_argument("--output-dir", type=Path, default=Path(".generated/vlm_eval"))
    parser.add_argument("--models", nargs="*", default=MODELS)
    parser.add_argument("--max-side", type=int, default=1800)
    parser.add_argument("--jpeg-quality", type=int, default=80)
    parser.add_argument("--max-tokens", type=int, default=5000)
    parser.add_argument("--detail", default="low", choices=["low", "high", "auto"])
    parser.add_argument("--prompt-mode", default="full", choices=["full", "compact"])
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--force-prepare", action="store_true")
    parser.add_argument("--force-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path.cwd()
    expected_doc = load_json(args.expected)
    config = load_json(args.config)
    probe = load_probe_module()

    prepared_dir = args.output_dir / "prepared"
    result_dir = args.output_dir / "results"
    prepared_cases = []
    for case in expected_doc["cases"]:
        source = root / case["source_image"]
        prepared = prepared_dir / f"{case['id']}.jpg"
        prepare_image(source, prepared, args.max_side, args.jpeg_quality, args.force_prepare)
        prepared_cases.append({**case, "prepared_image": str(prepared)})

    write_json(args.output_dir / "prepared_cases.json", {"cases": prepared_cases})
    if args.prepare_only:
        print(json.dumps({"prepared_cases": prepared_cases}, ensure_ascii=False, indent=2))
        return 0

    all_results = []
    for model in args.models:
        for case in prepared_cases:
            output_path = result_dir / model / f"{case['id']}.json"
            if output_path.exists() and not args.force_run:
                result = load_json(output_path)
                result["expected"] = case["expected"]
                result["score"] = score_case(case["expected"], result.get("parsed"))
                result["cost"] = estimate_cost(config, model, result.get("usage"))
                write_json(output_path, result)
            else:
                try:
                    probe_args = build_probe_args(probe, config, model, Path(case["prepared_image"]), args)
                    model_result = call_model(probe, probe_args)
                    parsed = model_result["parsed"]
                    error = model_result.get("error")
                except Exception as exc:
                    model_result = {
                        "response_status": None,
                        "elapsed_ms": None,
                        "usage": None,
                        "raw_content": None,
                        "response_body": None,
                    }
                    parsed = None
                    error = str(exc)
                score = score_case(case["expected"], parsed)
                result = {
                    "case_id": case["id"],
                    "source_image": case["source_image"],
                    "prepared_image": case["prepared_image"],
                    "model": model,
                    "error": error,
                    "elapsed_ms": model_result["elapsed_ms"],
                    "usage": model_result["usage"],
                    "cost": estimate_cost(config, model, model_result["usage"]),
                    "raw_content": model_result["raw_content"],
                    "response_body": model_result.get("response_body"),
                    "parsed": parsed,
                    "expected": case["expected"],
                    "score": score,
                }
                write_json(output_path, result)
            all_results.append(result)

    model_summaries = [
        summarize_model(model, [result for result in all_results if result["model"] == model])
        for model in args.models
    ]
    ranked = sorted(
        model_summaries,
        key=lambda item: (
            -item["weighted_accuracy"],
            item["latency_ms"]["avg"] if item["latency_ms"]["avg"] is not None else float("inf"),
            item["estimated_cost"] if item["estimated_cost"] is not None else float("inf"),
        ),
    )
    summary = {
        "recommendation": ranked[0]["model"] if ranked else None,
        "settings": {
            "detail": args.detail,
            "prompt_mode": args.prompt_mode,
            "max_side": args.max_side,
            "jpeg_quality": args.jpeg_quality,
            "max_tokens": args.max_tokens,
        },
        "variant": summarize_variant(all_results),
        "models": model_summaries,
        "field_weights": FIELD_WEIGHTS,
    }
    write_json(args.output_dir / "summary.json", summary)
    (args.output_dir / "summary.md").write_text(markdown_report(summary, all_results))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
