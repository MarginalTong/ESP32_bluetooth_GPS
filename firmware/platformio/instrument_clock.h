#pragma once

#include <stdio.h>
#include <stdlib.h>

#include "gray_layer.h"

// Visual tuning in 240-pixel layout units, inspired by the user's mechanical
// motorcycle dial reference. This is a clock, not an RPM or speed gauge.
namespace InstrumentClockStyle {
constexpr float centerX = 120, centerY = 110, radius = 92;
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

  // Radians clockwise from twelve; hour hand advances between hour marks.
  static float minuteAngle(int minute) { return minute * 6.0f * kRadians; }
  static float hourAngle(int hour, int minute) {
    return ((hour % 12) * 30.0f + minute * 0.5f) * kRadians;
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
    hand(mask, scale, hourAngle(hour, minute), 47, 3.2f);
    tint(mask, InstrumentClockStyle::ivory, false);
    mask.clear();
    hand(mask, scale, minuteAngle(minute), 71, 2.2f);
    const float x = InstrumentClockStyle::centerX * scale;
    const float y = InstrumentClockStyle::centerY * scale;
    mask.fillRoundRect(x - 4 * scale, y - 4 * scale,
                       x + 4 * scale, y + 4 * scale, 4 * scale, 255);
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
    for (int i = 0; i < 180; ++i) {
      const float a = i * 2 * kRadians, b = (i + 1) * 2 * kRadians;
      mask.strokeSegment((centerX + radius * sinf(a)) * s,
                          (centerY - radius * cosf(a)) * s,
                          (centerX + radius * sinf(b)) * s,
                          (centerY - radius * cosf(b)) * s, 0.5f * s, 130);
    }
    for (int i = 0; i < 60; ++i)
      radial(mask, s, minuteAngle(i), i % 5 == 0 ? 79 : 86, 91,
              i % 5 == 0 ? 0.95f : 0.45f, i % 5 == 0 ? 255 : 180);
    for (int i = 1; i <= 12; ++i) {
      char number[3];
      snprintf(number, sizeof(number), "%d", i);
      const float a = i * 30 * kRadians;
      label(mask, s, number, centerX + 68 * sinf(a), centerY - 68 * cosf(a) + 5, 13);
    }
    label(mask, s, "NAVIO", centerX, 76, 7);
    label(mask, s, "ready to go", centerX, 216, 7);
  }

  void timeWindow(GrayLayer& mask, float s, const char* text) {
    // The digital window stays readable when either hand crosses six o'clock.
    mask.clear();
    mask.fillRoundRect(81 * s, 144 * s, 159 * s, 170 * s, 4 * s, 255);
    constexpr uint8_t black[] = {0, 0, 0};
    tint(mask, black, true);
    mask.clear();
    label(mask, s, text, InstrumentClockStyle::centerX, 163, 15);
    tint(mask, InstrumentClockStyle::ivory, true);
  }

  static void hand(GrayLayer& mask, float s, float a, float length, float halfWidth) {
    radial(mask, s, a, -10, length, halfWidth, 255);
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
