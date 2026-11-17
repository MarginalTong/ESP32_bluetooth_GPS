#pragma once

// Where the round panel's instruction area puts its parts, in one place
// (recorded in firmware/README.md), shared by the firmware and the host test
// (instruction_layout_test). Canvas pixels of the 240-px layout.
//
// Below the map is a slightly lighter panel: the turn arrow on the left, the
// distance in the middle with its unit underneath, and the speed limit sign
// on the right, sitting across the panel's upper edge.
#include <stdint.h>

namespace InstructionLayout {
// First row of the panel; the map is clipped above it.
constexpr float panelTop = 162.0f;
// Gray level of the panel, of 255: enough to separate it from the black map
// without lowering the contrast of the white arrow and digits.
constexpr uint8_t panelLevel = 28;

// Arrow artwork centre: its 33 px height just fits under the panel's edge,
// level with the distance digits.
constexpr float arrowCenterX = 62.0f;
constexpr float arrowCenterY = 183.5f;

// Distance digits: centred between the arrow and the speed limit sign.
constexpr float distanceCenterX = 134.0f;
constexpr float distanceTop = 168.0f;  // top of the capitals
constexpr uint8_t distanceSize = 4;    // capitals 7 px per size step: 28 px
// Widest text drawn at full size, from 4 px right of the arrow to 3 px left
// of the sign; wider text ("NOW") is drawn one size smaller.
constexpr float distanceMaxWidth = 76.0f;
constexpr uint8_t unitSize = 2;        // 14 px
constexpr float unitGap = 3.0f;        // between the digits and the unit

// Diagnostic line under the unit, where the aperture is narrowest.
constexpr float errorTop = unitGap + distanceTop + 7.0f * distanceSize + 7.0f * unitSize + 1.0f;

struct DistancePlace {
  uint8_t size;
  float numberLeft, numberTop;
  float unitLeft, unitTop;
};

// The text centred, the unit under its left edge. `fullWidth` is the text's
// width at distanceSize; smaller text stays centred on the same line.
inline DistancePlace placeDistance(float fullWidth) {
  const uint8_t size = fullWidth > distanceMaxWidth ? distanceSize - 1 : distanceSize;
  const float left = distanceCenterX - fullWidth * size / distanceSize / 2.0f;
  const float top = distanceTop + 7.0f * (distanceSize - size) / 2.0f;
  return {size, left, top, left, distanceTop + 7.0f * distanceSize + unitGap};
}
}  // namespace InstructionLayout
