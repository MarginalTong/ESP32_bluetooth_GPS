#include <stdio.h>
#include <stdlib.h>

#include "side_road_ray.h"

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
  }
}

int main() {
  const SideRoadArea rect = {240, 200, 0, 0, 0};
  const SideRoadArea round = {240, 240, 120, 120, 120};
  SideRoadRay ray;

  // The ray keeps its fixed length whatever the real segment length.
  check(planSideRoadRay(100, 100, 100 + 300, 100, 48, rect, ray),
        "a long branch is drawn");
  check(ray.ux == 1 && ray.uy == 0 && ray.length == 48,
        "only the branch direction is used");
  check(planSideRoadRay(100, 100, 100, 103, 48, rect, ray) && ray.uy == 1,
        "a short branch gets the same ray length");

  check(!planSideRoadRay(100, 100, 100.5f, 100, 48, rect, ray),
        "under a pixel has no direction");
  check(!planSideRoadRay(100, 100, NAN, 100, 48, rect, ray),
        "a NaN endpoint is not drawn");

  // A ray that would leave the map is shortened to fit, not dropped.
  check(planSideRoadRay(200, 100, 300, 100, 48, rect, ray),
        "a ray running past the map edge is still drawn");
  check(ray.length > 32 && ray.length <= 34,
        "it stops at the 6 px margin inside the edge");
  check(planSideRoadRay(100, 170, 100, 300, 48, rect, ray) &&
            ray.length > 22 && ray.length <= 24,
        "a ray towards the instruction area stops above it");
  check(planSideRoadRay(228, 100, 300, 100, 48, rect, ray) && ray.length < 7,
        "a junction at the edge still shows its branch, however short");
  check(!planSideRoadRay(238, 100, 300, 100, 48, rect, ray),
        "a junction outside the map is omitted");

  check(planSideRoadRay(120, 120, 200, 120, 48, round, ray) && ray.length == 48,
        "a ray inside the round aperture keeps its full length");
  // Junction near the top of the round panel: the chord there is short.
  check(planSideRoadRay(120, 12, 200, 12, 90, round, ray),
        "a far junction shows as soon as it is inside the aperture");
  check(ray.length > 30 && ray.length < 40,
        "its ray ends at the round bezel");
  check(!planSideRoadRay(30, 30, 0, 30, 20, round, ray),
        "a junction outside the round aperture is omitted");

  printf("side road ray: direction-only, shortened-to-fit and omission checks passed\n");
  return 0;
}
