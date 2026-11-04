#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/side-road-ray.XXXXXX")
trap 'rm -f "$binary"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Werror -Ifirmware/platformio \
  firmware/tests/side_road_ray_test.cpp -o "$binary"
"$binary"
