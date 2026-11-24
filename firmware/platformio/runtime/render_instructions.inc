void drawDistance(const NavState& navigation, bool blinkState) {
  const int distanceMeters = navigation.distanceMeters;
  display.setTextColor(COLOR_WHITE);
#if NAV_ROUND_DISPLAY
  // Digits centred in the instruction panel, unit underneath: see
  // platformio/instruction_layout.h.
  const char* label = nullptr;
  const char* unit = nullptr;
  char number[8];
  if (navigation.direction == Direction::Arrived) {
    label = "ARR";
  } else if (distanceMeters <= 30) {
    if (blinkState) label = "NOW";
  } else {
    if (distanceMeters < 1000) {
      snprintf(number, sizeof(number), "%d", distanceMeters);
    } else {
      snprintf(number, sizeof(number), "%.1f", distanceMeters / 1000.0);
    }
    label = number;
    unit = distanceMeters < 1000 ? "m" : "km";
  }
  float right = DISTANCE_RIGHT;
  if (!useNativeLayer()) {
    if (unit != nullptr)
      right -= drawFallbackDistanceText(unit, &FreeSans9pt7b, lroundf(right),
                                        DISTANCE_TOP + 15, true) + 3;
    if (label != nullptr)
      drawFallbackDistanceText(label, &FreeSansBold18pt7b, lroundf(right),
                               DISTANCE_TOP, true);
    return;
  }
  if (label == nullptr) return;
  const InstructionLayout::DistancePlace place = InstructionLayout::placeDistance(
      uiTextWidth(label, InstructionLayout::distanceSize));
  drawUiText(label, place.size, place.numberLeft, place.numberTop);
  if (unit != nullptr)
    drawUiText(unit, InstructionLayout::unitSize, place.unitLeft, place.unitTop);
#else
  display.setTextSize(3);
  display.setCursor(DISTANCE_X, 104);
  if (navigation.direction == Direction::Arrived) {
    display.println("ARR");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.println("NOW");
    }
  } else if (distanceMeters < 1000) {
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.print(distanceMeters / 1000.0, 1);
    display.println("k");
  }
#endif
}

void drawBottomError() {
  if (lastError[0] == '\0') return;

  display.setTextColor(COLOR_ACCENT);
#if NAV_ROUND_DISPLAY
  // Below the distance the round aperture is narrow: centre the message there
  // and drop trailing characters until it fits the visible width at its
  // lowest row (3 px margin).
  constexpr float top = InstructionLayout::errorTop;
  const float dy = top + 7.0f - SCREEN_HEIGHT / 2.0f;
  const float radius = PANEL_VISIBLE_RADIUS * float(SCREEN_WIDTH) / PANEL_VIEW_WIDTH - 3.0f;
  const float available = 2.0f * sqrtf(fmaxf(0.0f, radius * radius - dy * dy));
  char visible[25];
  strlcpy(visible, lastError, sizeof(visible));
  for (size_t length = strlen(visible); length > 0 && uiTextWidth(visible, 1) > available;)
    visible[--length] = '\0';
  drawRoundCenteredText(visible, 1, top);
#else
  display.setTextSize(1);
  display.setCursor(8, SCREEN_HEIGHT - 10);
  display.print(lastError);
#endif
}

#if NAV_ROUND_DISPLAY
uint16_t roundTextHeight(const char* value, uint8_t size) {
  if (useNativeLayer()) return 7 * size;
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  return height;
}

void drawRoundCenteredText(const char* value, uint8_t size, int16_t top) {
  if (useNativeLayer()) {
    drawUiText(value, size, (SCREEN_WIDTH - uiTextWidth(value, size)) / 2.0f, top);
    return;
  }
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor((SCREEN_WIDTH - width) / 2 - x, top - y);
  display.print(value);
}

void drawRoundCenteredStatus(const char* primary, uint8_t primarySize,
                             const char* secondary = nullptr,
                             uint8_t secondarySize = 1) {
  const int16_t primaryHeight = roundTextHeight(primary, primarySize);
  const int16_t secondaryHeight = secondary == nullptr
                                      ? 0
                                      : roundTextHeight(secondary, secondarySize);
  const int16_t gap = secondary == nullptr ? 0 : 18;
  const int16_t top = (SCREEN_HEIGHT - primaryHeight - gap - secondaryHeight) / 2;
  drawRoundCenteredText(primary, primarySize, top);
  if (secondary != nullptr)
    drawRoundCenteredText(secondary, secondarySize, top + primaryHeight + gap);
}

// Keep the idle brand legible even when the native gray layer could not be
// allocated. GFX's built-in font scales square pixels; outline-derived fonts
// give the fallback a proper sans-serif shape instead.
void drawStandbyBrandText(const char* value, bool primary) {
  const GFXfont* font = primary ? &FreeSansBold24pt7b : &FreeSans9pt7b;
  const int16_t centerY = primary ? 105 : 146;
  int16_t x, y;
  uint16_t width, height;
  display.setFont(font);
  display.setTextSize(1);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor((SCREEN_WIDTH - width) / 2 - x,
                    centerY - int16_t(height / 2) - y);
  display.print(value);
  display.setFont(nullptr);
}
#endif
