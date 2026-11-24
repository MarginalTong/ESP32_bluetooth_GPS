#pragma once
#include "nav_types.h"

// Link/clock events cannot end a trip. Only signed END does that; ARRIVED
// completes through the existing local animation, even without a link.
struct NavigationContinuity {
  bool active = false;
  bool awaitingFresh = false;
  NavState lastValid = {Direction::Stop, 0, 0};
  void linkLost() { if (active) awaitingFresh = true; }
  void accept(const NavState& state, bool ended, bool contextOnly, bool geometry = false) {
    if (ended) {
      active = awaitingFresh = false;
      lastValid = {Direction::Stop, 0, 0};
    } else if (contextOnly || state.direction == Direction::Stop) {
      if (geometry) active = true;
      if (active) awaitingFresh = true;
    } else {
      active = true; awaitingFresh = false; lastValid = state;
    }
  }
};

// HMAC and connection nonce are verified before this gate. Expiry is optional
// for older phones; newer phones bound the lifetime of measured guidance.
struct PacketWindow {
  uint32_t highest = 0;
  void reset() { highest = 0; }
  bool accept(uint32_t n, bool hasExpiry, uint32_t expiry,
              int64_t nowUtc, bool clockReady) {
    if (n <= highest) return false;
    if (hasExpiry && (!clockReady || expiry < nowUtc || expiry > nowUtc + 20))
      return false;
    highest = n; return true;
  }
};
