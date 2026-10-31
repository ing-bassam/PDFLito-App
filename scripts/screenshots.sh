#!/bin/bash
# Takes the App Store screenshots in the Simulator using the built-in demo content.
# Usage: scripts/screenshots.sh <simulator-udid> <path/to/PDFLito.app> <output-folder>
set -euo pipefail

UDID="$1"
APP="$2"
OUT="$3"
BUNDLE_ID="${BUNDLE_ID:-de.pdflito.app}"

mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" "$APP"

shoot() {
  local name="$1"
  shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo YES "$@"
  sleep 20
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
  echo "Screenshot $name gespeichert"
}

shoot "01_pruefen" -screen review
shoot "02_dokumente" -screen library
shoot "03_einstellungen" -screen settings
