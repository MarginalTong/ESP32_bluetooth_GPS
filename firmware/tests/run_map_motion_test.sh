#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/map-motion-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
awk '
  BEGIN { print "#include <stdint.h>\n#include <math.h>" }
  FNR == NR {
    if (/^\/\/ BEGIN MAP MOTION/) copying = 1;
    if (copying) print;
    if (/^\/\/ END MAP MOTION/) copying = 0;
    next;
  }
  { print }
' firmware/esp32_nav_display/esp32_nav_display.ino firmware/tests/map_motion_test.cpp |
  "${CXX:-clang++}" -x c++ -std=c++11 -Wall -Wextra -Werror - -o "$binary"
"$binary"
