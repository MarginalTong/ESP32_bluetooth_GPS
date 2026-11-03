#pragma once
#include <stdint.h>

// Panel pixels, not the NAVIO logical canvas. Deliberately no fonts or AA.
constexpr uint16_t panelTestPixel(unsigned stage, unsigned x, unsigned y) {
  if (stage == 0) return 0x0000;
  if (stage == 1) return 0xFFFF;
  if (stage == 2) return 0xF800;
  if (stage == 3) return 0x07E0;
  if (stage == 4) return 0x001F;
  // White 1px grid at 30px intervals, with a red center cross. The center
  // square is 60x60; all visible line segments should be straight and intact.
  if (x == 180 || y == 180) return 0xF800;
  if ((x >= 150 && x <= 210 && (y == 150 || y == 210)) ||
      (y >= 150 && y <= 210 && (x == 150 || x == 210))) return 0xFFFF;
  return x % 30 == 0 || y % 30 == 0 ? 0xFFFF : 0x0000;
}
