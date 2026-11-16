#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "text_cache.h"

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

constexpr int kSize = 360, kGuard = 64;

struct Surface {
  std::vector<uint8_t> memory = std::vector<uint8_t>(kSize * kSize + kGuard * 2, 0x5a);
  GrayLayer layer;
  Surface() {
    layer.pixels = memory.data() + kGuard;
    layer.width = layer.height = layer.clipBottom = kSize;
    layer.clear();
  }
  bool guardsIntact() const {
    for (int i = 0; i < kGuard; ++i)
      if (memory[i] != 0x5a || memory[memory.size() - 1 - i] != 0x5a) return false;
    return true;
  }
};

// Largest difference, in gray levels, between two layers.
static int difference(const Surface& a, const Surface& b) {
  int worst = 0;
  for (int i = 0; i < kSize * kSize; ++i) {
    const int d = abs(a.layer.pixels[i] - b.layer.pixels[i]);
    if (d > worst) worst = d;
  }
  return worst;
}

int main() {
  // The distance text of the round panel: size 4 at 1.5 native pixels.
  const float scale = 42.0f / NAVIO_NUMERIC_FONT.capHeight;
  TextCache cache;

  {
    Surface direct, cached, again;
    direct.layer.drawText(NAVIO_NUMERIC_FONT, "350", 150.4f, 298.5f, scale, 255);
    cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 150.4f, 298.5f, scale, 255);
    // The bitmap is drawn at a whole-pixel offset, so only float rounding
    // may differ: one gray level of 255.
    check(difference(direct, cached) <= 1, "cached text looks like directly drawn text");
    check(cache.rasterized == 1, "the first draw rasterizes the text");
    cache.draw(again.layer, NAVIO_NUMERIC_FONT, "350", 150.4f, 298.5f, scale, 255);
    check(cache.rasterized == 1, "the same text is not rasterized again");
    check(difference(cached, again) == 0, "a reused bitmap draws the same pixels");
  }

  {
    Surface changed, direct;
    cache.draw(changed.layer, NAVIO_NUMERIC_FONT, "340", 150.4f, 298.5f, scale, 255);
    direct.layer.drawText(NAVIO_NUMERIC_FONT, "340", 150.4f, 298.5f, scale, 255);
    check(cache.rasterized == 2 && difference(direct, changed) <= 1,
          "different text is drawn fresh, not from another string's bitmap");
    cache.draw(changed.layer, NAVIO_NUMERIC_FONT, "340", 151.0f, 298.5f, scale, 255);
    check(cache.rasterized == 3, "the same text at another position is drawn fresh");
  }

  {
    // Text keeps the brighter of itself and what is under it, like drawText.
    Surface direct, cached;
    direct.layer.strokeSegment(100, 280, 300, 280, 6, 200);
    cached.layer.strokeSegment(100, 280, 300, 280, 6, 200);
    direct.layer.drawText(NAVIO_NUMERIC_FONT, "350", 150.4f, 298.5f, scale, 120);
    cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 150.4f, 298.5f, scale, 120);
    check(difference(direct, cached) <= 1, "cached text blends over the layer like drawn text");
  }

  {
    // Clipping follows the layer at draw time, not at the time of caching.
    Surface direct, cached;
    for (const int clip : {kSize, 285}) {
      direct.layer.clear();
      cached.layer.clear();
      direct.layer.clipBottom = cached.layer.clipBottom = clip;
      for (const float x : {-30.0f, 150.0f, 320.0f}) {
        direct.layer.drawText(NAVIO_NUMERIC_FONT, "350", x, 298.5f, scale, 255);
        cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", x, 298.5f, scale, 255);
      }
      check(difference(direct, cached) <= 1, "cached text is clipped like drawn text");
    }
    cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 150, -500, scale, 255);
    cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 150, 900, scale, 255);
    cache.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 1e9f, 100, scale, 255);
    check(cached.guardsIntact(), "off-screen cached text never writes outside the layer");
  }

  {
    // More strings than slots: the least recently used one is replaced.
    TextCache small;
    Surface surface;
    const char* texts[] = {"1", "2", "3", "4", "5", "6", "7"};
    for (const char* text : texts)
      small.draw(surface.layer, NAVIO_NUMERIC_FONT, text, 10, 100, scale, 255);
    check(small.rasterized == 7, "each new string is rasterized once");
    small.draw(surface.layer, NAVIO_NUMERIC_FONT, "7", 10, 100, scale, 255);
    small.draw(surface.layer, NAVIO_NUMERIC_FONT, "2", 10, 100, scale, 255);
    check(small.rasterized == 7, "recently used strings are still kept");
    small.draw(surface.layer, NAVIO_NUMERIC_FONT, "1", 10, 100, scale, 255);
    check(small.rasterized == 8, "the oldest string was dropped to make room");
  }

  {
    // Text that cannot be kept is still drawn.
    TextCache big;
    Surface direct, cached;
    const char* longText = "CONNECT PHONE CONNECT PHONE";
    direct.layer.drawText(NAVIO_TEXT_FONT, longText, 5, 100, 0.2f, 255);
    big.draw(cached.layer, NAVIO_TEXT_FONT, longText, 5, 100, 0.2f, 255);
    check(difference(direct, cached) == 0, "text too long to cache is drawn directly");
    direct.layer.clear();
    cached.layer.clear();
    direct.layer.drawText(NAVIO_NUMERIC_FONT, "00:10", 0, 300, 3.0f, 255);
    big.draw(cached.layer, NAVIO_NUMERIC_FONT, "00:10", 0, 300, 3.0f, 255);
    check(difference(direct, cached) == 0, "text too large to cache is drawn directly");
    big.draw(cached.layer, NAVIO_NUMERIC_FONT, "", 0, 300, 1.0f, 255);
    big.draw(cached.layer, NAVIO_NUMERIC_FONT, "350", 0, 300, 0.0f, 255);
    check(cached.guardsIntact(), "empty text and a zero scale are harmless");
  }

  puts("text cache: same pixels as direct drawing, reuse, clipping, eviction and fallbacks passed");
}
