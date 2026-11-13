#pragma once

// Map animation, shared by the firmware and the host test (map_motion_test).
#include <math.h>
#include <stdint.h>

// Display-only interpolation. Never used for maneuver or distance decisions.
// Each packet starts a linear glide from where the map is drawn now to the
// new geometry, lasting about one packet interval, so ~1 Hz updates read as
// continuous motion instead of a short hop followed by a pause.
struct MapMotion {
  // 20 route points, then 2 side-road segments (x0, y0, x1, y1 each).
  static constexpr uint8_t kRouteValues = 40;
  static constexpr uint8_t kValues = kRouteValues + 8;
  static constexpr uint32_t kMinDurationMs = 120;
  static constexpr uint32_t kMaxDurationMs = 1100;
  // Longer gaps are pauses (phone stopped sending), not the packet rate.
  static constexpr uint32_t kMaxIntervalMs = 3000;
  // Larger moves, in route-source units, are route changes: no glide.
  static constexpr float kSnapDistance = 24.0f;
  float current[kValues] = {};
  float start[kValues] = {};
  float target[kValues] = {};
  uint8_t routes = 0, roads = 0;
  uint32_t started = 0, durationMs = 0, lastPacket = 0;
  float packetIntervalMs = 1000.0f;
  bool valid = false, active = false;

  bool tick(uint32_t now) {
    if (!active) return false;
    const uint32_t elapsed = now - started;
    const float t = elapsed >= durationMs ? 1.0f : float(elapsed) / durationMs;
    for (int i = 0; i < kValues; ++i)
      current[i] = start[i] + (target[i] - start[i]) * t;
    active = elapsed < durationMs;
    return true;
  }

  bool jumped(const float* values, int from, int to) const {
    for (int i = from; i < to; ++i)
      if (fabsf(values[i] - current[i]) > kSnapDistance) return true;
    return false;
  }

  void accept(const float* values, uint8_t routeCount, uint8_t roadCount,
              uint32_t now) {
    tick(now);
    if (valid && now - lastPacket <= kMaxIntervalMs)
      packetIntervalMs += (float(now - lastPacket) - packetIntervalMs) * 0.3f;
    lastPacket = now;
    // The route and the side roads snap independently, so a side road
    // appearing does not make the route jump.
    const bool snapRoute =
        !valid || routes != routeCount || jumped(values, 0, kRouteValues);
    const bool snapRoads =
        !valid || roads != roadCount || jumped(values, kRouteValues, kValues);
    bool changed = snapRoute || snapRoads;
    for (int i = 0; i < kValues; ++i) changed = changed || values[i] != target[i];
    if (!changed) return;
    routes = routeCount;
    roads = roadCount;
    for (int i = 0; i < kValues; ++i) {
      const bool snap = i < kRouteValues ? snapRoute : snapRoads;
      start[i] = snap ? values[i] : current[i];
      target[i] = values[i];
      if (snap) current[i] = values[i];
    }
    const float interval = packetIntervalMs < kMinDurationMs ? kMinDurationMs
                           : packetIntervalMs > kMaxDurationMs ? kMaxDurationMs
                                                               : packetIntervalMs;
    durationMs = uint32_t(interval);
    started = now;
    valid = true;
    active = !(snapRoute && snapRoads);
  }
};
