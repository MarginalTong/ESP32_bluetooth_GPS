#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/ui-state-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
for round in 1 0; do
  "${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror \
    -DNAV_WAVESHARE_146="$round" -Ifirmware/platformio \
    firmware/platformio/ui_state.cpp firmware/platformio/ui_screens.cpp \
    firmware/tests/ui_state_test.cpp -o "$binary"
  "$binary"
done
