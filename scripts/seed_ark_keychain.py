#!/usr/bin/env python3
"""Seed Coffee Journal's iOS Keychain with local Ark credentials.

This script reads ignored local config.json and launches the installed app once
with DEBUG environment variables. The app copies those values into Keychain.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


DEFAULT_DEVICE = "00008130-000544543678001C"
DEFAULT_BUNDLE_ID = "com.dengos.CoffeeJournal"
DEFAULT_MODEL = "ep-20260516191128-js45j"
DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"


def load_config(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text())
    api_key = data.get("api_key")
    if isinstance(api_key, dict):
        api_key = api_key.get("secret")
    if not isinstance(api_key, str) or not api_key:
        raise SystemExit("config.json must contain api_key.secret")
    return {
        "ARK_API_KEY": api_key,
        "ARK_MODEL": data.get("model") or DEFAULT_MODEL,
        "ARK_BASE_URL": data.get("base_url") or DEFAULT_BASE_URL,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("config.json"))
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    env = load_config(args.config)
    command = [
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        args.device,
        "--terminate-existing",
        "--environment-variables",
        json.dumps(env),
        args.bundle_id,
    ]
    result = subprocess.run(command, check=False)
    if result.returncode == 0:
        print("Seed launch completed. Ark credentials should now be in the app Keychain.")
    else:
        print("Seed launch failed. Unlock the device and retry, or set ARK_API_KEY in the Xcode Run scheme once.")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
