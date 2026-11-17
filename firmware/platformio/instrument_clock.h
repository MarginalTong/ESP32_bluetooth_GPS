#pragma once

#include <stdio.h>
#include <stdlib.h>

#include "gray_layer.h"

// Visual tuning in 240-pixel layout units, inspired by the user's mechanical
// motorcycle dial reference. This is a clock, not an RPM or speed gauge.
namespace InstrumentClockStyle {
constexpr float centerX = 120, centerY = 120, radius = 116;
// Reference supplied 2026-11-17: hollow red hub and a slim tapered needle.
constexpr float hubRadius = 12, hubHalfStroke = 1.6f;
constexpr float needleRoot = 11, needleLength = 98, needleHalfWidth = 2.2f;
constexpr uint8_t ivory[3] = {246, 222, 181};
constexpr uint8_t red[3] = {244, 48, 54};
}  // namespace InstrumentClockStyle

struct InstrumentClock {
  ColorSprite sprite;
  int shownMinute = -1;
  uint32_t renders = 0;

  InstrumentClock() = default;
  InstrumentClock(const InstrumentClock&) = delete;
  InstrumentClock& operator=(const InstrumentClock&) = delete;
  ~InstrumentClock() { free(sprite.pixels); }

  static bool parse(const char* text, int& hour, int& minute) {
    if (!text || strlen(text) != 5 || text[2] != ':') return false;
    const int positions[] = {0, 1, 3, 4};
    for (int i : positions)
      if (text[i] < '0' || text[i] > '9') return false;
    hour = (text[0] - '0') * 10 + text[1] - '0';
    minute = (text[3] - '0') * 10 + text[4] - '0';
    return hour < 24 && minute < 60;
  }

  // A 270-degree instrument sweep, from lower-left midnight to lower-right
  // midnight. One needle shows the whole day; the digital window gives minutes.
  static float timeAngle(int hour, int minute) {
    return (225.0f + (hour * 60 + minute) * 270.0f / 1440.0f) * kRadians;
  }

  bool prepare(const char* text, int16_t size) {
    int hour, minute;
    if (!parse(text, hour, minute) || size < 120 || size > 512) return false;
    const int stamp = hour * 60 + minute;
    if (sprite.pixels && sprite.width == size && shownMinute == stamp) return true;
    const size_t count = size_t(size) * size;
    uint8_t* maskPixels = static_cast<uint8_t*>(calloc(count, 1));
    if (!maskPixels) return false;
    if (!sprite.pixels || sprite.width != size) {
      uint16_t* next = static_cast<uint16_t*>(malloc(count * sizeof(uint16_t)));
      if (!next) { free(maskPixels); return false; }
      free(sprite.pixels);
      sprite.pixels = next;
      sprite.width = sprite.height = size;
    }
    GrayLayer mask;
    mask.pixels = maskPixels;
    mask.width = mask.height = mask.clipBottom = size;
    const float scale = size / 240.0f;
    face(mask, scale);
    tint(mask, InstrumentClockStyle::ivory, false);
    mask.clear();
    needle(mask, scale, timeAngle(hour, minute));
    hub(mask, scale);
    tint(mask, InstrumentClockStyle::red, true);
    timeWindow(mask, scale, text);
    free(maskPixels);
    shownMinute = stamp;
    ++renders;
    return true;
  }

 private:
  static constexpr float kRadians = 0.017453292519943295f;

  static void radial(GrayLayer& mask, float s, float angle, float from,
                     float to, float halfWidth, uint8_t level) {
    const float dx = sinf(angle), dy = -cosf(angle);
    const float x = InstrumentClockStyle::centerX, y = InstrumentClockStyle::centerY;
    mask.strokeSegment((x + from * dx) * s, (y + from * dy) * s,
                        (x + to * dx) * s, (y + to * dy) * s, halfWidth * s, level);
  }

  static void label(GrayLayer& mask, float s, const char* text,
                    float x, float baseline, float height) {
    const float fontScale = height * s / NAVIO_TEXT_FONT.capHeight;
    mask.drawText(NAVIO_TEXT_FONT, text,
                   x * s - NAVIO_TEXT_FONT.textWidth(text, fontScale) / 2,
                   baseline * s, fontScale, 255);
  }

  static void face(GrayLayer& mask, float s) {
    using namespace InstrumentClockStyle;
    // Small line segments make a continuous, anti-aliased instrument bezel.
    for (int i = 0; i < 135; ++i) {
      const float a = (225 + i * 2) * kRadians, b = (227 + i * 2) * kRadians;
      mask.strokeSegment((centerX + radius * sinf(a)) * s,
                          (centerY - radius * cosf(a)) * s,
                          (centerX + radius * sinf(b)) * s,
                          (centerY - radius * cosf(b)) * s, 0.5f * s, 130);
    }
    for (int i = 0; i <= 96; ++i)
      radial(mask, s, (225 + i * 270.0f / 96) * kRadians,
              i % 16 == 0 ? 99 : (i % 4 == 0 ? 105 : 110), 115,
              i % 16 == 0 ? 1.1f : 0.5f, i % 4 == 0 ? 255 : 180);
    for (int i = 0; i <= 24; i += 4) {
      char number[3];
      snprintf(number, sizeof(number), "%d", i);
      const float a = timeAngle(i, 0);
      label(mask, s, number, centerX + 85 * sinf(a), centerY - 85 * cosf(a) + 6, 16);
    }
    label(mask, s, "NAVIO", centerX, 76, 7);
    label(mask, s, "ready to go", centerX, 222, 7);
  }

  void timeWindow(GrayLayer& mask, float s, const char* text) {
    // Time sits in the open bottom of the sweep, away from the needle.
    mask.clear();
    mask.fillRoundRect(73 * s, 181 * s, 167 * s, 209 * s, 4 * s, 255);
    constexpr uint8_t black[] = {0, 0, 0};
    tint(mask, black, true);
    mask.clear();
    label(mask, s, text, InstrumentClockStyle::centerX, 205, 22);
    tint(mask, InstrumentClockStyle::ivory, true);
  }

  static void needle(GrayLayer& mask, float s, float a) {
    using namespace InstrumentClockStyle;
    const float dx = sinf(a), dy = -cosf(a), nx = -dy, ny = dx;
    mask.fillTriangle((centerX + needleRoot * dx + needleHalfWidth * nx) * s,
                       (centerY + needleRoot * dy + needleHalfWidth * ny) * s,
                       (centerX + needleRoot * dx - needleHalfWidth * nx) * s,
                       (centerY + needleRoot * dy - needleHalfWidth * ny) * s,
                       (centerX + needleLength * dx) * s,
                       (centerY + needleLength * dy) * s, 255);
  }

  static void hub(GrayLayer& mask, float s) {
    using namespace InstrumentClockStyle;
    const float cx = centerX * s, cy = centerY * s;
    const float radius = hubRadius * s, halfStroke = hubHalfStroke * s;
    const float reach = radius + halfStroke + 1;
    int16_t left, right, top, bottom;
    mask.bounds(cx - reach, cx + reach, mask.width, left, right);
    mask.bounds(cy - reach, cy + reach, mask.clipBottom, top, bottom);
    // Distance coverage of an annulus: no painted disc or erasing pass, so
    // the hub remains hollow at every angle and native rendering size.
    for (int16_t y = top; y <= bottom; ++y)
      for (int16_t x = left; x <= right; ++x) {
        const float dx = x + 0.5f - cx, dy = y + 0.5f - cy;
        const float distance = fabsf(sqrtf(dx * dx + dy * dy) - radius);
        const uint8_t value = uint8_t(255 * GrayLayer::clamp01(halfStroke + 0.5f - distance));
        uint8_t& pixel = mask.pixels[size_t(y) * mask.width + x];
        if (value > pixel) pixel = value;
      }
  }

  void tint(const GrayLayer& mask, const uint8_t* rgb, bool overlay) {
    for (size_t i = 0; i < size_t(mask.width) * mask.height; ++i) {
      const uint8_t alpha = mask.pixels[i];
      const uint16_t old = overlay ? sprite.pixels[i] : 0;
      const int r = (old >> 11) * 255 / 31;
      const int g = ((old >> 5) & 63) * 255 / 63;
      const int b = (old & 31) * 255 / 31;
      const uint16_t pixel = uint16_t((((r * (255-alpha) + rgb[0]*alpha)/255) >> 3) << 11) |
          uint16_t((((g * (255-alpha) + rgb[1]*alpha)/255) >> 2) << 5) |
          uint16_t(((b * (255-alpha) + rgb[2]*alpha)/255) >> 3);
      // Zero is transparent in the compositor; use its near-black sentinel.
      sprite.pixels[i] = pixel ? pixel : 0x0020;
    }
  }
};
