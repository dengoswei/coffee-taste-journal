#!/usr/bin/env python3
"""Create a complete local Flomo backup without persisting credentials."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import requests


API_URL = "https://flomoapp.com/api/v1/memo/updated/"
API_SALT = "dbbc3dd73364b4084c3a69346e0ce2b2"
PAGE_LIMIT = 200


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def authorization(config_path: Path) -> str:
    token = os.environ.get("FLOMO_AUTHORIZATION")
    if not token and config_path.exists():
        config = read_json(config_path)
        token = config.get("authorization")
    if not isinstance(token, str) or not token.strip():
        raise SystemExit(
            "missing Flomo authorization; set FLOMO_AUTHORIZATION or run "
            "`flomo config --token ...`"
        )
    token = token.strip()
    return token if token.startswith("Bearer ") else f"Bearer {token}"


def signed_params(cursor: dict[str, Any] | None = None) -> dict[str, Any]:
    params: dict[str, Any] = {
        "limit": PAGE_LIMIT,
        "tz": "8:0",
        "timestamp": str(int(datetime.now().timestamp())),
        "api_key": "flomo_web",
        "app_version": "5.25.64",
        "platform": "mac",
        "webp": "1",
    }
    if cursor:
        params.update(cursor)
    signature_input = "&".join(
        f"{key}={value}" for key, value in sorted(params.items())
    )
    params["sign"] = hashlib.md5(
        (signature_input + API_SALT).encode("utf-8")
    ).hexdigest()
    return params


def cursor_for(memo: dict[str, Any]) -> dict[str, Any]:
    updated_at = memo.get("updated_at")
    slug = memo.get("slug")
    if not isinstance(updated_at, str) or not isinstance(slug, str):
        raise RuntimeError("last memo is missing pagination fields")
    return {
        "latest_slug": slug,
        "latest_updated_at": int(datetime.fromisoformat(updated_at).timestamp()),
    }


def fetch_all_memos(
    session: requests.Session,
    token: str,
    pages_dir: Path,
    timeout: int,
) -> tuple[list[dict[str, Any]], int]:
    pages_dir.mkdir(parents=True, exist_ok=True)
    cursor: dict[str, Any] | None = None
    memos: list[dict[str, Any]] = []
    seen_cursors: set[tuple[str, int]] = set()
    page_number = 0

    while True:
        page_number += 1
        response = session.get(
            API_URL,
            params=signed_params(cursor),
            headers={"authorization": token},
            timeout=timeout,
        )
        response.raise_for_status()
        payload = response.json()
        if payload.get("code") != 0:
            raise RuntimeError(
                f"Flomo API returned code={payload.get('code')}: "
                f"{payload.get('message') or payload.get('msg') or 'unknown error'}"
            )
        page = payload.get("data") or []
        if not isinstance(page, list):
            raise RuntimeError("Flomo API data is not a list")
        write_json(pages_dir / f"page-{page_number:04d}.json", payload)
        memos.extend(page)

        if len(page) < PAGE_LIMIT:
            break
        cursor = cursor_for(page[-1])
        cursor_key = (
            str(cursor["latest_slug"]),
            int(cursor["latest_updated_at"]),
        )
        if cursor_key in seen_cursors:
            raise RuntimeError("Flomo pagination cursor repeated")
        seen_cursors.add(cursor_key)

    return memos, page_number


def safe_extension(file_record: dict[str, Any], url: str) -> str:
    candidates = [
        str(file_record.get("name") or ""),
        urlparse(url).path,
    ]
    for candidate in candidates:
        suffix = Path(candidate).suffix.lower()
        if re.fullmatch(r"\.[a-z0-9]{1,10}", suffix):
            return suffix
    return ".bin"


def download_file(
    session: requests.Session,
    url: str,
    destination: Path,
    timeout: int,
) -> dict[str, Any]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    with session.get(url, stream=True, timeout=timeout) as response:
        response.raise_for_status()
        with destination.open("wb") as output:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if not chunk:
                    continue
                output.write(chunk)
                digest.update(chunk)
                size += len(chunk)
    return {
        "path": str(destination),
        "bytes": size,
        "sha256": digest.hexdigest(),
    }


def backup_media(
    session: requests.Session,
    memos: list[dict[str, Any]],
    backup_dir: Path,
    timeout: int,
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for memo in memos:
        slug = memo.get("slug")
        for index, file_record in enumerate(memo.get("files") or [], start=1):
            if not isinstance(file_record, dict):
                raise RuntimeError(f"memo {slug} has a non-object file record")
            file_id = str(file_record.get("id") or f"{slug}-{index}")
            record: dict[str, Any] = {
                "memo_slug": slug,
                "file_id": file_id,
                "name": file_record.get("name"),
                "type": file_record.get("type"),
                "declared_size": file_record.get("size"),
                "downloads": {},
            }
            for role, field, directory in (
                ("original", "url", "original"),
                ("thumbnail", "thumbnail_url", "thumbnail"),
            ):
                url = file_record.get(field)
                if not isinstance(url, str) or not url.startswith(
                    ("http://", "https://")
                ):
                    continue
                extension = safe_extension(file_record, url)
                destination = (
                    backup_dir / "media" / directory / f"{file_id}{extension}"
                )
                downloaded = download_file(
                    session,
                    url,
                    destination,
                    timeout,
                )
                downloaded["path"] = str(
                    destination.relative_to(backup_dir)
                )
                downloaded["source_url"] = url
                record["downloads"][role] = downloaded
            if "original" not in record["downloads"]:
                raise RuntimeError(
                    f"file {file_id} in memo {slug} has no downloadable original"
                )
            records.append(record)
    return records


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksums(backup_dir: Path) -> None:
    checksum_path = backup_dir / "SHA256SUMS"
    files = sorted(
        path for path in backup_dir.rglob("*")
        if path.is_file() and path != checksum_path
    )
    lines = [
        f"{file_sha256(path)}  {path.relative_to(backup_dir)}"
        for path in files
    ]
    checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_manifest(
    memos: list[dict[str, Any]],
    page_count: int,
    media_records: list[dict[str, Any]],
    created_at: str,
) -> dict[str, Any]:
    slugs = [memo.get("slug") for memo in memos]
    created_values = [
        memo.get("created_at") for memo in memos if memo.get("created_at")
    ]
    updated_values = [
        memo.get("updated_at") for memo in memos if memo.get("updated_at")
    ]
    fields = Counter(key for memo in memos for key in memo)
    original_downloads = [
        record["downloads"]["original"] for record in media_records
    ]
    thumbnail_downloads = [
        record["downloads"]["thumbnail"]
        for record in media_records
        if "thumbnail" in record["downloads"]
    ]
    slug_digest = hashlib.sha256(
        "\n".join(sorted(str(slug) for slug in slugs)).encode("utf-8")
    ).hexdigest()
    return {
        "schema_version": 1,
        "created_at": created_at,
        "source": {
            "service": "Flomo",
            "api_url": API_URL,
            "page_limit": PAGE_LIMIT,
            "authorization_persisted": False,
        },
        "memos": {
            "count": len(memos),
            "unique_slug_count": len(set(slugs)),
            "duplicate_slug_count": len(slugs) - len(set(slugs)),
            "deleted_count": sum(bool(memo.get("deleted_at")) for memo in memos),
            "page_count": page_count,
            "first_created_at": min(created_values, default=None),
            "last_created_at": max(created_values, default=None),
            "first_updated_at": min(updated_values, default=None),
            "last_updated_at": max(updated_values, default=None),
            "sorted_slug_sha256": slug_digest,
            "field_presence": dict(sorted(fields.items())),
        },
        "media": {
            "file_record_count": len(media_records),
            "original_download_count": len(original_downloads),
            "original_bytes": sum(item["bytes"] for item in original_downloads),
            "thumbnail_download_count": len(thumbnail_downloads),
            "thumbnail_bytes": sum(
                item["bytes"] for item in thumbnail_downloads
            ),
        },
        "artifacts": {
            "raw_pages": "raw/pages/",
            "merged_json": "raw/memos.json",
            "newline_json": "raw/memos.ndjson",
            "media_index": "media/index.json",
            "checksums": "SHA256SUMS",
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("backups/flomo"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path.home() / ".flomo" / "config.json",
    )
    parser.add_argument("--timeout", type=int, default=60)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = authorization(args.config)
    created = datetime.now().astimezone()
    backup_name = created.strftime("%Y%m%d-%H%M%S")
    output_root = args.output_root.resolve()
    final_dir = output_root / backup_name
    partial_dir = output_root / f".partial-{backup_name}"
    if final_dir.exists() or partial_dir.exists():
        raise SystemExit(f"backup path already exists: {backup_name}")

    output_root.mkdir(parents=True, exist_ok=True)
    partial_dir.mkdir()
    session = requests.Session()
    try:
        memos, page_count = fetch_all_memos(
            session,
            token,
            partial_dir / "raw" / "pages",
            args.timeout,
        )
        slugs = [memo.get("slug") for memo in memos]
        if len(slugs) != len(set(slugs)):
            raise RuntimeError("duplicate memo slugs detected")
        write_json(partial_dir / "raw" / "memos.json", memos)
        ndjson = "\n".join(
            json.dumps(memo, ensure_ascii=False, separators=(",", ":"))
            for memo in memos
        )
        (partial_dir / "raw" / "memos.ndjson").write_text(
            ndjson + ("\n" if ndjson else ""),
            encoding="utf-8",
        )

        media_records = backup_media(
            session,
            memos,
            partial_dir,
            args.timeout,
        )
        write_json(partial_dir / "media" / "index.json", media_records)
        manifest = build_manifest(
            memos,
            page_count,
            media_records,
            created.isoformat(),
        )
        write_json(partial_dir / "manifest.json", manifest)
        (partial_dir / "README.md").write_text(
            "# Flomo Local Backup\n\n"
            "This directory contains raw API pages, a merged memo corpus, "
            "downloaded original media, thumbnails, a media index, and "
            "SHA-256 checksums. Authentication credentials are not stored.\n",
            encoding="utf-8",
        )
        write_checksums(partial_dir)
        partial_dir.rename(final_dir)
        write_json(
            output_root / "latest.json",
            {
                "backup": backup_name,
                "manifest": f"{backup_name}/manifest.json",
                "created_at": created.isoformat(),
            },
        )
    except Exception:
        shutil.rmtree(partial_dir, ignore_errors=True)
        raise
    finally:
        session.close()

    print(
        json.dumps(
            {
                "backup_dir": str(final_dir),
                "memo_count": manifest["memos"]["count"],
                "unique_slug_count": manifest["memos"]["unique_slug_count"],
                "file_record_count": manifest["media"]["file_record_count"],
                "original_download_count": manifest["media"][
                    "original_download_count"
                ],
                "thumbnail_download_count": manifest["media"][
                    "thumbnail_download_count"
                ],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
