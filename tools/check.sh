#!/usr/bin/env bash
# One command for every local check. Run it before each commit.
# Usage: bash tools/check.sh [--firmware-build] [--ios]
#   --firmware-build  also compile every PlatformIO environment (slow).
#   --ios             also build the iOS app and run its XCTests on a
#                     simulator (slow; needs Xcode and an iOS simulator).
# It never uploads firmware or installs the app.
set -euo pipefail
cd "$(dirname "$0")/.."

build=false
ios=false
for arg in "$@"; do
  case "$arg" in
    --firmware-build) build=true ;;
    --ios) ios=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }

step "App: formatting and rule guards"
(cd moto_nav_bridge && dart format --output=none --set-exit-if-changed lib test)
python3 tools/check_rules.py

step "App: static analysis"
(cd moto_nav_bridge && flutter analyze)

step "App: tests"
(cd moto_nav_bridge && flutter test --timeout 60s)

step "Firmware: host tests"
for test in packet_auth panel_init ui_state map_motion anti_alias_render side_road_ray; do
  bash "firmware/tests/run_${test}_test.sh"
done
python3 firmware/tests/monitor_config_test.py

step "Database: migration tests"
(cd supabase/tests && npm test --silent)

if $build; then
  step "Firmware: PlatformIO builds"
  pio="${PIO:-$HOME/.platformio/penv/bin/pio}"
  for env in jc3636w518c waveshare_146; do
    "$pio" run -e "$env"
  done
fi

if $ios; then
  step "iOS: build and XCTests on a simulator"
  # The project targets devices only; allow the simulator for this run.
  # Building through xcodebuild keeps the account dart-defines in
  # Generated.xcconfig (a plain `flutter build` would clear them).
  (cd moto_nav_bridge/ios && xcodebuild test -quiet \
    -workspace Runner.xcworkspace -scheme Runner \
    -destination "platform=iOS Simulator,name=${IOS_SIMULATOR:-iPhone 17 Pro}" \
    -derivedDataPath "${TMPDIR:-/tmp}/navio-ios-check" \
    SUPPORTED_PLATFORMS="iphoneos iphonesimulator" CODE_SIGNING_ALLOWED=NO)
fi

step "All checks passed"
