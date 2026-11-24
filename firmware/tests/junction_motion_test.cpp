#include <assert.h>
#include "map_motion.h"

// Phone packets at 1 Hz, display ticks at 40 Hz. In the app's 128x64 frame
// the cursor is (64,34); a passed junction must keep going past y=34.
int main() {
  MapMotion motion;
  float packet[MapMotion::kValues] = {};
  packet[0] = 64;
  packet[1] = 34;
  const int arm = MapMotion::kRouteValues;
  packet[arm] = 64;
  packet[arm + 2] = 74;
  packet[arm + 1] = packet[arm + 3] = 32;
  motion.accept(packet, 2, 1, 0);
  float previous = 32;
  for (uint32_t second = 1; second <= 4; ++second) {
    const float target = 32 + second * 1.6f;
    packet[arm + 1] = packet[arm + 3] = target;
    motion.accept(packet, 2, 1, second * 1000);
    for (uint32_t frame = 25; frame <= 1000; frame += 25) {
      motion.tick(second * 1000 + frame);
      const float y = motion.current[arm + 1];
      assert(y >= previous && y <= target);
      assert(y - previous < 0.05f);
      assert(motion.current[0] == 64 && motion.current[1] == 34);
      previous = y;
    }
  }
  assert(previous > 34);
  // Without a new reliable sample the picture stops, never predicts forever.
  motion.tick(600000);
  assert(motion.current[arm + 1] == previous && !motion.active);
  motion.accept(packet, 2, 0, 601000);
  assert(motion.roads == 0);
}
