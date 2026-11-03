#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/panel-init-test.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror \
  -Ifirmware/platformio firmware/tests/panel_init_test.cpp -o "$binary"
"$binary"
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror \
  -Ifirmware/platformio firmware/tests/panel_pattern_test.cpp -o "$binary"
"$binary"
