// Run with: bash firmware/tests/run_map_motion_test.sh
// The runner prepends the actual MapMotion implementation from the sketch.
#include <assert.h>

int main() {
  MapMotion motion;
  float p[20] = {};
  p[0] = 64;
  p[1] = 34;
  motion.accept(p, 2, 1, 0, 0);
  assert(motion.current[0] == 64 && !motion.active);
  p[2] = 10;
  p[12] = 10;
  motion.accept(p, 2, 1, 0, 100);
  motion.tick(190);
  assert(motion.current[2] == 5 && motion.current[12] == 5);
  assert(motion.current[0] == 64 && motion.current[1] == 34);
  // Identical packets must not restart an in-flight transition.
  motion.accept(p, 2, 1, 0, 190);
  motion.tick(280);
  assert(motion.current[2] == 10 && !motion.active);
  p[2] = 20;
  motion.accept(p, 2, 1, 0, 300);
  motion.tick(390);
  p[2] = 22;
  motion.accept(p, 2, 1, 0, 390);
  assert(motion.current[2] == 15);
  motion.tick(570);
  assert(motion.current[2] == 22);
  // Maneuver/count changes and large jumps snap immediately.
  p[2] = 23;
  motion.accept(p, 2, 1, 1, 600);
  assert(motion.current[2] == 23 && !motion.active);
  p[2] = 24;
  motion.accept(p, 3, 0, 1, 700);
  assert(motion.current[2] == 24 && !motion.active);
  p[2] = 80;
  motion.accept(p, 3, 0, 1, 800);
  assert(motion.current[2] == 80 && !motion.active);
  // millis() wraparound still completes the transition.
  p[2] = 81;
  motion.accept(p, 3, 0, 1, UINT32_MAX - 90);
  motion.tick(100);
  assert(motion.current[2] == 81 && !motion.active);
  motion.valid = false;
  p[2] = 82;
  motion.accept(p, 3, 0, 1, 200);
  assert(motion.current[2] == 82 && !motion.active);
}
