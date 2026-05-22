#!/usr/bin/env python3
"""Evaluate Ark Seedream image generation for Coffee Journal flavor art."""

from __future__ import annotations

import argparse
import base64
import contextlib
import html
import json
import mimetypes
import signal
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"
DEFAULT_CONFIG = "config.json"
DEFAULT_EXPECTED = "eval/coffee_bag_expected_labels.json"
DEFAULT_OUTPUT_DIR = ".generated/flavor_art_eval"

MODEL_5 = "doubao-seedream-5-0-260128"
MODEL_45 = "doubao-seedream-4-5-251128"
MODEL_40 = "doubao-seedream-4-0-250828"

MODEL_PRICING_CNY_PER_IMAGE = {
    MODEL_5: 0.22,
    MODEL_45: 0.25,
}


@dataclass(frozen=True)
class EvalConfig:
    id: str
    model: str
    prompt_style: str
    size: str = "2K"
    watermark: bool = False
    repeats: int = 2


DEFAULT_CONFIGS = [
    EvalConfig("seedream5_card", MODEL_5, "card"),
    EvalConfig("seedream5_scene", MODEL_5, "scene"),
    EvalConfig("seedream45_card", MODEL_45, "card"),
    EvalConfig("seedream40_card", MODEL_40, "card"),
]


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def config_api_key(config: dict[str, Any]) -> str | None:
    value = config.get("api_key")
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("secret"), str):
        return value["secret"]
    return None


def config_string(config: dict[str, Any], key: str) -> str | None:
    value = config.get(key)
    return value if isinstance(value, str) else None


def selected_notes(notes: list[str], limit: int = 5) -> list[str]:
    return [note for note in notes if note][:limit]


def bean_title(case: dict[str, Any]) -> str:
    coffee = case["expected"]["coffee"]
    parts = [
        coffee.get("roaster"),
        coffee.get("origin"),
        coffee.get("variety"),
        coffee.get("process"),
    ]
    return " · ".join(str(part) for part in parts if part)


def build_prompt(case: dict[str, Any], style: str) -> str:
    coffee = case["expected"]["coffee"]
    notes = selected_notes(coffee.get("flavor_notes") or [])
    note_text = ", ".join(notes)
    primary = ", ".join(notes[:3])
    secondary = ", ".join(notes[3:])
    base = (
        "Create a premium editorial image for a private iOS coffee tasting journal. "
        "Visualize the sensory flavor notes of this coffee as a warm coffee tasting still life. "
        f"Coffee: roaster {coffee.get('roaster') or 'unknown'}, "
        f"origin {coffee.get('origin') or 'unknown'}, "
        f"variety {coffee.get('variety') or 'unknown'}, "
        f"process {coffee.get('process') or 'unknown'}. "
        f"Flavor notes in priority order: {note_text}. "
        f"Make the first notes most prominent: {primary}. "
    )
    if secondary:
        base += f"Subtly include these supporting notes only if composition allows: {secondary}. "
    guardrails = (
        "No readable text, no labels, no logos, no packaging, no UI, no watermark-like marks. "
        "Default to a pour-over coffee context: clear brewed coffee, dripper, server, filter paper, or tasting cup. "
        "Use a small handleless ceramic tasting cup or modern handleless pour-over cup; avoid traditional handled mugs. "
        "Do not show espresso cups, crema, portafilters, or espresso-machine cues unless the coffee is explicitly marked as espresso. "
        "Natural materials, ceramic cup, roasted beans, fruit or spice elements, refined lighting. "
        "Must look useful as a small card thumbnail and as a larger bean detail hero image."
    )
    if style == "scene":
        return (
            base
            + "Use a richer tasting-table scene with layered depth, soft morning light, shallow depth of field, "
            "and a realistic photographic composition. "
            + guardrails
        )
    return (
        base
        + "Use a clean centered composition with strong silhouette, high visual clarity, calm neutral background, "
        "and enough contrast for a mobile app card. "
        + guardrails
    )


def build_payload(config: EvalConfig, prompt: str, response_format: str) -> dict[str, Any]:
    return {
        "model": config.model,
        "prompt": prompt,
        "sequential_image_generation": "disabled",
        "response_format": response_format,
        "size": config.size,
        "stream": False,
        "watermark": config.watermark,
    }


def post_generation(api_key: str, base_url: str, payload: dict[str, Any], timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/images/generations",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
            return {
                "status": response.status,
                "elapsed_ms": int((time.time() - start) * 1000),
                "body": body,
            }
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {error_body}") from exc


@contextlib.contextmanager
def wall_timeout(seconds: int):
    def handle_timeout(signum: int, frame: Any) -> None:
        raise TimeoutError(f"generation exceeded wall timeout of {seconds}s")

    old_handler = signal.signal(signal.SIGALRM, handle_timeout)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


def response_image_items(body: dict[str, Any]) -> list[dict[str, Any]]:
    data = body.get("data")
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    images = body.get("images")
    if isinstance(images, list):
        return [item for item in images if isinstance(item, dict)]
    return []


def file_extension(content_type: str | None, fallback: str = ".png") -> str:
    if content_type:
        guessed = mimetypes.guess_extension(content_type.split(";")[0].strip())
        if guessed:
            return ".jpg" if guessed == ".jpe" else guessed
    return fallback


def save_url(url: str, output_stem: Path, timeout: int) -> Path:
    request = urllib.request.Request(url, headers={"User-Agent": "CoffeeJournalFlavorArtEval/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        content_type = response.headers.get("Content-Type")
        data = response.read()
    output_path = output_stem.with_suffix(file_extension(content_type))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(data)
    return output_path


def save_base64(encoded: str, output_stem: Path) -> Path:
    if encoded.startswith("data:"):
        metadata, encoded = encoded.split(",", 1)
        mime = metadata.split(";")[0].replace("data:", "")
        suffix = file_extension(mime)
    else:
        suffix = ".png"
    output_path = output_stem.with_suffix(suffix)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(base64.b64decode(encoded))
    return output_path


def save_response_images(body: dict[str, Any], output_stem: Path, timeout: int) -> list[str]:
    paths = []
    for index, item in enumerate(response_image_items(body)):
        stem = output_stem if index == 0 else output_stem.with_name(f"{output_stem.name}_{index + 1}")
        if isinstance(item.get("url"), str):
            paths.append(str(save_url(item["url"], stem, timeout)))
        elif isinstance(item.get("b64_json"), str):
            paths.append(str(save_base64(item["b64_json"], stem)))
        elif isinstance(item.get("image"), str):
            paths.append(str(save_base64(item["image"], stem)))
    return paths


def estimate_cost(model: str, images: int) -> dict[str, Any]:
    price = MODEL_PRICING_CNY_PER_IMAGE.get(model)
    return {
        "images": images,
        "cny_per_image": price,
        "estimated_cny": round(price * images, 4) if price is not None else None,
    }


def run_one(
    api_key: str,
    base_url: str,
    case: dict[str, Any],
    config: EvalConfig,
    repeat_index: int,
    output_dir: Path,
    response_format: str,
    timeout: int,
    force: bool,
) -> dict[str, Any]:
    prompt = build_prompt(case, config.prompt_style)
    result_path = output_dir / "results" / config.id / case["id"] / f"run_{repeat_index}.json"
    if result_path.exists() and not force:
        return read_json(result_path)

    payload = build_payload(config, prompt, response_format)
    image_stem = output_dir / "images" / config.id / case["id"] / f"run_{repeat_index}"
    error = None
    response: dict[str, Any] | None = None
    image_paths: list[str] = []
    try:
        with wall_timeout(timeout):
            response = post_generation(api_key, base_url, payload, timeout)
            image_paths = save_response_images(response["body"], image_stem, timeout)
        if not image_paths:
            error = "response did not contain url, b64_json, or image data"
    except Exception as exc:
        error = str(exc)

    result = {
        "case_id": case["id"],
        "bean": bean_title(case),
        "flavor_notes": case["expected"]["coffee"].get("flavor_notes") or [],
        "config_id": config.id,
        "model": config.model,
        "prompt_style": config.prompt_style,
        "size": config.size,
        "watermark": config.watermark,
        "repeat_index": repeat_index,
        "prompt": prompt,
        "payload": payload,
        "status": response.get("status") if response else None,
        "elapsed_ms": response.get("elapsed_ms") if response else None,
        "response_body": response.get("body") if response else None,
        "image_paths": image_paths,
        "cost": estimate_cost(config.model, len(image_paths)),
        "error": error,
        "review": {
            "flavor_coverage": None,
            "priority_hierarchy": None,
            "coffee_context": None,
            "app_card_aesthetic": None,
            "artifact_control": None,
            "thumbnail_usability": None,
            "total": None,
            "notes": None,
        },
    }
    write_json(result_path, result)
    return result


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
    by_config: dict[str, list[dict[str, Any]]] = {}
    for result in results:
        by_config.setdefault(result["config_id"], []).append(result)

    config_summaries = []
    for config_id, items in sorted(by_config.items()):
        latencies = [item["elapsed_ms"] for item in items if isinstance(item.get("elapsed_ms"), int)]
        images = sum(len(item.get("image_paths") or []) for item in items)
        known_costs = [
            item["cost"]["estimated_cny"]
            for item in items
            if isinstance(item.get("cost", {}).get("estimated_cny"), (int, float))
        ]
        config_summaries.append({
            "config_id": config_id,
            "model": items[0]["model"] if items else None,
            "prompt_style": items[0]["prompt_style"] if items else None,
            "cases": len(items),
            "successes": sum(1 for item in items if item.get("image_paths")),
            "images": images,
            "avg_latency_ms": round(sum(latencies) / len(latencies), 1) if latencies else None,
            "min_latency_ms": min(latencies) if latencies else None,
            "max_latency_ms": max(latencies) if latencies else None,
            "estimated_cny": round(sum(known_costs), 4) if known_costs else None,
        })
    total_costs = [
        item["cost"]["estimated_cny"]
        for item in results
        if isinstance(item.get("cost", {}).get("estimated_cny"), (int, float))
    ]
    return {
        "total_runs": len(results),
        "successful_runs": sum(1 for item in results if item.get("image_paths")),
        "total_images": sum(len(item.get("image_paths") or []) for item in results),
        "known_estimated_cny": round(sum(total_costs), 4) if total_costs else None,
        "configs": config_summaries,
    }


def write_markdown(output_dir: Path, summary: dict[str, Any], results: list[dict[str, Any]]) -> None:
    lines = [
        "# Coffee Flavor Art Evaluation",
        "",
        "## Summary",
        "",
        f"- Total runs: `{summary['total_runs']}`",
        f"- Successful runs: `{summary['successful_runs']}`",
        f"- Total images: `{summary['total_images']}`",
        f"- Known estimated CNY: `{summary['known_estimated_cny']}`",
        "",
        "## Configs",
        "",
        "| config | model | prompt | runs | successes | images | avg latency ms | estimated CNY |",
        "|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for item in summary["configs"]:
        lines.append(
            f"| `{item['config_id']}` | `{item['model']}` | `{item['prompt_style']}` | "
            f"{item['cases']} | {item['successes']} | {item['images']} | "
            f"{item['avg_latency_ms']} | {item['estimated_cny']} |"
        )
    lines += [
        "",
        "## Runs",
        "",
        "| case | config | repeat | latency ms | image | error |",
        "|---|---|---:|---:|---|---|",
    ]
    for result in results:
        image = result["image_paths"][0] if result.get("image_paths") else ""
        lines.append(
            f"| `{result['case_id']}` | `{result['config_id']}` | {result['repeat_index']} | "
            f"{result.get('elapsed_ms')} | `{image}` | {html.escape(str(result.get('error') or ''))} |"
        )
    (output_dir / "summary.md").write_text("\n".join(lines) + "\n")


def write_gallery(output_dir: Path, summary: dict[str, Any], results: list[dict[str, Any]]) -> None:
    rows = []
    for result in results:
        images = "".join(
            f'<a href="{html.escape(Path(path).relative_to(output_dir).as_posix())}">'
            f'<img src="{html.escape(Path(path).relative_to(output_dir).as_posix())}" loading="lazy" /></a>'
            for path in result.get("image_paths") or []
            if Path(path).is_relative_to(output_dir)
        )
        notes = ", ".join(result.get("flavor_notes") or [])
        error_html = ""
        if result.get("error"):
            error_html = f"<pre class='error'>{html.escape(result['error'])}</pre>"
        rows.append(
            "<section class='card'>"
            f"<h2>{html.escape(result['case_id'])} · {html.escape(result['config_id'])} · #{result['repeat_index']}</h2>"
            f"<div class='meta'>{html.escape(result['bean'])}</div>"
            f"<div class='notes'>{html.escape(notes)}</div>"
            f"<div class='metrics'>model: <code>{html.escape(result['model'])}</code> · "
            f"latency: {result.get('elapsed_ms')}ms · cost: {result.get('cost', {}).get('estimated_cny')}</div>"
            f"<div class='images'>{images}</div>"
            f"<details><summary>Prompt</summary><p>{html.escape(result['prompt'])}</p></details>"
            f"{error_html}"
            "</section>"
        )
    html_doc = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Coffee Flavor Art Evaluation</title>
  <style>
    body {{ margin: 0; padding: 32px; font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f7f3ea; color: #171411; }}
    h1 {{ font-size: 34px; margin: 0 0 8px; }}
    .summary {{ margin: 0 0 24px; color: #6f675e; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 18px; }}
    .card {{ background: #fffaf1; border: 1px solid #e7dccb; border-radius: 10px; padding: 16px; }}
    .card h2 {{ font-size: 17px; margin: 0 0 8px; }}
    .meta, .notes, .metrics {{ color: #665e55; margin: 5px 0; line-height: 1.35; }}
    .images {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; margin-top: 12px; }}
    img {{ width: 100%; aspect-ratio: 1 / 1; object-fit: cover; border-radius: 8px; border: 1px solid #e4d8c7; }}
    details {{ margin-top: 10px; color: #6b6258; }}
    details p {{ white-space: pre-wrap; }}
    .error {{ color: #b42318; white-space: pre-wrap; }}
  </style>
</head>
<body>
  <h1>Coffee Flavor Art Evaluation</h1>
  <p class="summary">Runs: {summary['total_runs']} · Successes: {summary['successful_runs']} · Images: {summary['total_images']} · Known estimated CNY: {summary['known_estimated_cny']}</p>
  <main class="grid">
    {''.join(rows)}
  </main>
</body>
</html>
"""
    (output_dir / "gallery.html").write_text(html_doc)


def write_review_template(output_dir: Path, results: list[dict[str, Any]]) -> None:
    review_items = []
    for result in results:
        review_items.append({
            "case_id": result["case_id"],
            "config_id": result["config_id"],
            "repeat_index": result["repeat_index"],
            "image_paths": result.get("image_paths") or [],
            "scores": result["review"],
        })
    write_json(output_dir / "review.json", {"rubric": {
        "flavor_coverage": 35,
        "priority_hierarchy": 20,
        "coffee_context": 15,
        "app_card_aesthetic": 15,
        "artifact_control": 10,
        "thumbnail_usability": 5,
    }, "items": review_items})


def write_contact_sheets(output_dir: Path, results: list[dict[str, Any]]) -> None:
    try:
        from PIL import Image, ImageDraw, ImageFont
    except Exception:
        return

    grouped: dict[str, list[dict[str, Any]]] = {}
    for result in results:
        if result.get("image_paths"):
            grouped.setdefault(result["config_id"], []).append(result)

    font = ImageFont.load_default()
    sheet_dir = output_dir / "contact_sheets"
    sheet_dir.mkdir(parents=True, exist_ok=True)
    cell_w, cell_h = 320, 390
    image_h = 320
    pad = 14

    for config_id, items in sorted(grouped.items()):
        items = sorted(items, key=lambda item: (item["case_id"], item["repeat_index"]))
        cols = 2
        rows = (len(items) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), "#f7f3ea")
        draw = ImageDraw.Draw(sheet)
        for index, item in enumerate(items):
            path = Path(item["image_paths"][0])
            with Image.open(path) as image:
                image = image.convert("RGB")
                image.thumbnail((cell_w - pad * 2, image_h - pad), Image.Resampling.LANCZOS)
                x = (index % cols) * cell_w + (cell_w - image.width) // 2
                y = (index // cols) * cell_h + pad
                sheet.paste(image, (x, y))
            label = f"{item['case_id']} #{item['repeat_index']}"
            draw.text(((index % cols) * cell_w + pad, (index // cols) * cell_h + image_h + 8), label, fill="#171411", font=font)
        sheet.save(sheet_dir / f"{config_id}.jpg", quality=88)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", type=Path, default=Path(DEFAULT_EXPECTED))
    parser.add_argument("--config", type=Path, default=Path(DEFAULT_CONFIG))
    parser.add_argument("--output-dir", type=Path, default=Path(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--response-format", choices=["url", "b64_json"], default="url")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--force-run", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    local_config = read_json(args.config) if args.config.exists() else {}
    api_key = config_api_key(local_config)
    if not api_key:
        raise SystemExit(f"Missing Ark API key in {args.config}")
    base_url = args.base_url or config_string(local_config, "base_url") or DEFAULT_BASE_URL

    cases = read_json(args.expected)["cases"]
    configs = DEFAULT_CONFIGS
    if args.smoke:
        cases = cases[:1]
        configs = [DEFAULT_CONFIGS[0]]
        configs = [EvalConfig(configs[0].id, configs[0].model, configs[0].prompt_style, configs[0].size, configs[0].watermark, 1)]

    run_id = time.strftime("%Y%m%d-%H%M%S")
    output_dir = args.output_dir / ("smoke-" + run_id if args.smoke else "run-" + run_id)
    output_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for config in configs:
        for case in cases:
            for repeat_index in range(1, config.repeats + 1):
                result = run_one(
                    api_key=api_key,
                    base_url=base_url,
                    case=case,
                    config=config,
                    repeat_index=repeat_index,
                    output_dir=output_dir,
                    response_format=args.response_format,
                    timeout=args.timeout,
                    force=args.force_run,
                )
                results.append(result)
                marker = "OK" if result.get("image_paths") else "FAIL"
                print(f"{marker} {config.id} {case['id']} #{repeat_index} {result.get('elapsed_ms')}ms", flush=True)

    summary = summarize(results)
    write_json(output_dir / "results.json", {"summary": summary, "results": results})
    write_markdown(output_dir, summary, results)
    write_gallery(output_dir, summary, results)
    write_review_template(output_dir, results)
    write_contact_sheets(output_dir, results)
    print(json.dumps({"output_dir": str(output_dir), "summary": summary}, ensure_ascii=False, indent=2))
    return 0 if summary["successful_runs"] == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
