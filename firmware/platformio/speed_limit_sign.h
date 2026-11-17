#pragma once

// The posted speed limit, drawn as the Australian regulatory sign (a red
// ring, white inside, black number). Shared by the firmware and the host
// test (speed_limit_sign_test). It is the only colour on the panel, so it is
// a small colour bitmap laid over the gray layer when the frame is composed.
#include <stdio.h>
#include <stdlib.h>

#include "gray_layer.h"

// The look and place of the sign, in one place (recorded in
// firmware/README.md). Positions are canvas pixels of the 240-px layout.
namespace SpeedSignStyle {
// Right of the map, clear of the route (centre column), the rider marker and
// the instruction strip, and 6 px inside the round aperture. About 9 mm on
// the 39 mm panel: readable at a glance without crowding the map.
constexpr float centerX = 198.0f;
constexpr float centerY = 92.0f;
constexpr float diameter = 54.0f;
// Black margin around the sign, so map lines under it do not touch the ring.
constexpr float halo = 2.0f;
// Ring width as a fraction of the sign's radius, and the red, both measured
// from the sign artwork supplied for this feature (2026-11-17).
constexpr float ring = 0.20f;
constexpr uint8_t red[3] = {238, 45, 47};
// Digits: at most this share of the white disc's diameter in height / width.
constexpr float digitHeight = 0.46f;
constexpr float digitWidth = 0.80f;
}  // namespace SpeedSignStyle

struct SpeedLimitSign {
  // Limits a sign can show, km/h; matches the app's ValhallaSpeedLimits.
  static constexpr int kMinKph = 5;
  static constexpr int kMaxKph = 130;
  // An opaque pixel that is black on the panel: 0 means transparent.
  static constexpr uint16_t kBlack = 0x0020;

  ColorSprite sprite;
  uint8_t shownKph = 0;
  float shownX = 0, shownY = 0, shownDiameter = 0;
  uint32_t renders = 0;  // times the bitmap was drawn

  ~SpeedLimitSign() { free(sprite.pixels); }

  // The limit to show for a received value, or 0 for none.
  static uint8_t valid(long kph) {
    return kph >= kMinKph && kph <= kMaxKph ? uint8_t(kph) : 0;
  }

  // Makes `sprite` the sign for `kph`, centred on (centerX, centerY) with the
  // given diameter and halo, all in panel-view pixels. The bitmap is drawn
  // again only when something changed. Returns false when there is no sign
  // to show (no limit, or no memory).
  bool prepare(uint8_t kph, float centerX, float centerY, float diameter, float halo) {
    if (valid(kph) == 0 || !(diameter >= 8.0f)) return false;
    if (sprite.pixels != nullptr && kph == shownKph && centerX == shownX &&
        centerY == shownY && diameter == shownDiameter)
      return true;
    const int16_t size = int16_t(ceilf(diameter + 2.0f * halo)) + 2;
    const size_t count = size_t(size) * size;
    if (sprite.width != size) {
      free(sprite.pixels);
      sprite.pixels = static_cast<uint16_t*>(malloc(count * sizeof(uint16_t)));
      sprite.width = sprite.height = sprite.pixels != nullptr ? size : 0;
    }
    // Coverage of the halo, the red disc, the white disc and the digits.
    uint8_t* masks = static_cast<uint8_t*>(calloc(count, 4));
    if (sprite.pixels == nullptr || masks == nullptr) {
      free(masks);
      shownKph = 0;
      return false;
    }
    sprite.x = int16_t(floorf(centerX - size / 2.0f));
    sprite.y = int16_t(floorf(centerY - size / 2.0f));
    const float cx = centerX - sprite.x, cy = centerY - sprite.y;
    const float radius = diameter / 2.0f;
    const float inner = radius * (1.0f - SpeedSignStyle::ring);
    GrayLayer mask[4];
    const float radii[3] = {radius + halo, radius, inner};
    for (int i = 0; i < 4; ++i) {
      mask[i].pixels = masks + count * i;
      mask[i].width = mask[i].height = mask[i].clipBottom = size;
      if (i < 3)
        mask[i].fillRoundRect(cx - radii[i], cy - radii[i], cx + radii[i], cy + radii[i],
                              radii[i], 255);
    }
    char text[4];
    snprintf(text, sizeof(text), "%u", unsigned(kph));
    const AlphaFont& font = NAVIO_NUMERIC_FONT;
    const float byHeight = SpeedSignStyle::digitHeight * 2.0f * inner / font.capHeight;
    const float byWidth = SpeedSignStyle::digitWidth * 2.0f * inner / font.textWidth(text, 1.0f);
    const float scale = byHeight < byWidth ? byHeight : byWidth;
    mask[3].drawText(font, text, cx - font.textWidth(text, scale) / 2.0f,
                     cy + font.capHeight * scale / 2.0f, scale, 255);
    for (size_t i = 0; i < count; ++i)
      sprite.pixels[i] = pixel(mask[0].pixels[i], mask[1].pixels[i], mask[2].pixels[i],
                               mask[3].pixels[i]);
    free(masks);
    shownKph = kph;
    shownX = centerX;
    shownY = centerY;
    shownDiameter = diameter;
    ++renders;
    return true;
  }

 private:
  // Black, then red by the outer disc, white by the inner disc, and black
  // again by the digits, each blended by its coverage (0..255).
  static uint16_t pixel(uint8_t halo, uint8_t outer, uint8_t inner, uint8_t digits) {
    if (halo < 128) return 0;
    uint16_t packed = 0;
    const uint8_t shift[3] = {11, 5, 0}, bits[3] = {5, 6, 5};
    for (int c = 0; c < 3; ++c) {
      uint32_t value = SpeedSignStyle::red[c] * outer / 255;
      value += (255 - value) * inner / 255;
      value -= value * digits / 255;
      packed |= uint16_t((value >> (8 - bits[c])) << shift[c]);
    }
    return packed != 0 ? packed : kBlack;
  }
};
