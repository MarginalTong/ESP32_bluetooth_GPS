#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/map-motion-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++11 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/map_motion_test.cpp -o "$binary"
"$binary"
