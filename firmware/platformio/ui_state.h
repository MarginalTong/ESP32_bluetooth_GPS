#pragma once

#include "nav_types.h"

// The only place where connection/navigation facts are turned into a page.
// No Arduino, BLE or drawing dependencies: the same resolver runs in host tests.
enum class UiScreen : uint8_t {
  Off,
  Pairing,
  Brand,
  Clock,
  NotPaired,
  ConnectionLost,
  Updating,
  CachedRoute,
  WaitingPhone,
  NoGuidance,
  StaleGuidance,
  Navigating,
  Arrived,
};

struct UiInputs {
  bool displayAvailable = false;
  bool displayOn = true;  // Dim is still visible; only Off suppresses drawing.
  bool pairing = false;
  bool paired = false;
  bool connected = false;
  bool hadConnection = false;
  bool hasNavigation = false;
  bool tripEnded = false;
  bool clockSynced = false;
  bool rerouting = false;
  bool packetTimedOut = false;
  uint8_t routePointCount = 0;
  NavState navigation = {Direction::Stop, 0};
};

struct UiState {
  UiScreen screen = UiScreen::Off;
  bool connected = false;  // Brand/clock subtitle, not another page decision.
  NavState navigation = {Direction::Stop, 0};
};

UiState resolveUiState(const UiInputs& inputs);
const char* uiScreenName(UiScreen screen);
