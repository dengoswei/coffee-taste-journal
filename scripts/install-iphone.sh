#!/bin/zsh
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

repo_root="${0:A:h:h}"
project="$repo_root/CoffeeTasteJournal.xcodeproj"
scheme="CoffeeJournalApp"
app_name="Coffee Journal.app"
derived_data="$repo_root/.build/xcode-derived"
device_id="${1:-${DEVICE_ID:-}}"

if [[ -z "$device_id" ]]; then
  devices_json="$(mktemp /private/tmp/coffee-journal-devices.XXXXXX)"
  trap 'rm -f "$devices_json"' EXIT
  xcrun devicectl list devices --timeout 30 --json-output "$devices_json" >/dev/null
  device_id="$(jq -r 'first(.result.devices[] | select(.hardwareProperties.reality == "physical" and .deviceProperties.bootState == "booted" and .connectionProperties.tunnelState == "connected") | .identifier) // empty' "$devices_json")"
fi

if [[ -z "$device_id" || "$device_id" == "null" ]]; then
  echo "No connected, booted physical iPhone found. Connect and unlock the iPhone, then retry." >&2
  exit 1
fi

app_path="$derived_data/Build/Products/Debug-iphoneos/$app_name"
if [[ ! -d "$app_path" ]]; then
  app_path="$(find "$repo_root" -type d -path "*/Build/Products/*-iphoneos/$app_name" -print -quit 2>/dev/null || true)"
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  xcodebuild -project "$project" -scheme "$scheme" -configuration Debug \
    -destination "id=$device_id" -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates build
  app_path="$derived_data/Build/Products/Debug-iphoneos/$app_name"
fi

[[ -d "$app_path" ]] || { echo "Built app not found: $app_path" >&2; exit 1; }
echo "Installing cached app: $app_path"
xcrun devicectl device install app --device "$device_id" "$app_path"
