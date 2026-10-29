#include "ui_state.h"

namespace {
UiScreen resolveScreen(const UiInputs& inputs) {
  if (!inputs.displayAvailable || !inputs.displayOn) return UiScreen::Off;
  if (inputs.pairing) return UiScreen::Pairing;

  if (!inputs.connected) {
    if (inputs.tripEnded) return UiScreen::Brand;
    if (inputs.hadConnection) return UiScreen::ConnectionLost;
    return UiScreen::Brand;
  }

  if (!inputs.hasNavigation) {
    if (!inputs.paired) return UiScreen::NotPaired;
    if (inputs.tripEnded) return UiScreen::Brand;
    return inputs.clockSynced ? UiScreen::Clock : UiScreen::Brand;
  }

  // A cached route is context only, even if its maneuver was STOP/ARRIVED.
  if (inputs.rerouting) {
    if (inputs.routePointCount < 2) return UiScreen::Updating;
    return inputs.packetTimedOut ? UiScreen::WaitingPhone : UiScreen::CachedRoute;
  }
  if (inputs.navigation.direction == Direction::Stop) return UiScreen::NoGuidance;
  // The app stops sending after arrival; that final page must never expire.
  if (inputs.navigation.direction == Direction::Arrived) return UiScreen::Arrived;
  if (inputs.packetTimedOut) return UiScreen::StaleGuidance;
  return UiScreen::Navigating;
}
}  // namespace

UiState resolveUiState(const UiInputs& inputs) {
  return {resolveScreen(inputs), inputs.connected, inputs.navigation};
}

const char* uiScreenName(UiScreen screen) {
  switch (screen) {
    case UiScreen::Off: return "off";
    case UiScreen::Pairing: return "pairing";
    case UiScreen::Brand: return "brand";
    case UiScreen::Clock: return "clock";
    case UiScreen::NotPaired: return "not_paired";
    case UiScreen::ConnectionLost: return "connection_lost";
    case UiScreen::Updating: return "updating";
    case UiScreen::CachedRoute: return "cached_route";
    case UiScreen::WaitingPhone: return "waiting_phone";
    case UiScreen::NoGuidance: return "no_guidance";
    case UiScreen::StaleGuidance: return "stale_guidance";
    case UiScreen::Navigating: return "navigating";
    case UiScreen::Arrived: return "arrived";
  }
  return "unknown";
}
