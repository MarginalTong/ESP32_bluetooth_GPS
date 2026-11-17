#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/instrument-clock-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/instrument_clock_test.cpp -o "$binary"
"$binary" "$@"
