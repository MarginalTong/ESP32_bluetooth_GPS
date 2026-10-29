#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/anti-alias-render.XXXXXX")
trap 'rm -f "$binary"' EXIT
awk '
  BEGIN { print "#include <stddef.h>\n#include <stdint.h>\n#include <string.h>\n#include <math.h>\n#include \"numeric_font.h\"\n#include \"text_font.h\"" }
  FNR == NR {
    if (/^\/\/ BEGIN ROUTE RENDER/) copying = 1;
    if (copying) print;
    if (/^\/\/ END ROUTE RENDER/) copying = 0;
    next;
  }
  { print }
' firmware/esp32_nav_display/esp32_nav_display.ino firmware/tests/anti_alias_render_test.cpp |
  "${CXX:-clang++}" -x c++ -std=c++11 -O2 -Wall -Wextra -Werror \
    -Ifirmware/esp32_nav_display - -o "$binary"
"$binary"
