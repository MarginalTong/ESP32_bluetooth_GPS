// The runner compiles the actual ROUTE RENDER block before this test.
#include <stdio.h>
#include <stdlib.h>
#include <vector>

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

int main() {
  constexpr int size = 412, guard = 32;
  std::vector<uint8_t> memory(size * size + guard * 2, 0x5a);
  GrayLayer layer;
  layer.pixels = memory.data() + guard;
  layer.width = layer.height = layer.clipBottom = size;

  const auto binary = [&]() {
    int ink = 0, background = 0;
    for (int index = 0; index < size * size; ++index) {
      check(layer.pixels[index] == 0 || layer.pixels[index] == 255,
            "text/shape edges must contain no anti-aliasing gray pixels");
      ink += layer.pixels[index] == 255;
      background += layer.pixels[index] == 0;
    }
    check(ink > 0 && background > 0, "drawing must produce visible ink and background");
  };

  layer.clear();
  layer.strokeSegment(-10.3f, 15.2f, 370.7f, 205.4f, 2.4f, 255);
  binary();

  layer.clear();
  layer.fillRoundRect(30.2f, 40.7f, 95.4f, 105.6f, 11.3f, 255);
  binary();

  layer.clear();
  layer.fillTriangle(13.2f, 20.8f, 86.7f, 135.4f, 173.1f, 12.9f, 255);
  binary();
  layer.fillTriangle(20.5f, 24.3f, 80.1f, 115.8f, 155.3f, 19.7f, 0);
  binary();

  // A 4-bit source mask is thresholded once, rather than bilinearly blended.
  const NavoNumericGlyph glyphs[] = {{'X', 2, 1, 0, 0, 2, 0}};
  const uint8_t alpha[] = {0x78};
  const AlphaFont testFont = {glyphs, 1, alpha, 1};
  layer.clear();
  layer.drawText(testFont, "X", 0, 0, 1, 255);
  check(layer.pixels[0] == 0 && layer.pixels[1] == 255,
        "half-covered source pixels choose ink/background without smoothing");
  binary();

  layer.clear();
  layer.drawText(NAVO_NUMERIC_FONT, "00:10", 12.3f, 100.7f, 0.8f, 255);
  layer.drawText(NAVO_TEXT_FONT, "NAVO", 18.4f, 180.2f, 0.85f, 255);
  layer.drawText(NAVO_TEXT_FONT, "CONNECT PHONE", 16.1f, 220.8f, 0.2f, 255);
  binary();
  const float advance = NAVO_NUMERIC_FONT.textWidth("00:10", 0.8f);
  check(advance > 0 && advance < size, "existing font metrics still fit the native panel");

  layer.clear();
  layer.clipBottom = 100;
  layer.strokeSegment(15, 80, 140, 135, 3, 255);
  layer.drawText(NAVO_TEXT_FONT, "NAVO", 20, 120, 0.8f, 255);
  binary();
  for (int y = 100; y < size; ++y)
    for (int x = 0; x < size; ++x)
      check(layer.pixels[y * size + x] == 0, "map/text clipping protects the instruction area");
  layer.clipBottom = size;

  // Longitudinal fading is a road style, not anti-aliasing across an edge.
  layer.clear();
  layer.strokeFadingRails(20, 50, 1, 0, 100, 3, 2, 245);
  check(layer.pixels[46 * size + 25] == 245 && layer.pixels[47 * size + 25] == 245,
        "each rail has a flat, hard-edged cross section");
  check(layer.pixels[45 * size + 25] == 0 && layer.pixels[48 * size + 25] == 0,
        "no soft fringe outside the rail");
  const uint8_t faded = layer.pixels[47 * size + 110];
  check(faded > 0 && faded < 245, "the far end of a side road still fades");

  layer.clear();
  layer.fillTriangle(-100, -10, 50, 500, 520, 40, 255);
  layer.fillRoundRect(-20, -20, 25, 25, 5, 255);
  layer.drawText(NAVO_TEXT_FONT, "NAVO", -20, 8, 0.8f, 255);
  for (int index = 0; index < guard; ++index) {
    check(memory[index] == 0x5a && memory[memory.size() - 1 - index] == 0x5a,
          "off-screen shapes/text must not write outside the framebuffer");
  }
  puts("hard-edge rendering: binary edges, font masks, clipping and rail fade passed");
}
