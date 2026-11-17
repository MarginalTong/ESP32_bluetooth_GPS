#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/speed-limit-sign-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++11 -O2 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/speed_limit_sign_test.cpp -o "$binary"
"$binary"
