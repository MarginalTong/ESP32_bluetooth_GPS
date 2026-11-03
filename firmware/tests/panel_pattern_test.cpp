#include "panel_test_pattern.h"
#include <cassert>
#include <cstdio>

int main() {
  const uint16_t fills[] = {0x0000, 0xFFFF, 0xF800, 0x07E0, 0x001F};
  for (unsigned s = 0; s < 5; ++s)
    for (unsigned y = 0; y < 360; ++y)
      for (unsigned x = 0; x < 360; ++x)
        assert(panelTestPixel(s, x, y) == fills[s]);
  for (unsigned i = 0; i < 360; ++i) {
    assert(panelTestPixel(5, 180, i) == 0xF800);
    assert(panelTestPixel(5, i, 180) == 0xF800);
  }
  assert(panelTestPixel(5, 151, 151) == 0);
  assert(panelTestPixel(5, 150, 151) == 0xFFFF);
  assert(panelTestPixel(5, 210, 151) == 0xFFFF);
  assert(panelTestPixel(5, 11, 30) == 0xFFFF);
  std::puts("Panel diagnostic: 648,000 solid pixels + grid/cross geometry passed");
}
