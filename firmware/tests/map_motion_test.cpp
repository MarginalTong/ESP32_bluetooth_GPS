// Run with: bash firmware/tests/run_map_motion_test.sh
#include <assert.h>

#include "map_motion.h"

static bool near(float a, float b) { return fabsf(a - b) < 0.01f; }

int main() {
  static_assert(MapMotion::kValues == 40 + 8 * 4,
                "20 route points and 8 side-road segments");
  MapMotion motion;
  const int road = MapMotion::kRouteValues;
  float p[MapMotion::kValues] = {};
  p[0] = 64;
  p[1] = 34;
  // One side road: junction (20, 10), arm to the right.
  p[road] = 20, p[road + 1] = 10, p[road + 2] = 30, p[road + 3] = 10;
  motion.accept(p, 2, 1, 0);
  assert(motion.current[0] == 64 && !motion.active);

  // A glide lasts one packet interval and moves linearly.
  p[2] = 10;
  p[road + 1] = p[road + 3] = 12;
  motion.accept(p, 2, 1, 1000);
  assert(motion.durationMs == 1000);
  motion.tick(1500);
  assert(near(motion.current[2], 5) && near(motion.current[road + 1], 11));
  assert(motion.current[0] == 64 && motion.current[1] == 34);
  // Identical packets must not restart an in-flight glide.
  motion.accept(p, 2, 1, 1500);
  motion.tick(1999);
  assert(motion.active);
  motion.tick(2000);
  assert(motion.current[2] == 10 && !motion.active);

  // A new target mid-glide continues from where the map is drawn.
  p[2] = 20;
  motion.accept(p, 2, 1, 3000);
  motion.tick(3000 + motion.durationMs / 2);
  const float drawn = motion.current[2];
  assert(drawn > 10 && drawn < 20);
  p[2] = 30;
  motion.accept(p, 2, 1, 3000 + motion.durationMs / 2);
  assert(motion.current[2] == drawn && motion.start[2] == drawn && motion.active);
  motion.tick(10000);
  assert(motion.current[2] == 30 && !motion.active);

  // The duration follows the packet rate, within limits.
  uint32_t now = 20000;
  for (int i = 0; i < 40; ++i) {
    p[2] = 30 + (i % 2);
    motion.accept(p, 2, 1, now += 50);
  }
  assert(motion.durationMs == MapMotion::kMinDurationMs);
  for (int i = 0; i < 40; ++i) {
    p[2] = 30 + (i % 2);
    motion.accept(p, 2, 1, now += 2500);
  }
  assert(motion.durationMs == MapMotion::kMaxDurationMs);
  // A long pause is not taken as the packet rate.
  const float interval = motion.packetIntervalMs;
  p[2] = 33;
  motion.accept(p, 2, 1, now += 60000);
  assert(motion.packetIntervalMs == interval);
  motion.tick(now += 5000);

  // A route-shape change snaps the route but lets the side roads glide.
  p[2] = 34;
  p[4] = 40;
  p[road + 1] = p[road + 3] = 13;
  motion.accept(p, 3, 1, now);
  assert(motion.current[2] == 34 && motion.current[4] == 40);
  assert(motion.current[road + 1] == 12 && motion.active);
  motion.tick(now += 5000);
  // A side road appearing is drawn in place; nothing else jumps.
  p[2] = 35;
  p[road + 4] = 20, p[road + 5] = 2, p[road + 6] = 30, p[road + 7] = 2;
  motion.accept(p, 3, 2, now);
  assert(motion.current[2] == 34 && motion.current[road + 5] == 2 && motion.active);
  assert(motion.current[road + 1] == 13);
  motion.tick(now += 5000);
  // A large jump is a new route, not motion.
  p[2] = 80;
  p[road] = 80;
  motion.accept(p, 3, 2, now);
  assert(motion.current[2] == 80 && motion.current[road] == 80 && !motion.active);

  // Side roads are followed by position, not by slot. Two junctions, each
  // with one arm to the right; the rider passes the near one.
  {
    MapMotion m;
    float q[MapMotion::kValues] = {};
    const auto arm = [&](int slot, float y) {
      float* s = q + road + slot * 4;
      s[0] = 64, s[1] = y, s[2] = 74, s[3] = y;
    };
    arm(0, 30);
    arm(1, 20);
    m.accept(q, 0, 2, 0);
    // The near arm leaves; the far one takes slot 0, 2 units closer.
    arm(0, 22);
    arm(1, 0);
    q[road + 4] = q[road + 6] = 0;
    m.accept(q, 0, 1, 1000);
    assert(m.current[road + 1] == 20 && m.active);  // glides on from y = 20
    m.tick(1000 + m.durationMs);
    assert(m.current[road + 1] == 22);
    // A new junction comes into view ahead: it appears in place, and the
    // arm already drawn keeps gliding instead of jumping slots.
    arm(0, 24);
    arm(1, 6);
    m.accept(q, 0, 2, 2000);
    assert(m.current[road + 1] == 22 && m.current[road + 5] == 6);
    // The opposite arm of the same junction is a different road.
    m.tick(2000 + m.durationMs);
    q[road + 2] = 54;
    m.accept(q, 0, 2, 3000);
    assert(m.current[road + 2] == 54);
  }

  // millis() wraparound still completes the glide.
  p[2] = 81;
  motion.accept(p, 3, 2, UINT32_MAX - 90);
  motion.tick(motion.durationMs);
  assert(motion.current[2] == 81 && !motion.active);
  motion.valid = false;
  p[2] = 82;
  motion.accept(p, 3, 2, 2000);
  assert(motion.current[2] == 82 && !motion.active);
}
