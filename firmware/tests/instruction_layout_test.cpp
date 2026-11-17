#include <stdio.h>
#include <stdlib.h>

#include "gray_layer.h"
#include "instruction_layout.h"
#include "speed_limit_sign.h"

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s (%s)\n", message, "instruction layout");
    exit(1);
  }
}

using namespace InstructionLayout;

// Visible circle of the round panel in the 240-px layout, with a 3 px margin.
constexpr float kCenter = 120.0f, kRadius = 118.0f - 3.0f;
static bool insideCircle(float x, float y) {
  return (x - kCenter) * (x - kCenter) + (y - kCenter) * (y - kCenter) <= kRadius * kRadius;
}

// Whether the box [left, right] x [top, bottom] keeps `gap` px from the sign.
static bool clearOfSign(float left, float right, float top, float bottom, float gap) {
  const float nearestX = SpeedSignStyle::centerX < left ? left
                         : SpeedSignStyle::centerX > right ? right : SpeedSignStyle::centerX;
  const float nearestY = SpeedSignStyle::centerY < top ? top
                         : SpeedSignStyle::centerY > bottom ? bottom : SpeedSignStyle::centerY;
  const float dx = nearestX - SpeedSignStyle::centerX, dy = nearestY - SpeedSignStyle::centerY;
  const float reach = SpeedSignStyle::diameter / 2 + SpeedSignStyle::halo + gap;
  return dx * dx + dy * dy >= reach * reach;
}

static void checkText(const char* text, const char* unit) {
  const bool numeric = text[0] >= '0' && text[0] <= '9';
  const AlphaFont& font = numeric ? NAVIO_NUMERIC_FONT : NAVIO_TEXT_FONT;
  const float fullWidth = font.textWidth(text, 7.0f * distanceSize / font.capHeight);
  const DistancePlace place = placeDistance(fullWidth);
  const float width = fullWidth * place.size / distanceSize;
  const float right = place.numberLeft + width, bottom = place.numberTop + 7.0f * place.size;
  check(place.size >= 1 && place.size <= distanceSize, text);
  // The widest arrows reach 26.5 px right of the artwork centre (stroke included).
  check(place.numberLeft >= arrowCenterX + 26.5f + 3.0f, "text keeps clear of the arrow");
  check(clearOfSign(place.numberLeft, right, place.numberTop, bottom, 2.0f),
        "text keeps clear of the speed limit sign");
  check(place.numberTop >= panelTop + 3.0f && bottom <= distanceTop + 7.0f * distanceSize,
        "text stays on its line inside the panel");
  check(insideCircle(right, bottom) && insideCircle(place.numberLeft, bottom),
        "text is inside the round aperture");
  if (unit == nullptr) return;
  const float unitWidth = NAVIO_TEXT_FONT.textWidth(unit, 7.0f * unitSize / NAVIO_TEXT_FONT.capHeight);
  const float unitBottom = place.unitTop + 7.0f * unitSize;
  check(fabsf(unitBottom - bottom) < 0.001f &&
            fabsf(place.unitLeft - right - unitGap) < 0.001f,
        "unit is to the right of the digits with aligned bottoms, never below them");
  check(clearOfSign(place.unitLeft, place.unitLeft + unitWidth,
                    place.unitTop, unitBottom, 2.0f), "unit keeps clear of the speed limit sign");
  check(insideCircle(place.unitLeft, unitBottom) && insideCircle(place.unitLeft + unitWidth, unitBottom),
        "the unit is inside the round aperture");
  check(errorTop >= unitBottom, "the diagnostic line is below the unit");
}

int main() {
  checkText("31", "m");
  checkText("106", "m");
  checkText("300", "m");
  checkText("999", "m");
  checkText("1.0", "km");
  checkText("10.0", "km");
  checkText("9999.9", "km");
  checkText("2147483.6", "km");
  const float threeDigits = NAVIO_NUMERIC_FONT.textWidth(
      "106", 7.0f * distanceSize / NAVIO_NUMERIC_FONT.capHeight);
  check(placeDistance(threeDigits).size == distanceSize, "106 m retains full-size digits");
  checkText("NOW", nullptr);
  checkText("ARR", nullptr);

  // The arrow: 33 px of artwork plus its stroke, under the panel's edge and
  // inside the aperture at its lowest, leftmost point (the turn stems).
  check(arrowCenterY - 18.5f - 2.5f >= panelTop - 0.5f, "the arrow starts under the panel edge");
  check(insideCircle(arrowCenterX - 18.0f - 2.5f, arrowCenterY + 16.5f + 2.5f),
        "the arrow stem is inside the round aperture");
  // Its head's outer corner is 35 px left of and 4.5 px above the centre.
  check(insideCircle(arrowCenterX - 35.0f - 2.5f, arrowCenterY - 4.5f + 2.5f),
        "the U-turn arrow head is inside the round aperture");

  // The sign sits across the panel edge, inside the aperture, and off the
  // route's centre column and rider marker (18 px either side of centre).
  const float reach = SpeedSignStyle::diameter / 2 + SpeedSignStyle::halo;
  check(SpeedSignStyle::centerY - reach < panelTop && SpeedSignStyle::centerY + reach > panelTop,
        "the sign sits across the panel's upper edge");
  check(SpeedSignStyle::centerX - reach > kCenter + 18.0f + 6.0f, "the sign is clear of the rider marker");
  puts("instruction layout: distance texts, unit, arrow and sign fit the round panel without touching");
}
