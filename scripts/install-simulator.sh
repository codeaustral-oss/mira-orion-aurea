#!/usr/bin/env bash
# Build both current apps and attach the configured hosted proxy before install.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${MIRA_UDID:-C5BE91CC-4C0D-4BA7-8491-06B2D79916BE}"
DD="$ROOT/.build/SimulatorCurrent"
LOCK="$ROOT/.build/simulator-install.lock"
mkdir -p "$ROOT/.build"
mkdir "$LOCK" 2>/dev/null || { echo "Another simulator install is running." >&2; exit 1; }
trap 'rmdir "$LOCK"' EXIT
for BRAND in Aurea Orion; do
  LOG="$ROOT/.build/simulator-${BRAND}.log"
  xcodebuild -project "$ROOT/MiraApp/Mira.xcodeproj" -scheme "Mira${BRAND}" \
    -configuration Debug -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 || { tail -60 "$LOG"; exit 1; }
  APP="$DD/Build/Products/Debug-iphonesimulator/Mira${BRAND}.app"
  "$ROOT/scripts/point-app.sh" "$APP"
  # Generated artwork can arrive with macOS provenance metadata. Remove it
  # from the simulator bundle before signing; it is not part of the app.
  xattr -cr "$APP"
  codesign --force --sign - "$APP" >/dev/null 2>&1
  xcrun simctl install "$UDID" "$APP"
  echo "Installed current Mira${BRAND}."
done
shasum -a 256 "$ROOT/MiraApp/Mira/Screens/Chat/"*.swift > "$ROOT/.build/simulator-source.sha256"
xcrun simctl launch --terminate-running-process "$UDID" com.codeaustral.mira.aurea
