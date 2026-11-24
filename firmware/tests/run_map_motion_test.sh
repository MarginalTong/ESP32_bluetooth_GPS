#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/map-motion-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
for test in map_motion junction_motion; do
  "${CXX:-clang++}" -std=c++11 -Wall -Wextra -Werror -Ifirmware/platformio \
    "firmware/tests/${test}_test.cpp" -o "$binary"
  "$binary"
done
