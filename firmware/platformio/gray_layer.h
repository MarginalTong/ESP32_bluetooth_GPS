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

  float coverage(const NavioNumericGlyph& glyph, int x, int y) const {
    if (x < 0 || y < 0 || x >= glyph.width || y >= glyph.height) return 0.0f;
    const uint32_t index = uint32_t(y) * glyph.width + x;
    const uint8_t packed = alpha[glyph.offset + index / 2];
    return float(index & 1 ? packed & 15 : packed >> 4) / 15.0f;
  }

  float sample(const NavioNumericGlyph& glyph, float x, float y) const {
    const int ix = int(floorf(x)), iy = int(floorf(y));
    const float fx = x - ix, fy = y - iy;
    const float upper = coverage(glyph, ix, iy) * (1.0f - fx) +
                        coverage(glyph, ix + 1, iy) * fx;
    const float lower = coverage(glyph, ix, iy + 1) * (1.0f - fx) +
                        coverage(glyph, ix + 1, iy + 1) * fx;
    return upper * (1.0f - fy) + lower * fy;
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

  static float segmentDistance(float px, float py, float ax, float ay, float bx,
                               float by) {
    const float dx = bx - ax, dy = by - ay;
    const float lengthSquared = dx * dx + dy * dy;
    const float t = lengthSquared > 0.0f
                        ? clamp01(((px - ax) * dx + (py - ay) * dy) / lengthSquared)
                        : 0.0f;
    const float ex = px - (ax + t * dx), ey = py - (ay + t * dy);
    return sqrtf(ex * ex + ey * ey);
  }

  void clear() {
    if (pixels != nullptr) memset(pixels, 0, size_t(width) * height);
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

  // Lighten blend: keeps the brighter value, so the overlapping ends of a
  // polyline's segments never double their anti-aliased edges.
  void strokeSegment(float ax, float ay, float bx, float by, float halfWidth,
                     uint8_t level) {
    if (pixels == nullptr) return;
    const float reach = halfWidth + 1.0f;
    int16_t x0, x1, y0, y1;
    bounds(fminf(ax, bx) - reach, fmaxf(ax, bx) + reach, width, x0, x1);
    bounds(fminf(ay, by) - reach, fmaxf(ay, by) + reach, clipBottom, y0, y1);
    for (int16_t y = y0; y <= y1; ++y) {
      uint8_t* row = pixels + size_t(y) * width;
      for (int16_t x = x0; x <= x1; ++x) {
        const float coverage = clamp01(
            halfWidth + 0.5f - segmentDistance(x + 0.5f, y + 0.5f, ax, ay, bx, by));
        if (coverage <= 0.0f) continue;
        const uint8_t value = uint8_t(level * coverage + 0.5f);
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
    bounds(fminf(x0, x1) - reach, fmaxf(x0, x1) + reach, width, left, right);
    bounds(fminf(y0, y1) - reach, fmaxf(y0, y1) + reach, clipBottom, top, bottom);
    for (int16_t y = top; y <= bottom; ++y) {
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
    if (pixels == nullptr) return;
    const int steps = scale >= 0.5f ? 2 : (scale <= 1.0f / 6 ? 6 : int(ceilf(1.0f / scale)));
    for (const char* c = text; *c != '\0'; ++c) {
      const NavioNumericGlyph* glyph = font.glyphFor(*c);
      if (glyph == nullptr) continue;
      const float x0 = x + glyph->xOffset * scale;
      const float y0 = baseline + glyph->yOffset * scale;
      int16_t left, right, top, bottom;
      bounds(x0 - 1, x0 + glyph->width * scale + 1, width, left, right);
      bounds(y0 - 1, y0 + glyph->height * scale + 1, clipBottom, top, bottom);
      for (int16_t py = top; py <= bottom; ++py) {
        uint8_t* row = pixels + size_t(py) * width;
        for (int16_t px = left; px <= right; ++px) {
          float sum = 0.0f;
          for (int sy = 0; sy < steps; ++sy) {
            const float gy = (py + (sy + 0.5f) / steps - y0) / scale - 0.5f;
            for (int sx = 0; sx < steps; ++sx) {
              const float gx = (px + (sx + 0.5f) / steps - x0) / scale - 0.5f;
              sum += font.sample(*glyph, gx, gy);
            }
          }
          if (sum <= 0.0f) continue;
          const uint8_t value = uint8_t(level * sum / (steps * steps) + 0.5f);
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

// Builds one full panel frame: UI from the low-resolution canvas (nearest
// sample) on top of the independently sized gray layer, black outside the
// round aperture. Lookup tables are computed once.
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

  // Writes view rows [firstRow, firstRow + rowCount) to `out`. `layer` may be
  // null (no map on this screen).
  void compose(const uint16_t* canvas, const GrayLayer* layer, uint16_t* out,
               int16_t firstRow, int16_t rowCount) const {
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
      for (int16_t x = start; x < end; ++x) {
        const uint16_t ui = canvasRow[sourceX[x]];
        row[x] = ui != 0 || mapRow == nullptr ? ui : gray565[mapRow[layerX[x]]];
      }
    }
  }
};
