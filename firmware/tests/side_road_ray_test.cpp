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

  check(!planSideRoadRay(200, 100, 300, 100, 48, rect, ray),
        "a ray running past the map edge is omitted, not clipped");
  check(!planSideRoadRay(100, 180, 100, 300, 48, rect, ray),
        "a ray running into the instruction area is omitted");

  check(planSideRoadRay(120, 120, 200, 120, 48, round, ray),
        "a ray inside the round aperture is drawn");
  check(!planSideRoadRay(40, 40, 0, 40, 20, round, ray),
        "a ray in the round panel's corner is omitted");

  printf("side road ray: fixed length, direction-only and fit checks passed\n");
  return 0;
}
