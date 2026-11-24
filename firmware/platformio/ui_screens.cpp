#include "ui_screens.h"
#include "ui_draw.h"

namespace {
// Insets keep the compact wordmark inside the round aperture. Draw it only on
// idle/status pages: route and maneuver pixels always belong to navigation.
void drawCompactBrand() {
#if NAV_ROUND_DISPLAY
  drawUiText("NAVIO", 2, 38, 38);
#else
  drawUiText("NAVIO", 2, 12, 8);
#endif
}

// Keep the title centered independently of the footer's presence or height.
void drawLargeBrand() {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    drawRoundCenteredStatus("NAVIO", 5, nullptr, 1);
  } else {
    drawStandbyBrandText("NAVIO", true);
  }
#else
  drawUiText("NAVIO", 4, 60, 35);
#endif
}

#if NAV_ROUND_DISPLAY
void drawIdleFooter(const char* text, const UiRenderContext& context) {
  // User-requested bottom placement, in logical canvas pixels. The inset
  // leaves room for these labels where the circular aperture narrows.
  constexpr int16_t bottomInset = 24;
  const int16_t top = context.screenHeight - bottomInset - roundTextHeight(text, 1);
  drawRoundCenteredText(text, 1, top);
}
#endif

void drawClock(const UiState& state, const UiRenderContext& context) {
  if (!state.connected) {
    drawLargeBrand();
    return;
  }
  // The instrument renderer owns the face; never overlay the standby logo.
#if NAV_ROUND_DISPLAY
  if (drawInstrumentClock(context.clockText)) return;
  // Keep the readiness hint subordinate to the large time digits.
  drawRoundCenteredStatus(context.clockText, 7, nullptr, 1);
  drawIdleFooter("ready to go", context);
#else
  drawUiText(context.clockText, 7, 15, 30);
  drawUiText("ready to go", 2, 54, 99);
#endif
}

void drawPairing(const UiRenderContext& context) {
#if NAV_ROUND_DISPLAY
  drawRoundCenteredText(context.deviceName, 1, 60);
#if NAV_PAIR_ON_POWER_UP
  // Confirmed by the power-up window; this shows only for a moment.
  drawRoundCenteredStatus("PAIRING", 2, "KEEP PHONE CLOSE", 1);
#else
  drawRoundCenteredStatus("PRESS BOOT", 2, "TO PAIR", 1);
#endif
#else
  drawUiText(context.deviceName, 1, 12, 12);
  drawUiText("PRESS BOOT", 2, 54, 51);
  drawUiText("TO PAIR", 1, 67, 108);
#endif
}

void drawNotPaired() {
  drawCompactBrand();
#if NAV_ROUND_DISPLAY
  drawRoundCenteredStatus("NOT PAIRED", 2, "PAIR IN THE APP", 1);
#else
  drawUiText("NOT PAIRED", 2, 60, 40);
  drawUiText("PAIR IN THE APP", 1, 75, 80);
#endif
}

void drawUpdating(const UiState& state, const UiRenderContext& context) {
#if !NAV_ROUND_DISPLAY
  (void)context;  // The original rectangular panel has fixed text positions.
#endif
  if (state.screen == UiScreen::Updating) {
#if NAV_ROUND_DISPLAY
    drawRoundCenteredText("UPDATING...", 1,
        (context.screenHeight - roundTextHeight("UPDATING...", 1)) / 2);
#else
    drawUiText("UPDATING...", 1, 84, 62);
#endif
    return;
  }

  drawMiniRouteMap(false, state.navigation.direction);
  drawDirection(state.navigation.direction);
#if NAV_ROUND_DISPLAY
  drawRoundCenteredText("LAST KNOWN", 1, 210);
#else
  drawUiText("LAST KNOWN", 1, 140, 116);
#endif
}

void drawNoGuidance(const UiRenderContext& context) {
#if !NAV_ROUND_DISPLAY
  (void)context;
#endif
#if NAV_ROUND_DISPLAY
  drawRoundCenteredText("NO GUIDANCE", 1,
      (context.screenHeight - roundTextHeight("NO GUIDANCE", 1)) / 2);
#else
  drawUiText("NO GUIDANCE", 1, 84, 62);
#endif
}

void drawStaleGuidance(const UiState& state, const UiRenderContext& context) {
  drawMiniRouteMap(false, state.navigation.direction);
  drawDirection(state.navigation.direction);
#if NAV_ROUND_DISPLAY
  (void)context;
  drawRoundCenteredText(state.connected ? "LAST KNOWN" : "BLE / STALE", 1, 210);
#else
  drawUiText(state.connected ? "LAST KNOWN" : "LINK LOST", 1, context.distanceX, 116);
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
    case UiScreen::ConnectionLost:
      drawLargeBrand();
      break;
    case UiScreen::Clock:
      drawClock(state, context);
      break;
    case UiScreen::NotPaired:
      drawNotPaired();
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
#if NAV_ROUND_DISPLAY
      drawRoundCenteredText("ARRIVED", 2, 156);
#else
      drawUiText("ARRIVED", 2, 78, 101);
#endif
      break;
    case UiScreen::Navigating:
      drawMiniRouteMap(true, state.navigation.direction);
      drawDirection(state.navigation.direction);
      drawDistance(state.navigation, blinkState);
      // Only with live guidance: a stale position has no known limit.
      drawSpeedLimit(state.navigation.speedLimitKph);
      drawBottomError();
      break;
    case UiScreen::Off:
      break;
  }
  presentDisplay();
}
