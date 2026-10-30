#include "ui_screens.h"
#include "ui_draw.h"

namespace {
// Insets keep the compact wordmark inside the round aperture. Draw it only on
// idle/status pages: route and maneuver pixels always belong to navigation.
void drawCompactBrand() {
#if NAV_WAVESHARE_146
  drawUiText("NAVIO", 2, 38, 38);
#else
  drawUiText("NAVIO", 2, 12, 8);
#endif
}

void drawDisconnectedBrand(const char* subtitle) {
#if NAV_WAVESHARE_146
  if (useNativeLayer()) {
    drawRoundCenteredStatus("NAVIO", 5, subtitle, 1);
  } else {
    drawStandbyBrandText("NAVIO", true);
    drawStandbyBrandText(subtitle, false);
  }
#else
  drawUiText("NAVIO", 4, 60, 35);
  drawUiText(subtitle, 1, (240 - uiTextWidth(subtitle, 1)) / 2, 91);
#endif
}

void drawBrand(const UiState& state) {
  if (!state.connected) {
    drawDisconnectedBrand("CONNECT PHONE");
    return;
  }
  drawCompactBrand();
#if NAV_WAVESHARE_146
  drawRoundCenteredStatus("READY TO GO", 2, nullptr, 1);
#else
  drawUiText("ready to go", 2, 54, 65);
#endif
}

void drawClock(const UiState& state, const UiRenderContext& context) {
  if (!state.connected) {
    drawDisconnectedBrand("CONNECT PHONE");
    return;
  }
  drawCompactBrand();
#if NAV_WAVESHARE_146
  drawRoundCenteredStatus(context.clockText, 7, "ready to go", 2);
#else
  drawUiText(context.clockText, 7, 15, 30);
  drawUiText("ready to go", 2, 54, 99);
#endif
}

void drawPairing(const UiRenderContext& context) {
#if NAV_WAVESHARE_146
  drawRoundCenteredText(context.deviceName, 1, 60);
  drawRoundCenteredStatus("PRESS BOOT", 2, "TO PAIR", 1);
#else
  drawUiText(context.deviceName, 1, 12, 12);
  drawUiText("PRESS BOOT", 2, 54, 51);
  drawUiText("TO PAIR", 1, 67, 108);
#endif
}

void drawNotPaired() {
  drawCompactBrand();
#if NAV_WAVESHARE_146
  drawRoundCenteredStatus("NOT PAIRED", 2, "PAIR IN THE APP", 1);
#else
  drawUiText("NOT PAIRED", 2, 60, 40);
  drawUiText("PAIR IN THE APP", 1, 75, 80);
#endif
}

void drawConnectionLost() {
  drawDisconnectedBrand("CONNECTION LOST");
#if NAV_WAVESHARE_146
  drawRoundCenteredText("RECONNECT PHONE", 1, 177);
#else
  drawUiText("RECONNECT PHONE", 1, 75, 113);
#endif
}

void drawUpdating(const UiState& state, const UiRenderContext& context) {
#if !NAV_WAVESHARE_146
  (void)context;  // The original rectangular panel has fixed text positions.
#endif
  if (state.screen == UiScreen::Updating) {
#if NAV_WAVESHARE_146
    drawRoundCenteredText("UPDATING...", 1,
        (context.screenHeight - roundTextHeight("UPDATING...", 1)) / 2);
#else
    drawUiText("UPDATING...", 1, 84, 62);
#endif
    return;
  }

  drawMiniRouteMap(false, state.navigation.direction);
  const bool waiting = state.screen == UiScreen::WaitingPhone;
#if NAV_WAVESHARE_146
  drawRoundCenteredText(waiting ? "WAITING PHONE" : "CACHED ROUTE", 1, 177);
  drawRoundCenteredText("UPDATING...", 1, 200);
#else
  drawUiText(waiting ? "WAITING PHONE" : "CACHED ROUTE", 1, waiting ? 71 : 76, 104);
  drawUiText("UPDATING...", 1, 83, 118);
#endif
}

void drawNoGuidance(const UiRenderContext& context) {
#if !NAV_WAVESHARE_146
  (void)context;
#endif
#if NAV_WAVESHARE_146
  drawRoundCenteredText("NO GUIDANCE", 1,
      (context.screenHeight - roundTextHeight("NO GUIDANCE", 1)) / 2);
#else
  drawUiText("NO GUIDANCE", 1, 84, 62);
#endif
}

void drawStaleGuidance(const UiState& state, const UiRenderContext& context) {
  drawMiniRouteMap(false, state.navigation.direction);
  drawDirection(state.navigation.direction);
#if NAV_WAVESHARE_146
  constexpr float labelCenter = 154.5f;
  drawUiText("NO UPDATE", 2, labelCenter - uiTextWidth("NO UPDATE", 2) / 2,
             context.distanceTop);
  drawUiText("CHECK PHONE", 1, labelCenter - uiTextWidth("CHECK PHONE", 1) / 2,
             context.distanceTop + 19);
#else
  drawUiText("NO UPD", 2, context.distanceX, 100);
  drawUiText("CHECK PHONE", 1, context.distanceX, 122);
#endif
}
}  // namespace

void renderUiScreen(const UiState& state, const UiRenderContext& context,
                    bool blinkState) {
  if (state.screen == UiScreen::Off) return;
  beginFrame();
  switch (state.screen) {
    case UiScreen::Pairing:
      drawPairing(context);
      break;
    case UiScreen::Brand:
      drawBrand(state);
      break;
    case UiScreen::Clock:
      drawClock(state, context);
      break;
    case UiScreen::NotPaired:
      drawNotPaired();
      break;
    case UiScreen::ConnectionLost:
      drawConnectionLost();
      break;
    case UiScreen::Updating:
    case UiScreen::CachedRoute:
    case UiScreen::WaitingPhone:
      drawUpdating(state, context);
      break;
    case UiScreen::NoGuidance:
      drawNoGuidance(context);
      break;
    case UiScreen::StaleGuidance:
      drawStaleGuidance(state, context);
      break;
    case UiScreen::Arrived:
      drawArrivalCheck(state.arrivalProgress);
#if NAV_WAVESHARE_146
      drawRoundCenteredText("ARRIVED", 2, 156);
#else
      drawUiText("ARRIVED", 2, 78, 101);
#endif
      break;
    case UiScreen::Navigating:
      drawMiniRouteMap(true, state.navigation.direction);
      drawDirection(state.navigation.direction);
      drawDistance(state.navigation, blinkState);
      drawBottomError();
      break;
    case UiScreen::Off:
      break;
  }
  presentDisplay();
}
