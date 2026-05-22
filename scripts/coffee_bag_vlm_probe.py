#!/usr/bin/env python3
"""Probe Ark-compatible VLM extraction quality for coffee bag photos.

Usage:
  python3 scripts/coffee_bag_vlm_probe.py front.jpg back.jpg
  python3 scripts/coffee_bag_vlm_probe.py --image-url https://example.com/bag.jpg
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"
DEFAULT_MODEL = "doubao-seed-1-6-flash-250828"
DEFAULT_CONFIG = "config.json"

SYSTEM_PROMPT = """You extract Add Bean draft information from coffee bag photos for a private coffee journal.
Return only valid JSON. Do not wrap it in Markdown.
Extract only information that is visible on the package.
Use null when a value is missing, ambiguous, too long, or not confidently readable.
Do not infer roast date, process, total grams, name, or farm from unrelated text.
Preserve roaster, variety, process, and flavor note spelling from the image.
If multiple photos are provided, combine evidence from all of them."""

USER_PROMPT = """Extract this schema:
{
  "coffee": {
    "roaster": string|null,
    "name": string|null,
    "origin": string|null,
    "farm": string|null,
    "variety": string|null,
    "process": string|null,
    "flavor_notes": [string],
    "notes": string|null
  },
  "bag": {
    "roast_date": "YYYY-MM-DD"|null,
    "total_grams": number|null
  },
  "evidence": {
    "roaster": string|null,
    "name": string|null,
    "origin": string|null,
    "farm": string|null,
    "variety": string|null,
    "process": string|null,
    "flavor_notes": string|null,
    "roast_date": string|null,
    "total_grams": string|null
  },
  "confidence": {
    "roaster": number,
    "name": number,
    "origin": number,
    "farm": number,
    "variety": number,
    "process": number,
    "flavor_notes": number,
    "roast_date": number,
    "total_grams": number
  }
}

Coffee-specific rules:
- High-priority fields are roaster, origin, variety, process, and flavor_notes.
- Origin must be country-level only, for example Peru, Costa Rica, Panama, or Colombia. Do not include regions or farms in origin.
- Roaster is the company/brand that roasted or sold the beans.
- Name is optional and must be conservative: only return a short product or lot name, typically 1-3 words. If the visible candidate is a long descriptive phrase, producer name, farm name, or ambiguous, return null.
- Farm should capture clearly visible farm, finca, estate, producer, or producer-family information. Return null if ambiguous.
- Process must be null if the bag does not explicitly show the processing method.
- Roast date must be null unless explicitly labeled as roast date or roasted on.
- Total grams must be null unless explicitly shown as net weight, weight, grams, or bag size."""

COMPACT_USER_PROMPT = """Return only this JSON schema:
{
  "coffee": {
    "roaster": string|null,
    "name": string|null,
    "origin": string|null,
    "farm": string|null,
    "variety": string|null,
    "process": string|null,
    "flavor_notes": [string]
  },
  "bag": {
    "roast_date": "YYYY-MM-DD"|null,
    "total_grams": number|null
  }
}

Rules:
- Extract only visible package text. Use null for missing, ambiguous, or unreadable values.
- Origin must be country-level only, such as Peru, Costa Rica, Panama, or Colombia.
- Name is optional: return only a clear short product or lot name, usually 1-3 words; otherwise null.
- Farm is optional: return only clearly visible farm, finca, estate, producer, or producer-family text.
- Do not infer roast date, total grams, process, name, or farm.
- Preserve flavor note wording from the package."""


def selected_user_prompt(prompt_mode: str) -> str:
    if prompt_mode == "compact":
        return COMPACT_USER_PROMPT
    return USER_PROMPT


def make_data_url(path: Path) -> str:
    data = path.read_bytes()
    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    encoded = base64.b64encode(data).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def read_config(path: str) -> dict[str, Any]:
    config_path = Path(path).expanduser()
    if not config_path.exists():
        return {}
    return json.loads(config_path.read_text())


def config_string(config: dict[str, Any], key: str) -> str | None:
    value = config.get(key)
    if isinstance(value, str):
        return value
    return None


def config_api_key(config: dict[str, Any]) -> str | None:
    value = config.get("api_key")
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        secret = value.get("secret")
        if isinstance(secret, str):
            return secret
    return None


def build_chat_payload(args: argparse.Namespace) -> dict[str, Any]:
    image_items = [
        {
            "type": "image_url",
            "image_url": {
                "url": make_data_url(Path(image_path)),
                "detail": args.detail,
            },
        }
        for image_path in args.images
    ]
    text_item = {"type": "text", "text": selected_user_prompt(args.prompt_mode)}
    payload: dict[str, Any] = {
        "model": args.model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": [*image_items, text_item]},
        ],
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
    }
    if args.json_mode:
        payload["response_format"] = {"type": "json_object"}
    return payload


def build_responses_payload(args: argparse.Namespace) -> dict[str, Any]:
    image_items = [
        {
            "type": "input_image",
            "image_url": make_data_url(Path(image_path)),
            "detail": args.detail,
        }
        for image_path in args.images
    ]
    image_items.extend(
        {"type": "input_image", "image_url": image_url, "detail": args.detail}
        for image_url in args.image_urls
    )
    payload: dict[str, Any] = {
        "model": args.model,
        "input": [
            {
                "role": "user",
                "content": [
                    *image_items,
                    {
                        "type": "input_text",
                        "text": f"{SYSTEM_PROMPT}\n\n{selected_user_prompt(args.prompt_mode)}",
                    },
                ],
            }
        ],
        "temperature": args.temperature,
        "max_output_tokens": args.max_tokens,
    }
    return payload


def call_chat_completions(args: argparse.Namespace, payload: dict[str, Any]) -> dict[str, Any]:
    url = f"{args.base_url.rstrip('/')}/chat/completions"
    headers = {
        "Authorization": f"Bearer {args.api_key}",
        "Content-Type": "application/json",
    }
    if args.auto_orientation:
        headers["X-Ark-Auto-Orientation"] = "true"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            body = response.read().decode("utf-8")
            elapsed_ms = int((time.time() - start) * 1000)
            return {"status": response.status, "elapsed_ms": elapsed_ms, "body": json.loads(body)}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {error_body}") from exc


def call_responses(args: argparse.Namespace, payload: dict[str, Any]) -> dict[str, Any]:
    url = f"{args.base_url.rstrip('/')}/responses"
    headers = {
        "Authorization": f"Bearer {args.api_key}",
        "Content-Type": "application/json",
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            body = response.read().decode("utf-8")
            elapsed_ms = int((time.time() - start) * 1000)
            return {"status": response.status, "elapsed_ms": elapsed_ms, "body": json.loads(body)}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {error_body}") from exc


def extract_chat_message_text(response: dict[str, Any]) -> str:
    choices = response.get("body", {}).get("choices", [])
    if not choices:
        raise ValueError("response has no choices")
    message = choices[0].get("message", {})
    content = message.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(part.get("text", "") for part in content if isinstance(part, dict))
    raise ValueError(f"unexpected message content type: {type(content).__name__}")


def extract_responses_text(response: dict[str, Any]) -> str:
    body = response.get("body", {})
    output_text = body.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text

    texts: list[str] = []
    for item in body.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if not isinstance(content, dict):
                continue
            text = content.get("text")
            if isinstance(text, str):
                texts.append(text)
    if texts:
        return "\n".join(texts)
    raise ValueError("response has no output text")


def parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.strip("`")
        if stripped.startswith("json"):
            stripped = stripped[4:].strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise
        return json.loads(stripped[start : end + 1])


def flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, nested in value.items():
            next_prefix = f"{prefix}.{key}" if prefix else key
            out.update(flatten(nested, next_prefix))
        return out
    return {prefix: value}


def normalize(value: Any) -> Any:
    if isinstance(value, str):
        return " ".join(value.casefold().split())
    if isinstance(value, list):
        return sorted(normalize(item) for item in value)
    return value


def compare_expected(parsed: dict[str, Any], expected_path: str | None) -> dict[str, Any] | None:
    if not expected_path:
        return None
    expected = json.loads(Path(expected_path).read_text())
    actual_flat = flatten(parsed)
    expected_flat = flatten(expected)
    rows = []
    matches = 0
    for key, expected_value in expected_flat.items():
        actual_value = actual_flat.get(key)
        ok = normalize(actual_value) == normalize(expected_value)
        matches += int(ok)
        rows.append({"field": key, "ok": ok, "expected": expected_value, "actual": actual_value})
    return {"matched": matches, "total": len(rows), "fields": rows}


def positive_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.exists():
        raise argparse.ArgumentTypeError(f"file does not exist: {path}")
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"not a file: {path}")
    return path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="*", type=positive_path, help="coffee bag image path(s)")
    parser.add_argument("--image-url", dest="image_urls", action="append", default=[], help="remote image URL")
    parser.add_argument("--expected", help="optional expected JSON subset for exact field comparison")
    parser.add_argument("--output", default="/tmp/coffee_bag_vlm_probe_result.json", help="output JSON path")
    parser.add_argument("--config", default=os.environ.get("ARK_CONFIG", DEFAULT_CONFIG), help="JSON config path")
    parser.add_argument("--api", default=os.environ.get("ARK_API_STYLE", "responses"), choices=["responses", "chat"])
    parser.add_argument("--base-url", default=os.environ.get("ARK_BASE_URL"))
    parser.add_argument("--api-key", default=os.environ.get("ARK_API_KEY"))
    parser.add_argument("--model", default=os.environ.get("ARK_MODEL"))
    parser.add_argument("--detail", default=os.environ.get("ARK_IMAGE_DETAIL", "high"), choices=["low", "high", "auto"])
    parser.add_argument("--prompt-mode", default="full", choices=["full", "compact"])
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--max-tokens", type=int, default=5000)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--json-mode", action="store_true", help="send response_format={type: json_object}")
    parser.add_argument("--no-auto-orientation", dest="auto_orientation", action="store_false")
    parser.set_defaults(auto_orientation=True)
    args = parser.parse_args()
    config = read_config(args.config)
    args.api_key = args.api_key or config_api_key(config)
    args.model = args.model or config_string(config, "model") or DEFAULT_MODEL
    args.base_url = args.base_url or config_string(config, "base_url") or DEFAULT_BASE_URL
    if not args.api_key:
        parser.error("missing ARK_API_KEY or --api-key")
    if not args.images and not args.image_urls:
        parser.error("provide at least one local image path or --image-url")
    return args


def main() -> int:
    args = parse_args()
    if args.api == "responses":
        payload = build_responses_payload(args)
        response = call_responses(args, payload)
        text = extract_responses_text(response)
    else:
        payload = build_chat_payload(args)
        response = call_chat_completions(args, payload)
        text = extract_chat_message_text(response)
    parsed = parse_json_object(text)
    result = {
        "request": {
            "api": args.api,
            "base_url": args.base_url,
            "model": args.model,
            "images": [str(path) for path in args.images],
            "image_urls": args.image_urls,
            "detail": args.detail,
            "prompt_mode": args.prompt_mode,
            "json_mode": args.json_mode,
        },
        "response_status": response["status"],
        "elapsed_ms": response["elapsed_ms"],
        "usage": response["body"].get("usage"),
        "raw_content": text,
        "parsed": parsed,
        "comparison": compare_expected(parsed, args.expected),
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"coffee_bag_vlm_probe failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
