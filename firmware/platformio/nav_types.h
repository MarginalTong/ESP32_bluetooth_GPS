#pragma once

#include <stdint.h>

enum class Direction : uint8_t {
  Up,
  Left,
  Right,
  BearLeft,
  BearRight,
  UTurn,
  Stop,
  Arrived,
  Unknown,
};

struct NavState {
  Direction direction;
  int distanceMeters;
  // Posted limit where the rider is, km/h; 0 when unknown (no sign shown).
  uint8_t speedLimitKph;
};
