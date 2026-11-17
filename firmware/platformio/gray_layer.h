#pragma once

// Anti-aliased drawing at the panel's native resolution, shared by the
// firmware and the host rendering tests (anti_alias_render_test,
// route_render_preview).
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "../esp32_nav_display/numeric_font.h"
#include "../esp32_nav_display/text_font.h"

// The UI is monochrome, so it is an 8-bit gray layer: 0 is black, 255
// white. Strokes use per-pixel distance coverage, which also gives round
// caps and joins.
// Text comes from fonts pre-rasterized with 4-bit coverage (numeric_font.h,
// text_font.h), larger than any on-screen use, so they are only scaled down.
struct AlphaFont {
  const NavioNumericGlyph* glyphs;
  size_t count;
  const uint8_t* alpha;
  float capHeight;  // height of 'H' (or a digit), in font pixels

  const NavioNumericGlyph* glyphFor(char c) const {
    for (size_t i = 0; i < count; ++i)
      if (glyphs[i].code == c) return &glyphs[i];
    return nullptr;
  }

  float textWidth(const char* text, float scale) const {
    float advance = 0.0f;
    for (const char* c = text; *c != '\0'; ++c) {
      const NavioNumericGlyph* glyph = glyphFor(*c);
      if (glyph != nullptr) advance += glyph->advance;
    }
    return advance * scale;
  }

  // 4-bit coverage of one font pixel, 0..15; 0 outside the glyph.
  uint32_t level(const NavioNumericGlyph& glyph, int x, int y) const {
    if (x < 0 || y < 0 || x >= glyph.width || y >= glyph.height) return 0;
    const uint32_t index = uint32_t(y) * glyph.width + x;
    const uint8_t packed = alpha[glyph.offset + index / 2];
    return index & 1 ? packed & 15 : packed >> 4;
  }

  // Bilinear sample at (x, y) in 16.16 fixed-point font pixels, as coverage
  // times kSampleOne. Integer only: the ESP32-S3 has no fast float divide or
  // floor, and text was most of a frame's drawing time with them.
  static constexpr uint32_t kSampleOne = 15u << 16;
  uint32_t sample(const NavioNumericGlyph& glyph, int32_t x, int32_t y) const {
    const int ix = x >> 16, iy = y >> 16;
    if (ix < -1 || iy < -1 || ix >= glyph.width || iy >= glyph.height) return 0;
    const uint32_t fx = (x >> 8) & 255, fy = (y >> 8) & 255;
    const uint32_t upper = level(glyph, ix, iy) * (256 - fx) + level(glyph, ix + 1, iy) * fx;
    const uint32_t lower =
        level(glyph, ix, iy + 1) * (256 - fx) + level(glyph, ix + 1, iy + 1) * fx;
    return upper * (256 - fy) + lower * fy;
  }
};

const AlphaFont NAVIO_NUMERIC_FONT = {
    NAVIO_NUMERIC_GLYPHS, sizeof(NAVIO_NUMERIC_GLYPHS) / sizeof(NAVIO_NUMERIC_GLYPHS[0]),
    NAVIO_NUMERIC_ALPHA, float(NAVIO_NUMERIC_CAP_HEIGHT)};
const AlphaFont NAVIO_TEXT_FONT = {
    NAVIO_TEXT_GLYPHS, sizeof(NAVIO_TEXT_GLYPHS) / sizeof(NAVIO_TEXT_GLYPHS[0]),
    NAVIO_TEXT_ALPHA, float(NAVIO_TEXT_CAP_HEIGHT)};

struct GrayLayer {
  uint8_t* pixels = nullptr;
  int16_t width = 0, height = 0;
  // Rows at and below this are never drawn (e.g. below the map).
  int16_t clipBottom = 0;

  static float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

  void clear() {
    if (pixels != nullptr) memset(pixels, 0, size_t(width) * height);
  }

  // Sets whole rows [top, bottom) to one level: a flat background to draw on.
  void fillRows(int16_t top, int16_t bottom, uint8_t level) {
    if (pixels == nullptr) return;
    if (top < 0) top = 0;
    if (bottom > height) bottom = height;
    if (top < bottom) memset(pixels + size_t(top) * width, level, size_t(bottom - top) * width);
  }

  // Pixel rows/columns a shape spanning [lo, hi] may touch, clipped. Clamped
  // before the integer conversion: a NaN or far off-screen coordinate gives
  // an empty range instead of an index outside the buffer.
  void bounds(float lo, float hi, int16_t limit, int16_t& first, int16_t& last) const {
    if (!(lo <= hi) || hi < 0.0f || lo >= limit) {
      first = 1;
      last = 0;
      return;
    }
    first = lo < 0.0f ? 0 : int16_t(floorf(lo));
    last = hi >= limit ? int16_t(limit - 1) : int16_t(ceilf(hi));
    if (last >= limit) last = limit - 1;
  }

  // Columns of pixel row `y` that a stroke from (ax, ay) along (dx, dy) can
  // touch: only the part of the stroke within `reach` rows of this one
  // matters. Keeps a diagonal stroke from visiting its whole bounding box.
  void rowSpan(int16_t y, float ax, float ay, float dx, float dy, float reach,
               int16_t& first, int16_t& last) const {
    float t0 = 0.0f, t1 = 1.0f;
    if (dy != 0.0f) {
      const float center = y + 0.5f - ay;
      t0 = clamp01((center - reach) / dy);
      t1 = clamp01((center + reach) / dy);
    }
    const float xa = ax + t0 * dx, xb = ax + t1 * dx;
    bounds(fminf(xa, xb) - reach, fmaxf(xa, xb) + reach, width, first, last);
  }

  // Lighten blend: keeps the brighter value, so the overlapping ends of a
  // polyline's segments never double their anti-aliased edges.
  void strokeSegment(float ax, float ay, float bx, float by, float halfWidth,
                     uint8_t level) {
    if (pixels == nullptr) return;
    const float reach = halfWidth + 1.0f;
    int16_t x0, x1, y0, y1;
    bounds(fminf(ay, by) - reach, fmaxf(ay, by) + reach, clipBottom, y0, y1);
    const float dx = bx - ax, dy = by - ay;
    const float lengthSquared = dx * dx + dy * dy;
    const float inverse = lengthSquared > 0.0f ? 1.0f / lengthSquared : 0.0f;
    // Squared distances decide the solid inside and the empty outside; only
    // the one-pixel edge band needs a square root.
    const float outer = halfWidth + 0.5f, inner = halfWidth - 0.5f;
    const float outerSquared = outer * outer;
    const float innerSquared = inner > 0.0f ? inner * inner : -1.0f;
    for (int16_t y = y0; y <= y1; ++y) {
      rowSpan(y, ax, ay, dx, dy, reach, x0, x1);
      uint8_t* row = pixels + size_t(y) * width;
      const float py = y + 0.5f - ay;
      for (int16_t x = x0; x <= x1; ++x) {
        const float px = x + 0.5f - ax;
        const float t = clamp01((px * dx + py * dy) * inverse);
        const float ex = px - t * dx, ey = py - t * dy;
        const float squared = ex * ex + ey * ey;
        if (squared >= outerSquared) continue;
        const uint8_t value = squared <= innerSquared
                                  ? level
                                  : uint8_t(level * (outer - sqrtf(squared)) + 0.5f);
        if (value > row[x]) row[x] = value;
      }
    }
  }

  // `xy` holds `count` points as x0,y0,x1,y1,...
  void strokePolyline(const float* xy, uint8_t count, float halfWidth, uint8_t level) {
    for (uint8_t i = 0; i + 1 < count; ++i)
      strokeSegment(xy[i * 2], xy[i * 2 + 1], xy[i * 2 + 2], xy[i * 2 + 3],
                    halfWidth, level);
  }

  // Gray level of a ray pixel `along` the arm and `distance` from its centre
  // line: full [peak] at the junction, a smoothstep fade to 0 at the tail,
  // with an anti-aliased edge across the stroke.
  static uint8_t fadingRayLevel(float along, float length, float distance,
                                float halfWidth, uint8_t peak) {
    const float coverage = clamp01(halfWidth + 0.5f - distance);
    const float t = clamp01(along / length);
    const float fade = 1.0f - t * t * (3.0f - 2.0f * t);
    return uint8_t(peak * fade * coverage + 0.5f);
  }

  // A junction arm drawn as one soft line from (x0, y0) along (ux, uy) that
  // fades out towards its far end. Lighten blend, like every stroke here.
  void strokeFadingRay(float x0, float y0, float ux, float uy, float length,
                       float halfWidth, uint8_t peak) {
    if (pixels == nullptr) return;
    const float x1 = x0 + ux * length, y1 = y0 + uy * length;
    const float reach = halfWidth + 1.0f;
    int16_t left, right, top, bottom;
    bounds(fminf(y0, y1) - reach, fmaxf(y0, y1) + reach, clipBottom, top, bottom);
    for (int16_t y = top; y <= bottom; ++y) {
      rowSpan(y, x0, y0, x1 - x0, y1 - y0, reach, left, right);
      uint8_t* row = pixels + size_t(y) * width;
      for (int16_t x = left; x <= right; ++x) {
        const float px = x + 0.5f - x0, py = y + 0.5f - y0;
        const float along = px * ux + py * uy;
        if (along < 0.0f || along >= length) continue;
        const float distance = fabsf(px * uy - py * ux);
        if (distance >= halfWidth + 0.5f) continue;
        const uint8_t value = fadingRayLevel(along, length, distance, halfWidth, peak);
        if (value > row[x]) row[x] = value;
      }
    }
  }

  // Anti-aliased rounded rectangle spanning [x0, x1] x [y0, y1].
  void fillRoundRect(float x0, float y0, float x1, float y1, float radius,
                     uint8_t level) {
    if (pixels == nullptr) return;
    int16_t left, right, top, bottom;
    bounds(x0 - 1.0f, x1 + 1.0f, width, left, right);
    bounds(y0 - 1.0f, y1 + 1.0f, clipBottom, top, bottom);
    const float cx = (x0 + x1) / 2.0f, cy = (y0 + y1) / 2.0f;
    const float innerX = (x1 - x0) / 2.0f - radius, innerY = (y1 - y0) / 2.0f - radius;
    for (int16_t y = top; y <= bottom; ++y) {
      uint8_t* row = pixels + size_t(y) * width;
      for (int16_t x = left; x <= right; ++x) {
        const float qx = fmaxf(fabsf(x + 0.5f - cx) - innerX, 0.0f);
        const float qy = fmaxf(fabsf(y + 0.5f - cy) - innerY, 0.0f);
        const float coverage = clamp01(radius + 0.5f - sqrtf(qx * qx + qy * qy));
        if (coverage <= 0.0f) continue;
        const uint8_t value = uint8_t(level * coverage + 0.5f);
        if (value > row[x]) row[x] = value;
      }
    }
  }

  // `x` is the left edge of the first glyph's advance box, `baseline` the
  // text baseline, both in layer pixels. Each output pixel averages enough
  // bilinear samples to cover the font pixels it shrinks, so small text
  // keeps thin strokes instead of dropping or flickering them.
  void drawText(const AlphaFont& font, const char* text, float x, float baseline,
                float scale, uint8_t level) {
    if (pixels == nullptr || !(scale > 0.0f)) return;
    const int steps = scale >= 0.5f ? 2 : (scale <= 1.0f / 6 ? 6 : int(ceilf(1.0f / scale)));
    // Font pixels between neighbouring samples, 16.16 fixed point.
    const float sampleStep = 65536.0f / (steps * scale);
    const int32_t step = int32_t(lroundf(sampleStep));
    const float toLevel = float(level) / (float(AlphaFont::kSampleOne) * steps * steps);
    for (const char* c = text; *c != '\0'; ++c) {
      const NavioNumericGlyph* glyph = font.glyphFor(*c);
      if (glyph == nullptr) continue;
      const float x0 = x + glyph->xOffset * scale;
      const float y0 = baseline + glyph->yOffset * scale;
      int16_t left, right, top, bottom;
      bounds(x0 - 1, x0 + glyph->width * scale + 1, width, left, right);
      bounds(y0 - 1, y0 + glyph->height * scale + 1, clipBottom, top, bottom);
      // Font position of the first sample of pixel (left, top). The sample
      // of font pixel i is taken at its centre, i + 0.5.
      const int32_t startX =
          int32_t(lroundf((left - x0) * steps * sampleStep + sampleStep / 2 - 32768.0f));
      const int32_t startY =
          int32_t(lroundf((top - y0) * steps * sampleStep + sampleStep / 2 - 32768.0f));
      for (int16_t py = top; py <= bottom; ++py) {
        uint8_t* row = pixels + size_t(py) * width;
        const int32_t rowY = startY + int32_t(py - top) * steps * step;
        for (int16_t px = left; px <= right; ++px) {
          const int32_t columnX = startX + int32_t(px - left) * steps * step;
          uint32_t sum = 0;
          for (int sy = 0; sy < steps; ++sy)
            for (int sx = 0; sx < steps; ++sx)
              sum += font.sample(*glyph, columnX + sx * step, rowY + sy * step);
          if (sum == 0) continue;
          const uint8_t value = uint8_t(sum * toLevel + 0.5f);
          if (value > row[px]) row[px] = value;
        }
      }
      x += glyph->advance * scale;
    }
  }

  // Anti-aliased filled triangle, blended over what is there (so it can also
  // cut a black outline into the route).
  void fillTriangle(float ax, float ay, float bx, float by, float cx, float cy,
                    uint8_t level) {
    if (pixels == nullptr) return;
    // Counter-clockwise in screen space, so the inside is on each edge's left.
    if ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax) < 0.0f) {
      float tx = bx, ty = by;
      bx = cx; by = cy; cx = tx; cy = ty;
    }
    const float ex[3] = {ax, bx, cx}, ey[3] = {ay, by, cy};
    float nx[3], ny[3], offset[3];
    for (int i = 0; i < 3; ++i) {
      const int j = (i + 1) % 3;
      const float dx = ex[j] - ex[i], dy = ey[j] - ey[i];
      const float length = sqrtf(dx * dx + dy * dy);
      if (length <= 0.0f) return;
      nx[i] = -dy / length;  // inward normal
      ny[i] = dx / length;
      offset[i] = -(nx[i] * ex[i] + ny[i] * ey[i]);
    }
    int16_t x0, x1, y0, y1;
    bounds(fminf(ax, fminf(bx, cx)) - 1.0f, fmaxf(ax, fmaxf(bx, cx)) + 1.0f, width, x0, x1);
    bounds(fminf(ay, fminf(by, cy)) - 1.0f, fmaxf(ay, fmaxf(by, cy)) + 1.0f, clipBottom, y0, y1);
    for (int16_t y = y0; y <= y1; ++y) {
      uint8_t* row = pixels + size_t(y) * width;
      for (int16_t x = x0; x <= x1; ++x) {
        const float px = x + 0.5f, py = y + 0.5f;
        float inside = 1e9f;
        for (int i = 0; i < 3; ++i)
          inside = fminf(inside, nx[i] * px + ny[i] * py + offset[i]);
        const float coverage = clamp01(inside + 0.5f);
        if (coverage <= 0.0f) continue;
        row[x] = uint8_t(row[x] + (level - row[x]) * coverage + 0.5f);
      }
    }
  }
};

// A small colour picture laid over the composed frame, positioned in panel
// view pixels. A pixel of 0 is transparent.
struct ColorSprite {
  uint16_t* pixels = nullptr;  // RGB565, `width` per row
  int16_t x = 0, y = 0, width = 0, height = 0;
};

// Builds one full panel frame: UI from the low-resolution canvas (nearest
// sample) on top of the independently sized gray layer, black outside the
// round aperture, with an optional colour sprite on top. Lookup tables are
// computed once.
struct PanelComposer {
  static constexpr int16_t kMaxSize = 512;
  int16_t width = 0, height = 0, canvasWidth = 0;
  int16_t layerWidth = 0, layerHeight = 0;
  uint16_t sourceX[kMaxSize] = {}, sourceY[kMaxSize] = {};
  uint16_t layerX[kMaxSize] = {}, layerY[kMaxSize] = {};
  int16_t spanStart[kMaxSize] = {}, spanEnd[kMaxSize] = {};
  uint16_t gray565[256] = {};

  // `centerX/Y` and `radius` describe the visible circle in view pixels.
  void init(int16_t viewWidth, int16_t viewHeight, int16_t canvasW, int16_t canvasH,
            float centerX, float centerY, float radius,
            int16_t layerW = 0, int16_t layerH = 0) {
    width = viewWidth;
    height = viewHeight;
    canvasWidth = canvasW;
    layerWidth = layerW > 0 ? layerW : viewWidth;
    layerHeight = layerH > 0 ? layerH : viewHeight;
    for (int16_t x = 0; x < width; ++x) {
      sourceX[x] = uint16_t(x * canvasW / width);
      layerX[x] = uint16_t(x * layerWidth / width);
    }
    for (int16_t y = 0; y < height; ++y) {
      sourceY[y] = uint16_t(y * canvasH / height);
      layerY[y] = uint16_t(y * layerHeight / height);
      const float dy = y + 0.5f - centerY;
      const float half = radius * radius - dy * dy;
      if (half <= 0.0f) {
        spanStart[y] = 0;
        spanEnd[y] = 0;
        continue;
      }
      const float reach = sqrtf(half);
      spanStart[y] = int16_t(fmaxf(0.0f, ceilf(centerX - reach - 0.5f)));
      spanEnd[y] = int16_t(fminf(float(width), floorf(centerX + reach - 0.5f) + 1.0f));
    }
    for (int g = 0; g < 256; ++g)
      gray565[g] = uint16_t(((g >> 3) << 11) | ((g >> 2) << 5) | (g >> 3));
  }

  bool blank(const uint16_t* canvasRow) const {
    for (int16_t x = 0; x < canvasWidth; ++x)
      if (canvasRow[x] != 0) return false;
    return true;
  }

  // Writes view rows [firstRow, firstRow + rowCount) to `out`. `layer` may be
  // null (no map on this screen).
  void compose(const uint16_t* canvas, const GrayLayer* layer, uint16_t* out,
               int16_t firstRow, int16_t rowCount,
               const ColorSprite* sprite = nullptr) const {
    for (int16_t y = firstRow; y < firstRow + rowCount && y < height; ++y) {
      uint16_t* row = out + size_t(y - firstRow) * width;
      const int16_t start = spanStart[y], end = spanEnd[y];
      for (int16_t x = 0; x < start; ++x) row[x] = 0;
      for (int16_t x = end; x < width; ++x) row[x] = 0;
      const uint16_t* canvasRow = canvas + size_t(sourceY[y]) * canvasWidth;
      const uint8_t* mapRow =
          layer != nullptr && layer->pixels != nullptr &&
                  layer->width == layerWidth && layer->height == layerHeight
              ? layer->pixels + size_t(layerY[y]) * layerWidth : nullptr;
      if (mapRow != nullptr && layerWidth == width && blank(canvasRow)) {
        // The usual row: nothing on the canvas, layer at panel resolution.
        for (int16_t x = start; x < end; ++x) row[x] = gray565[mapRow[x]];
      } else {
        for (int16_t x = start; x < end; ++x) {
          const uint16_t ui = canvasRow[sourceX[x]];
          row[x] = ui != 0 || mapRow == nullptr ? ui : gray565[mapRow[layerX[x]]];
        }
      }
      if (sprite == nullptr || sprite->pixels == nullptr || y < sprite->y ||
          y >= sprite->y + sprite->height)
        continue;
      const uint16_t* from = sprite->pixels + size_t(y - sprite->y) * sprite->width - sprite->x;
      const int16_t last = sprite->x + sprite->width < end ? sprite->x + sprite->width : end;
      for (int16_t x = sprite->x > start ? sprite->x : start; x < last; ++x)
        if (from[x] != 0) row[x] = from[x];
    }
  }
};
