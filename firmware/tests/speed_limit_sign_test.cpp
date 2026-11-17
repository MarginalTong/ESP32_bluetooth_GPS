#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "speed_limit_sign.h"

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

// The round panel: the 240-px layout drawn 1.5 times larger.
constexpr float kScale = 1.5f;
constexpr float kCenterX = SpeedSignStyle::centerX * kScale;
constexpr float kCenterY = SpeedSignStyle::centerY * kScale;
constexpr float kDiameter = SpeedSignStyle::diameter * kScale;
constexpr float kHalo = SpeedSignStyle::halo * kScale;

struct Rgb { int r, g, b; };
static Rgb rgb(uint16_t p) { return {(p >> 11) * 255 / 31, ((p >> 5) & 63) * 255 / 63, (p & 31) * 255 / 31}; }
static bool isRed(uint16_t p) { const Rgb c = rgb(p); return c.r > 200 && c.g < 80 && c.b < 80; }
static bool isWhite(uint16_t p) { const Rgb c = rgb(p); return c.r > 235 && c.g > 235 && c.b > 235; }
static bool isDark(uint16_t p) { const Rgb c = rgb(p); return p != 0 && c.r < 60 && c.g < 60 && c.b < 60; }

// The sprite pixel at view position (x, y); 0 outside the sprite.
static uint16_t at(const ColorSprite& s, float x, float y) {
  const int column = int(floorf(x)) - s.x, row = int(floorf(y)) - s.y;
  if (column < 0 || row < 0 || column >= s.width || row >= s.height) return 0;
  return s.pixels[row * s.width + column];
}

static void checkSign(SpeedLimitSign& sign, uint8_t kph, const char* label) {
  check(sign.prepare(kph, kCenterX, kCenterY, kDiameter, kHalo), label);
  const ColorSprite& s = sign.sprite;
  const float radius = kDiameter / 2, inner = radius * (1 - SpeedSignStyle::ring);
  int digits = 0;
  for (int row = 0; row < s.height; ++row)
    for (int column = 0; column < s.width; ++column) {
      const float dx = s.x + column + 0.5f - kCenterX, dy = s.y + row + 0.5f - kCenterY;
      const float distance = sqrtf(dx * dx + dy * dy);
      const uint16_t p = s.pixels[row * s.width + column];
      if (distance > radius + kHalo + 1) check(p == 0, "outside the sign is transparent");
      if (distance > radius + 1 && distance < radius + kHalo - 1)
        check(isDark(p), "a black margin separates the sign from the map");
      if (distance > inner + 1.5f && distance < radius - 1.5f) check(isRed(p), "the ring is red");
      // The digits keep clear of the ring.
      if (distance > inner * 0.9f && distance < inner - 1.5f)
        check(isWhite(p), "the number fits inside the white disc");
      if (distance < inner - 1.5f) {
        check(p != 0 && !isRed(p), "inside the ring is white with a black number");
        digits += isDark(p);
      }
    }
  check(digits > 60, "the number is drawn in black");
  // Above and below the number the disc is plain white.
  check(isWhite(at(s, kCenterX, kCenterY - inner * 0.75f)) &&
            isWhite(at(s, kCenterX, kCenterY + inner * 0.75f)),
        "the number is vertically centred");
}

int main() {
  check(SpeedLimitSign::valid(40) == 40 && SpeedLimitSign::valid(5) == 5 &&
            SpeedLimitSign::valid(130) == 130,
        "posted limits are shown");
  check(SpeedLimitSign::valid(0) == 0 && SpeedLimitSign::valid(4) == 0 &&
            SpeedLimitSign::valid(131) == 0 && SpeedLimitSign::valid(-60) == 0 &&
            SpeedLimitSign::valid(100000) == 0,
        "missing or impossible limits show no sign");

  SpeedLimitSign sign;
  check(!sign.prepare(0, kCenterX, kCenterY, kDiameter, kHalo), "no limit, no sign");
  // One, two and three digits, the widest ones included.
  checkSign(sign, 5, "5");
  checkSign(sign, 40, "40");
  checkSign(sign, 80, "80");
  checkSign(sign, 100, "100");
  checkSign(sign, 110, "110");

  const uint32_t before = sign.renders;
  check(sign.prepare(110, kCenterX, kCenterY, kDiameter, kHalo) && sign.renders == before,
        "an unchanged limit is not drawn again");
  check(sign.prepare(60, kCenterX, kCenterY, kDiameter, kHalo) && sign.renders == before + 1,
        "a new limit is drawn once");

  // The sign stays inside the visible circle of the 360-px panel.
  const float fromCenter = sqrtf((kCenterX - 180) * (kCenterX - 180) +
                                 (kCenterY - 180) * (kCenterY - 180));
  check(fromCenter + kDiameter / 2 + kHalo < 177 - 6, "the sign is clear of the round bezel");

  // Composed over the map: the sign replaces what is under it, nothing else.
  constexpr int size = 360;
  std::vector<uint8_t> gray(size * size, 200);
  GrayLayer layer;
  layer.pixels = gray.data();
  layer.width = layer.height = layer.clipBottom = size;
  std::vector<uint16_t> canvas(240 * 240, 0), plain(size * size), signed_(size * size);
  PanelComposer composer;
  composer.init(size, size, 240, 240, 180, 180, 177, size, size);
  for (int y = 0; y < size; y += 16) {
    composer.compose(canvas.data(), &layer, plain.data() + y * size, y, y + 16 > size ? size - y : 16);
    composer.compose(canvas.data(), &layer, signed_.data() + y * size, y,
                     y + 16 > size ? size - y : 16, &sign.sprite);
  }
  int covered = 0;
  for (int y = 0; y < size; ++y)
    for (int x = 0; x < size; ++x) {
      const uint16_t expected = at(sign.sprite, x, y);
      check(signed_[y * size + x] == (expected != 0 ? expected : plain[y * size + x]),
            "the sprite covers only its own opaque pixels");
      covered += expected != 0;
    }
  check(covered > 3000, "the sign is on the panel");
  // A sprite partly or wholly off the panel is clipped, not written outside.
  ColorSprite moved = sign.sprite;
  for (const int x : {-30, 340, 1000}) {
    moved.x = int16_t(x);
    moved.y = -20;
    std::vector<uint16_t> band(size * 16 + 2, 0xa55a);
    composer.compose(canvas.data(), &layer, band.data() + 1, 0, 16, &moved);
    check(band.front() == 0xa55a && band.back() == 0xa55a, "an off-panel sprite stays in bounds");
  }
  puts("speed limit sign: colours, digits within the disc, reuse, placement and composition passed");
}
