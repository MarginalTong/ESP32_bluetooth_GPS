#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/anti-alias-render.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++11 -O2 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/anti_alias_render_test.cpp -o "$binary"
"$binary"
