// Run with: bash firmware/tests/run_map_motion_test.sh
// The runner prepends the actual MapMotion implementation from the sketch.
#include <assert.h>

static bool near(float a, float b) { return fabsf(a - b) < 0.01f; }

int main() {
  MapMotion motion;
  const int road = MapMotion::kRouteValues;
  float p[MapMotion::kValues] = {};
  p[0] = 64;
  p[1] = 34;
  motion.accept(p, 2, 1, 0);
  assert(motion.current[0] == 64 && !motion.active);

  // A glide lasts one packet interval and moves linearly.
  p[2] = 10;
  p[road] = 10;
  motion.accept(p, 2, 1, 1000);
  assert(motion.durationMs == 1000);
  motion.tick(1500);
  assert(near(motion.current[2], 5) && near(motion.current[road], 5));
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
  p[road] = 12;
  motion.accept(p, 3, 1, now);
  assert(motion.current[2] == 34 && motion.current[4] == 40);
  assert(motion.current[road] == 10 && motion.active);
  motion.tick(now += 5000);
  // A side road appearing snaps only the side roads.
  p[2] = 35;
  p[road + 4] = 50;
  motion.accept(p, 3, 2, now);
  assert(motion.current[2] == 34 && motion.current[road + 4] == 50 && motion.active);
  motion.tick(now += 5000);
  // A large jump is a new route, not motion.
  p[2] = 80;
  p[road] = 80;
  motion.accept(p, 3, 2, now);
  assert(motion.current[2] == 80 && motion.current[road] == 80 && !motion.active);

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
