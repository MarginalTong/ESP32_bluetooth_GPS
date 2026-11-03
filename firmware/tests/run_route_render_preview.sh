#!/usr/bin/env bash
# Renders the round panel's screen the old and new way side by side (PPM).
# Usage: bash firmware/tests/run_route_render_preview.sh [out.ppm [standby.ppm]]
# Without arguments the image goes to $TMPDIR, never into the repository.
# Needs the Adafruit GFX library (fonts); set ADAFRUIT_GFX_DIR if it is not
# in the default Arduino libraries folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-${TMPDIR:-/tmp}/route_preview.ppm}"
gfx="${ADAFRUIT_GFX_DIR:-$HOME/Documents/Arduino/libraries/Adafruit_GFX_Library}"
work=$(mktemp -d "${TMPDIR:-/tmp}/route-render-preview.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The font headers include <Adafruit_GFX.h>; on the host it only needs to
# provide the font structs.
printf '#pragma once\n#include <stdint.h>\n#define PROGMEM\n#include "gfxfont.h"\n' \
  > "$work/Adafruit_GFX.h"
awk '
  BEGIN { print "#include <stddef.h>\n#include <stdint.h>\n#include <string.h>\n#include <math.h>\n#include <Adafruit_GFX.h>\n#include \"numeric_font.h\"\n#include \"text_font.h\"" }
  FNR == NR {
    if (/^\/\/ BEGIN ROUTE RENDER/) copying = 1;
    if (copying) print;
    if (/^\/\/ END ROUTE RENDER/) copying = 0;
    next;
  }
  { print }
' firmware/esp32_nav_display/esp32_nav_display.ino firmware/tests/route_render_preview.cpp |
  "${CXX:-clang++}" -x c++ -std=c++11 -O2 -Wall -Wextra -Werror -I"$work" -I"$gfx" -Ifirmware/esp32_nav_display - \
    -o "$work/preview"
"$work/preview" "$out" ${2:+"$2"}
