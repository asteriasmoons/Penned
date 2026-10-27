#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PENNED_MAC_DERIVED_DATA:-/tmp/PennedMacBuild}"
MODE="${1:-run}"
APP="$BUILD_DIR/Build/Products/Debug/PennedMac.app"
cd "$ROOT"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) printf 'Usage: %s [run|--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;; esac

# Ask the app to save and terminate. Never force-kill pending document edits.
if pgrep -x PennedMac >/dev/null; then
    osascript -e 'tell application id "im.lystaria.PennedMac" to quit'
    for _ in {1..30}; do pgrep -x PennedMac >/dev/null || break; sleep 1; done
    if pgrep -x PennedMac >/dev/null; then printf 'Penned is still saving or waiting for a confirmation. Close it before rebuilding.\n' >&2; exit 1; fi
fi
xcodebuild -project Vellix.xcodeproj -scheme PennedMac -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" "CODE_SIGNING_ALLOWED=${PENNED_CODE_SIGNING_ALLOWED:-YES}" build
case "$MODE" in
    --debug) lldb -- "$APP/Contents/MacOS/PennedMac" ;;
    --logs) open -n "$APP"; /usr/bin/log stream --style compact --info --predicate 'process == "PennedMac"' ;;
    --telemetry) open -n "$APP"; /usr/bin/log stream --style compact --info --predicate 'subsystem == "im.lystaria.PennedMac" OR subsystem == "im.lystaria.Vellix"' ;;
    --verify) open -n "$APP"; sleep 3; pgrep -x PennedMac >/dev/null ;;
    run) open -n "$APP" ;;
esac
