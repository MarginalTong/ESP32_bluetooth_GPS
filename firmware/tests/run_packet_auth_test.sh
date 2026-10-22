#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/packet-auth-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
awk '
  BEGIN { print "#include <stddef.h>\n#include <stdint.h>\n#include <string.h>" }
  FNR == NR {
    if (/^\/\/ BEGIN PACKET AUTH/) copying = 1;
    if (copying) print;
    if (/^\/\/ END PACKET AUTH/) copying = 0;
    next;
  }
  { print }
' firmware/esp32_nav_display/esp32_nav_display.ino firmware/tests/packet_auth_test.cpp |
  "${CXX:-clang++}" -x c++ -std=c++11 -Wall -Wextra -Werror - -o "$binary"
"$binary"
