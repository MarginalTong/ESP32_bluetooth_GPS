#pragma once

// Side roads on the mini map are schematic: a ray of one standard length
// from the route junction in the road's direction. Real segment lengths vary
// wildly and must not change how long a branch looks on this small display.
#include <math.h>
#include <stdint.h>

// The look of a side road, in one place (recorded in firmware/README.md):
// a dark gray line, so branches read as context and never compete with the
// white route, fading from the junction to nothing at the tail.
namespace SideRoadStyle {
constexpr float halfWidth = 2.5f;  // map pixels; about 5 px wide
constexpr uint8_t peak = 150;      // gray level at the junction, of 255
// Ray length in map pixels (240-px layout): round panel, rectangular panel.
constexpr float roundLength = 90.0f;
constexpr float rectLength = 56.0f;
// A ray shortened below this many map pixels is a speck, not a road.
constexpr float minLength = 12.0f;
}  // namespace SideRoadStyle

struct SideRoadRay {
  float x0, y0;  // junction, map pixels
  float ux, uy;  // unit direction away from the route
  float length;  // map pixels
};

// Where a ray may be drawn, in map pixels. `radius` 0 means a rectangular
// panel; otherwise the ray must also lie inside the round aperture.
struct SideRoadArea {
  float width, clipBottom;
  float centerX, centerY, radius;
};

// The phone orders each branch from its route junction towards its outer
// endpoint (x1, y1); only that direction is used. A ray that would leave the
// map is shortened to fit, so a junction shows as soon as it enters the map
// and its branch grows as it comes closer; the fade still ends at the tail.
// Returns false for a branch with no direction, a junction outside the map,
// or a ray left too short to read as a road.
inline bool planSideRoadRay(float x0, float y0, float x1, float y1, float length,
                            const SideRoadArea& area, SideRoadRay& ray) {
  const float dx = x1 - x0, dy = y1 - y0;
  const float span = sqrtf(dx * dx + dy * dy);
  // Under a pixel the direction is noise.
  if (!(span >= 1.0f)) return false;
  ray = {x0, y0, dx / span, dy / span, length};
  // Pixels kept clear of the map edge and the round bezel.
  constexpr float margin = 6.0f;
  const auto inside = [&](float along) {
    const float x = x0 + ray.ux * along, y = y0 + ray.uy * along;
    if (x < margin || x >= area.width - margin || y < margin ||
        y >= area.clipBottom - margin)
      return false;
    if (area.radius <= 0.0f) return true;
    const float cx = x - area.centerX, cy = y - area.centerY;
    const float visible = area.radius - margin;
    return cx * cx + cy * cy <= visible * visible;
  };
  if (!inside(0.0f)) return false;
  if (!inside(length)) {
    // The drawable area is convex, so the ray leaves it exactly once:
    // bisect for that point (10 steps: well under a pixel).
    float fits = 0.0f, leaves = length;
    for (int i = 0; i < 10; ++i) {
      const float middle = (fits + leaves) / 2.0f;
      (inside(middle) ? fits : leaves) = middle;
    }
    ray.length = fits;
  }
  return ray.length >= SideRoadStyle::minLength;
}
