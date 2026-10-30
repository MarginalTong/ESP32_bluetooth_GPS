#pragma once
#include <stdint.h>

// Main-loop only. Duplicate ARRIVED packets never restart the celebration.
class ArrivalFeedback {
 public:
  static constexpr uint32_t durationMs = 4000;
  void update(bool arrived, uint32_t now) {
    if (arrived && !active_) started_ = now;
    active_ = arrived;
  }
  uint32_t elapsed(uint32_t now) const { return active_ ? now - started_ : 0; }
 private:
  bool active_ = false;
  uint32_t started_ = 0;
};
