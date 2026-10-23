#!/usr/bin/env bash
# Renders the round panel's map the old and new way side by side (PPM).
# Usage: bash firmware/tests/run_route_render_preview.sh [out.ppm]
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-route_preview.ppm}"
binary=$(mktemp "${TMPDIR:-/tmp}/route-render-preview.XXXXXX")
trap 'rm -f "$binary"' EXIT
awk '
  BEGIN { print "#include <stddef.h>\n#include <stdint.h>\n#include <string.h>\n#include <math.h>" }
  FNR == NR {
    if (/^\/\/ BEGIN ROUTE RENDER/) copying = 1;
    if (copying) print;
    if (/^\/\/ END ROUTE RENDER/) copying = 0;
    next;
  }
  { print }
' firmware/esp32_nav_display/esp32_nav_display.ino firmware/tests/route_render_preview.cpp |
  "${CXX:-clang++}" -x c++ -std=c++11 -O2 -Wall -Wextra -Werror - -o "$binary"
"$binary" "$out"
