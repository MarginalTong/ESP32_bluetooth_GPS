#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/ui-state-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
for board in waveshare legacy jc3636w518c; do
  case "$board" in
    waveshare) flags=(-DNAV_WAVESHARE_146=1) ;;
    legacy) flags=(-DNAV_WAVESHARE_146=0) ;;
    jc3636w518c) flags=(-DNAV_WAVESHARE_146=0 -DNAV_JC3636W518C=1) ;;
  esac
  "${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror \
    "${flags[@]}" -Ifirmware/platformio firmware/tests/board_config_test.cpp -o "$binary"
  "$binary"
  "${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror \
    "${flags[@]}" -Ifirmware/platformio \
    firmware/platformio/ui_state.cpp firmware/platformio/ui_screens.cpp \
    firmware/tests/ui_state_test.cpp -o "$binary"
  "$binary"
done
