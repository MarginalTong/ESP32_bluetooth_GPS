#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/text-cache-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++11 -O2 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/text_cache_test.cpp -o "$binary"
"$binary"
