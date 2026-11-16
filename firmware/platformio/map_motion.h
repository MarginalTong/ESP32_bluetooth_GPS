#pragma once

// Map animation, shared by the firmware and the host test (map_motion_test).
#include <math.h>
#include <stdint.h>

// Display-only interpolation. Never used for maneuver or distance decisions.
// Each packet starts a linear glide from where the map is drawn now to the
// new geometry, lasting about one packet interval, so ~1 Hz updates read as
// continuous motion instead of a short hop followed by a pause.
struct MapMotion {
  // 20 route points, then up to 8 side-road segments (x0, y0, x1, y1 each):
  // every junction arm the map can show at once. Matches the app's
  // SideRoadPreview.maxSegments.
  static constexpr uint8_t kRouteValues = 40;
  static constexpr uint8_t kRoadSegments = 8;
  static constexpr uint8_t kValues = kRouteValues + kRoadSegments * 4;
  static constexpr uint32_t kMinDurationMs = 120;
  static constexpr uint32_t kMaxDurationMs = 1100;
  // Longer gaps are pauses (phone stopped sending), not the packet rate.
  static constexpr uint32_t kMaxIntervalMs = 3000;
  // Larger moves, in route-source units, are route changes: no glide.
  static constexpr float kSnapDistance = 24.0f;
  // A side road is the same arm as a drawn one when its junction moved at
  // most this far (route-source units; about 30 m, one packet at 110 km/h)
  // and not more than kRoadBacktrack away from the rider (GPS jitter).
  static constexpr float kRoadMatchDistance = 5.0f;
  static constexpr float kRoadBacktrack = 1.0f;
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

  // The segment among the `count` drawn ones that is the same junction arm
  // as `next`, or null. Slots are reordered whenever a junction passes or a
  // new one comes into view, so an arm is followed by position, not by slot:
  // otherwise it would slide from one junction to another.
  static const float* sameRoad(const float* next, const float* drawn, uint8_t count) {
    const float* best = nullptr;
    float bestDistance = kRoadMatchDistance;
    for (uint8_t j = 0; j < count; ++j) {
      const float* old = drawn + j * 4;
      // Opposite arms of one junction share its position.
      const float along = (old[2] - old[0]) * (next[2] - next[0]) +
                          (old[3] - old[1]) * (next[3] - next[1]);
      // A junction only comes closer (y grows towards the rider).
      if (along <= 0.0f || old[1] > next[1] + kRoadBacktrack) continue;
      const float dx = next[0] - old[0], dy = next[1] - old[1];
      const float distance = sqrtf(dx * dx + dy * dy);
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = old;
      }
    }
    return best;
  }

  void accept(const float* values, uint8_t routeCount, uint8_t roadCount,
              uint32_t now) {
    tick(now);
    if (valid && now - lastPacket <= kMaxIntervalMs)
      packetIntervalMs += (float(now - lastPacket) - packetIntervalMs) * 0.3f;
    lastPacket = now;
    const bool snapRoute =
        !valid || routes != routeCount || jumped(values, 0, kRouteValues);
    bool changed = snapRoute || roads != roadCount;
    for (int i = 0; i < kValues; ++i) changed = changed || values[i] != target[i];
    if (!changed) return;
    for (int i = 0; i < kRouteValues; ++i) {
      start[i] = snapRoute ? values[i] : current[i];
      target[i] = values[i];
      if (snapRoute) current[i] = values[i];
    }
    // Each side road glides from the arm it continues; a new arm appears in
    // place, so the route never jumps because a side road appeared.
    float drawn[kRoadSegments * 4];
    for (int i = 0; i < kRoadSegments * 4; ++i) drawn[i] = current[kRouteValues + i];
    const uint8_t drawnCount = valid ? roads : 0;
    for (uint8_t r = 0; r < kRoadSegments; ++r) {
      const float* next = values + kRouteValues + r * 4;
      const float* from = r < roadCount ? sameRoad(next, drawn, drawnCount) : nullptr;
      for (int k = 0; k < 4; ++k) {
        const int i = kRouteValues + r * 4 + k;
        target[i] = next[k];
        start[i] = current[i] = from != nullptr ? from[k] : next[k];
      }
    }
    routes = routeCount;
    roads = roadCount;
    const float interval = packetIntervalMs < kMinDurationMs ? kMinDurationMs
                           : packetIntervalMs > kMaxDurationMs ? kMaxDurationMs
                                                               : packetIntervalMs;
    durationMs = uint32_t(interval);
    started = now;
    valid = true;
    active = false;
    for (int i = 0; i < kValues; ++i) active = active || start[i] != target[i];
  }
};
