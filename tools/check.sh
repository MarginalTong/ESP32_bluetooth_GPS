#!/usr/bin/env bash
# One command for every local check. Run it before each commit.
# Usage: bash tools/check.sh [--firmware-build]
#   --firmware-build  also compile every PlatformIO environment (slow).
# It never uploads firmware or installs the app.
set -euo pipefail
cd "$(dirname "$0")/.."

build=false
[[ "${1:-}" == "--firmware-build" ]] && build=true

step() { printf '\n== %s\n' "$*"; }

step "App: static analysis"
(cd moto_nav_bridge && flutter analyze)

step "App: tests"
(cd moto_nav_bridge && flutter test --timeout 60s)

step "Firmware: host tests"
for test in packet_auth panel_init ui_state map_motion anti_alias_render; do
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

step "All checks passed"
