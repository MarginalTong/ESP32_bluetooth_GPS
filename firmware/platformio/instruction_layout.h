#pragma once

// Where the round panel's instruction area puts its parts, in one place
// (recorded in firmware/README.md), shared by the firmware and the host test
// (instruction_layout_test). Canvas pixels of the 240-px layout.
//
// Below the map, on black: the turn arrow on the left, the distance in the
// middle with its smaller unit on the right, and the speed limit sign on the right,
// sitting across the line where the map ends.
#include <stdint.h>

namespace InstructionLayout {
// First row of the instruction area; the map is clipped above it.
constexpr float panelTop = 162.0f;

// Arrow artwork centre: its 33 px height just fits under the map's edge,
// level with the distance digits.
constexpr float arrowCenterX = 62.0f;
constexpr float arrowCenterY = 183.5f;

// Right-align numbers to a fixed unit column so changing digit counts never
// pushes m/km down or into the sign. Measured with the bundled font: three
// digits at size 4 need 66.99 px; km at size 2 needs 27.57 px.
constexpr float distanceRight = 160.0f;
constexpr float distanceTop = 168.0f;  // top of the capitals
constexpr uint8_t distanceSize = 4;    // capitals 7 px per size step: 28 px
// Leaves at least 3 px after the widest arrow (right edge 88.5).
constexpr float distanceMaxWidth = 68.0f;
constexpr uint8_t unitSize = 2;        // 14 px
constexpr float unitGap = 3.0f;        // horizontal space before m/km

// Preserve the previous diagnostic line; changing units must not move errors.
constexpr float errorTop = 214.0f;

struct DistancePlace {
  uint8_t size;
  float numberLeft, numberTop;
  float unitLeft, unitTop;
};

// `fullWidth` is measured at distanceSize. All sizes share the same bottom
// edge; very long kilometre values may step down to size 1 to stay in bounds.
inline DistancePlace placeDistance(float fullWidth) {
  uint8_t size = distanceSize;
  while (size > 1 && fullWidth * size / distanceSize > distanceMaxWidth) --size;
  const float left = distanceRight - fullWidth * size / distanceSize;
  const float bottom = distanceTop + 7.0f * distanceSize;
  return {size, left, bottom - 7.0f * size,
          distanceRight + unitGap, bottom - 7.0f * unitSize};
}
}  // namespace InstructionLayout
