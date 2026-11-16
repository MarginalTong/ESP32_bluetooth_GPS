#pragma once

// Text drawn once and reused, shared by the firmware and the host test
// (text_cache_test). Rasterizing text is the most expensive drawing on the
// panel, and the same few strings ("350", "m", the clock) are drawn again on
// every frame of a map animation; copying a kept bitmap costs almost nothing.
#include <stdlib.h>
#include <string.h>

#include "gray_layer.h"

struct TextCache {
  // The strings one screen shows at a time, plus the blinking "NOW".
  static constexpr uint8_t kEntries = 6;
  // Longest cached string, with its terminator; longer text is drawn directly.
  static constexpr uint8_t kMaxText = 20;
  // Largest kept bitmap, in pixels (bytes): the full-width clock is ~25 000.
  static constexpr uint32_t kMaxPixels = 48000;

  struct Entry {
    const AlphaFont* font = nullptr;
    char text[kMaxText] = "";
    float x = 0, baseline = 0, scale = 0;
    uint8_t level = 0;
    // Layer position and size of the bitmap.
    int16_t left = 0, top = 0, width = 0, height = 0;
    uint8_t* pixels = nullptr;
    uint32_t lastUsed = 0;
  };
  Entry entries[kEntries];
  uint32_t uses = 0;
  uint32_t rasterized = 0;  // times text had to be drawn from the font

  ~TextCache() {
    for (Entry& entry : entries) free(entry.pixels);
  }

  // Same result as layer.drawText() with the same arguments.
  void draw(GrayLayer& layer, const AlphaFont& font, const char* text, float x,
            float baseline, float scale, uint8_t level) {
    Entry* entry = find(font, text, x, baseline, scale, level);
    if (entry == nullptr) entry = render(font, text, x, baseline, scale, level);
    if (entry == nullptr) {
      ++rasterized;
      layer.drawText(font, text, x, baseline, scale, level);
      return;
    }
    entry->lastUsed = ++uses;
    blend(*entry, layer);
  }

 private:
  Entry* find(const AlphaFont& font, const char* text, float x, float baseline,
              float scale, uint8_t level) {
    for (Entry& entry : entries) {
      if (entry.pixels != nullptr && entry.font == &font && entry.x == x &&
          entry.baseline == baseline && entry.scale == scale &&
          entry.level == level && strcmp(entry.text, text) == 0)
        return &entry;
    }
    return nullptr;
  }

  // The whole pixels the text can touch, as drawText() bounds each glyph.
  static bool extent(const AlphaFont& font, const char* text, float x, float baseline,
                     float scale, Entry& box) {
    float left = 0, right = 0, top = 0, bottom = 0;
    bool any = false;
    for (const char* c = text; *c != '\0'; ++c) {
      const NavioNumericGlyph* glyph = font.glyphFor(*c);
      if (glyph == nullptr) continue;
      const float x0 = x + glyph->xOffset * scale, y0 = baseline + glyph->yOffset * scale;
      const float x1 = x0 + glyph->width * scale, y1 = y0 + glyph->height * scale;
      left = any ? fminf(left, x0) : x0;
      right = any ? fmaxf(right, x1) : x1;
      top = any ? fminf(top, y0) : y0;
      bottom = any ? fmaxf(bottom, y1) : y1;
      any = true;
      x += glyph->advance * scale;
    }
    // Far outside any panel: not worth keeping, and unsafe to convert.
    if (!any || !(left > -4000.0f && right < 4000.0f && top > -4000.0f && bottom < 4000.0f))
      return false;
    box.left = int16_t(floorf(left - 1.0f));
    box.top = int16_t(floorf(top - 1.0f));
    box.width = int16_t(int16_t(ceilf(right + 1.0f)) - box.left + 1);
    box.height = int16_t(int16_t(ceilf(bottom + 1.0f)) - box.top + 1);
    return true;
  }

  Entry* render(const AlphaFont& font, const char* text, float x, float baseline,
                float scale, uint8_t level) {
    Entry fresh;
    if (!(scale > 0.0f) || strlen(text) >= kMaxText ||
        !extent(font, text, x, baseline, scale, fresh))
      return nullptr;
    const size_t bytes = size_t(fresh.width) * fresh.height;
    if (bytes > kMaxPixels) return nullptr;
    Entry* slot = &entries[0];
    for (Entry& entry : entries) {
      if (entry.pixels == nullptr) {
        slot = &entry;
        break;
      }
      if (entry.lastUsed < slot->lastUsed) slot = &entry;
    }
    free(slot->pixels);
    slot->pixels = nullptr;
    fresh.pixels = static_cast<uint8_t*>(calloc(bytes, 1));
    if (fresh.pixels == nullptr) return nullptr;
    fresh.font = &font;
    strcpy(fresh.text, text);
    fresh.x = x;
    fresh.baseline = baseline;
    fresh.scale = scale;
    fresh.level = level;
    GrayLayer bitmap;
    bitmap.pixels = fresh.pixels;
    bitmap.width = fresh.width;
    bitmap.height = bitmap.clipBottom = fresh.height;
    bitmap.drawText(font, text, x - fresh.left, baseline - fresh.top, scale, level);
    ++rasterized;
    *slot = fresh;
    return slot;
  }

  // Lighten blend, clipped like every GrayLayer drawing.
  static void blend(const Entry& entry, GrayLayer& layer) {
    if (layer.pixels == nullptr) return;
    const int firstX = entry.left < 0 ? -entry.left : 0;
    const int endX = entry.left + entry.width > layer.width ? layer.width - entry.left
                                                            : entry.width;
    for (int row = 0; row < entry.height; ++row) {
      const int y = entry.top + row;
      if (y < 0 || y >= layer.clipBottom) continue;
      const uint8_t* from = entry.pixels + size_t(row) * entry.width;
      uint8_t* to = layer.pixels + size_t(y) * layer.width + entry.left;
      for (int x = firstX; x < endX; ++x)
        if (from[x] > to[x]) to[x] = from[x];
    }
  }
};
