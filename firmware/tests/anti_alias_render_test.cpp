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

  const auto antialiased = [&](bool requireSolid = true) {
    int ink = 0, background = 0, edge = 0;
    for (int index = 0; index < size * size; ++index) {
      ink += layer.pixels[index] == 255;
      background += layer.pixels[index] == 0;
      edge += layer.pixels[index] > 0 && layer.pixels[index] < 255;
    }
    check(background > 0 && edge > 0, "text/shapes must have partially covered edge pixels");
    check(!requireSolid || ink > 0, "anti-aliasing must keep solid interiors crisp");
  };

  layer.clear();
  layer.strokeSegment(-10.3f, 15.2f, 370.7f, 205.4f, 2.4f, 255);
  antialiased();

  layer.clear();
  layer.fillRoundRect(30.2f, 40.7f, 95.4f, 105.6f, 11.3f, 255);
  antialiased();

  layer.clear();
  layer.fillTriangle(13.2f, 20.8f, 86.7f, 135.4f, 173.1f, 12.9f, 255);
  antialiased();
  layer.fillTriangle(20.5f, 24.3f, 80.1f, 115.8f, 155.3f, 19.7f, 0);
  antialiased();

  // Keep fractional coverage from a 4-bit font mask instead of thresholding
  // it to binary ink/background. This fails with the no-AA experiment.
  const NavioNumericGlyph glyphs[] = {{'X', 2, 1, 0, 0, 2, 0}};
  const uint8_t alpha[] = {0x78};
  const AlphaFont testFont = {glyphs, 1, alpha, 1};
  layer.clear();
  layer.drawText(testFont, "X", 0, 0, 1, 255);
  check(layer.pixels[0] > 0 && layer.pixels[0] < 255 &&
        layer.pixels[1] > 0 && layer.pixels[1] < 255,
        "partially covered source pixels remain antialiased");
  antialiased(false);

  layer.clear();
  layer.drawText(NAVIO_NUMERIC_FONT, "00:10", 12.3f, 100.7f, 0.8f, 255);
  layer.drawText(NAVIO_TEXT_FONT, "NAVIO", 18.4f, 180.2f, 0.85f, 255);
  layer.drawText(NAVIO_TEXT_FONT, "CONNECT PHONE", 16.1f, 220.8f, 0.2f, 255);
  antialiased();
  const float advance = NAVIO_NUMERIC_FONT.textWidth("00:10", 0.8f);
  check(advance > 0 && advance < size, "existing font metrics still fit the native panel");

  layer.clear();
  layer.clipBottom = 100;
  layer.strokeSegment(15, 80, 140, 135, 3, 255);
  layer.drawText(NAVIO_TEXT_FONT, "NAVIO", 20, 120, 0.8f, 255);
  antialiased();
  for (int y = 100; y < size; ++y)
    for (int x = 0; x < size; ++x)
      check(layer.pixels[y * size + x] == 0, "map/text clipping protects the instruction area");
  layer.clipBottom = size;

  // Rails have smooth cross-section edges as well as an along-road fade.
  layer.clear();
  layer.strokeFadingRails(20, 50, 1, 0, 100, 3, 2, 245);
  const uint8_t near = layer.pixels[46 * size + 25];
  const uint8_t edge = layer.pixels[45 * size + 25];
  check(near > 0 && near < 245 && edge > 0 && edge < near &&
        layer.pixels[44 * size + 25] == 0,
        "side roads have antialiased edges within bounded rail widths");
  const uint8_t faded = layer.pixels[47 * size + 110];
  check(faded > 0 && faded < near, "the far end of a side road still fades");

  layer.clear();
  layer.fillTriangle(-100, -10, 50, 500, 520, 40, 255);
  layer.fillRoundRect(-20, -20, 25, 25, 5, 255);
  layer.drawText(NAVIO_TEXT_FONT, "NAVIO", -20, 8, 0.8f, 255);
  for (int index = 0; index < guard; ++index) {
    check(memory[index] == 0x5a && memory[memory.size() - 1 - index] == 0x5a,
          "off-screen shapes/text must not write outside the framebuffer");
  }
  // The panel stays 412px while the AA raster can be smaller. Exercise both
  // native and experimental paths with exact-sized input and guarded output.
  for (const int raster : {412, 360}) {
    std::vector<uint8_t> small(raster * raster);
    for (int y = 0; y < raster; ++y)
      for (int x = 0; x < raster; ++x)
        small[y * raster + x] = uint8_t((x + y * 3) % 256);
    GrayLayer scaled;
    scaled.pixels = small.data();
    scaled.width = scaled.height = scaled.clipBottom = raster;
    PanelComposer composer;
    composer.init(size, size, 240, 240, size / 2.f, size / 2.f, size / 2.f - 3,
                  raster, raster);
    std::vector<uint16_t> canvas(240 * 240, 0);
    canvas[120 * 240 + 120] = 0xf800;
    constexpr int bandRows = 16;
    std::vector<uint16_t> band(size * bandRows + guard * 2, 0xa55a);
    for (int first = 0; first < size; first += bandRows) {
      const int rows = first + bandRows <= size ? bandRows : size - first;
      composer.compose(canvas.data(), &scaled, band.data() + guard, first, rows);
      for (int y = first; y < first + rows; ++y)
        for (int x = 0; x < size; ++x) {
          const bool visible = x >= composer.spanStart[y] && x < composer.spanEnd[y];
          const uint16_t ui = canvas[(y * 240 / size) * 240 + x * 240 / size];
          const uint8_t g = small[(y * raster / size) * raster + x * raster / size];
          const uint16_t expected = !visible ? 0 : ui != 0 ? ui : composer.gray565[g];
          check(band[guard + (y - first) * size + x] == expected,
                "scaled bands preserve UI overlay, grayscale, circle and full panel coverage");
        }
      for (int index = 0; index < guard; ++index)
        check(band[index] == 0xa55a && band[band.size() - 1 - index] == 0xa55a,
              "band composition stays within the output buffer");
    }
    composer.compose(canvas.data(), nullptr, band.data() + guard, 0, bandRows);
    for (int i = 0; i < size * bandRows; ++i)
      check(band[guard + i] == 0, "missing AA layer retains canvas-only fallback");
    scaled.width = 1;
    composer.compose(canvas.data(), &scaled, band.data() + guard, 0, bandRows);
    for (int i = 0; i < size * bandRows; ++i)
      check(band[guard + i] == 0, "mismatched layers are not read out of bounds");
  }
  puts("anti-alias rendering: smooth edges, solid interiors, font masks, clipping and rail fade passed");
  puts("panel composition: 412/360 rasters, band boundaries, UI overlay and fallback passed");
}
