#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "gray_layer.h"

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

// The plain definitions the optimized drawing must keep matching: a stroke
// is every pixel within its half width of the segment, text is the average
// of bilinear samples of the font mask.
static float referenceStroke(float px, float py, float ax, float ay, float bx, float by,
                             float halfWidth) {
  const float dx = bx - ax, dy = by - ay, lengthSquared = dx * dx + dy * dy;
  float t = lengthSquared > 0 ? ((px - ax) * dx + (py - ay) * dy) / lengthSquared : 0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  const float ex = px - (ax + t * dx), ey = py - (ay + t * dy);
  return GrayLayer::clamp01(halfWidth + 0.5f - sqrtf(ex * ex + ey * ey));
}

static float referenceGlyph(const AlphaFont& font, const NavioNumericGlyph& glyph,
                            float x, float y) {
  const int ix = int(floorf(x)), iy = int(floorf(y));
  const float fx = x - ix, fy = y - iy;
  const float upper = font.level(glyph, ix, iy) * (1 - fx) + font.level(glyph, ix + 1, iy) * fx;
  const float lower =
      font.level(glyph, ix, iy + 1) * (1 - fx) + font.level(glyph, ix + 1, iy + 1) * fx;
  return (upper * (1 - fy) + lower * fy) / 15.0f;
}

static void checkAgainstReferences(GrayLayer& layer, int size) {
  // Steep, shallow, vertical, horizontal, degenerate and partly off-screen.
  const float strokes[][5] = {
      {20.3f, 30.7f, 300.2f, 380.9f, 5.25f}, {390.5f, 12.1f, 40.8f, 60.4f, 2.4f},
      {100.5f, -30, 100.5f, 200, 3.75f},     {-25, 150.2f, 430, 150.2f, 0.3f},
      {200, 200, 200, 200, 6},               {350, 400, 450, 300, 4}};
  for (const auto& s : strokes) {
    layer.clear();
    layer.strokeSegment(s[0], s[1], s[2], s[3], s[4], 255);
    for (int y = 0; y < size; ++y)
      for (int x = 0; x < size; ++x) {
        const int expected = int(
            255 * referenceStroke(x + 0.5f, y + 0.5f, s[0], s[1], s[2], s[3], s[4]) + 0.5f);
        check(abs(layer.pixels[y * size + x] - expected) <= 1,
              "a stroke covers exactly the pixels within its half width");
      }
    // A fading ray never draws outside the same stroke, nor skips its middle.
    const float dx = s[2] - s[0], dy = s[3] - s[1], length = sqrtf(dx * dx + dy * dy);
    if (length <= 0) continue;
    layer.clear();
    layer.strokeFadingRay(s[0], s[1], dx / length, dy / length, length, s[4], 200);
    const int middleX = int(s[0] + dx * 0.25f), middleY = int(s[1] + dy * 0.25f);
    for (int y = 0; y < size; ++y)
      for (int x = 0; x < size; ++x) {
        const float inside =
            referenceStroke(x + 0.5f, y + 0.5f, s[0], s[1], s[2], s[3], s[4]);
        check(inside > 0 || layer.pixels[y * size + x] == 0, "a ray stays inside its stroke");
      }
    if (middleX >= 0 && middleX < size && middleY >= 0 && middleY < size && s[4] >= 1)
      check(layer.pixels[middleY * size + middleX] > 0, "a ray is drawn along its whole arm");
  }

  // Shrunk (the distance digits), tiny (6 samples per axis) and enlarged.
  const float scales[] = {42.0f / 79, 0.15f, 1.2f};
  for (const float scale : scales) {
    const float x = 30.4f, baseline = 200.6f;
    layer.clear();
    layer.drawText(NAVIO_NUMERIC_FONT, "8", x, baseline, scale, 255);
    const NavioNumericGlyph& glyph = *NAVIO_NUMERIC_FONT.glyphFor('8');
    const float x0 = x + glyph.xOffset * scale, y0 = baseline + glyph.yOffset * scale;
    const int steps = scale >= 0.5f ? 2 : (scale <= 1.0f / 6 ? 6 : int(ceilf(1.0f / scale)));
    int ink = 0;
    for (int y = 0; y < size; ++y)
      for (int px = 0; px < size; ++px) {
        float sum = 0;
        for (int sy = 0; sy < steps; ++sy)
          for (int sx = 0; sx < steps; ++sx)
            sum += referenceGlyph(NAVIO_NUMERIC_FONT, glyph,
                                  (px + (sx + 0.5f) / steps - x0) / scale - 0.5f,
                                  (y + (sy + 0.5f) / steps - y0) / scale - 0.5f);
        const int expected = int(255 * sum / (steps * steps) + 0.5f);
        ink += expected > 0;
        // Fixed-point sampling: within 2 gray levels of 255.
        check(abs(layer.pixels[y * size + px] - expected) <= 2,
              "text is the average of bilinear font samples");
      }
    check(ink > 20, "the reference glyph is on screen");
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

  // A side road is one soft line, brightest at the junction, fading out.
  layer.clear();
  layer.strokeFadingRay(20, 50, 1, 0, 100, 1.5f, 90);
  const uint8_t junction = layer.pixels[50 * size + 21];
  const uint8_t middle = layer.pixels[50 * size + 70];
  const uint8_t tail = layer.pixels[50 * size + 118];
  check(junction >= 85 && junction <= 90, "a side road starts at its dark gray peak");
  check(middle > 0 && middle < junction && tail < middle,
        "a side road fades steadily towards its tail");
  check(layer.pixels[50 * size + 121] == 0, "nothing is drawn past the tail");
  const uint8_t edge = layer.pixels[48 * size + 21];
  check(edge > 0 && edge < junction && layer.pixels[47 * size + 21] == 0,
        "a side road has an antialiased edge and a bounded width");
  check(layer.pixels[50 * size + 19] == 0, "nothing is drawn behind the junction");

  checkAgainstReferences(layer, size);

  // A flat background covers exactly its rows, clipped to the layer.
  layer.clear();
  layer.fillRows(400, 500, 28);
  layer.fillRows(-5, 2, 9);
  check(layer.pixels[399 * size + 7] == 0 && layer.pixels[400 * size] == 28 &&
            layer.pixels[size * size - 1] == 28 && layer.pixels[size + 3] == 9 &&
            layer.pixels[2 * size] == 0,
        "a row fill covers whole rows and nothing else");

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
  puts("anti-alias rendering: smooth edges, solid interiors, font masks, clipping, side-road fade\n"
       "and stroke/text reference match passed");
  puts("panel composition: 412/360 rasters, band boundaries, UI overlay and fallback passed");
}
