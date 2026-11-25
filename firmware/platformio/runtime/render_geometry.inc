void drawSideRoadSegments() {
  for (uint8_t i = 0; i < mapMotion.roads; i++) {
    const float* p = mapMotion.current + MapMotion::kRouteValues + i * 4;
    drawSideRoadLine(mapPreviewX(p[0]), mapPreviewY(p[1]),
                     mapPreviewX(p[2]), mapPreviewY(p[3]));
  }
}

#if NAV_ROUND_DISPLAY
// The instruction row sits where the round aperture narrows; its positions
// are in platformio/instruction_layout.h.
constexpr float INSTRUCTION_SCALE = 1.0f;
constexpr float INSTRUCTION_CENTER_X = InstructionLayout::arrowCenterX;
constexpr float INSTRUCTION_CENTER_Y = InstructionLayout::arrowCenterY;
static_assert(InstructionLayout::panelTop == MAP_CLIP_BOTTOM,
              "the instruction panel starts where the map is clipped");
// Distance text: right edge (fallback), and top of its capitals.
constexpr float DISTANCE_RIGHT = 168.0f;  // low-resolution fallback only
constexpr float DISTANCE_TOP = InstructionLayout::distanceTop;
#endif

// Arrow artwork is drawn in the original strip's coordinates, centred on
// (66, 111.5).
float instructionX(float x) {
#if NAV_ROUND_DISPLAY
  return INSTRUCTION_CENTER_X + (x - 66.0f) * INSTRUCTION_SCALE;
#else
  return x;
#endif
}

float instructionY(float y) {
#if NAV_ROUND_DISPLAY
  return INSTRUCTION_CENTER_Y + (y - 111.5f) * INSTRUCTION_SCALE;
#else
  return y;
#endif
}

void drawInstructionLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                         uint8_t thickness = 3) {
  drawStroke(instructionX(x0), instructionY(y0), instructionX(x1),
             instructionY(y1),
#if NAV_ROUND_DISPLAY
             thickness + 1
#else
             thickness
#endif
  );
}

void fillInstructionTriangle(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                             int16_t x2, int16_t y2) {
  fillUiTriangle(instructionX(x0), instructionY(y0), instructionX(x1),
                 instructionY(y1), instructionX(x2), instructionY(y2));
}

void drawArrowUp() {
  drawInstructionLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 98);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X - 15, 113);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X + 15, 113);
}

void drawArrowLeft() {
  drawInstructionLine(82, 128, 82, 116);
  drawInstructionLine(82, 116, 74, 106);
  drawInstructionLine(74, 106, 42, 106);
  drawInstructionLine(42, 106, 60, 93);
  drawInstructionLine(42, 106, 60, 119);
}

void drawArrowRight() {
  drawInstructionLine(48, 128, 48, 116);
  drawInstructionLine(48, 116, 56, 106);
  drawInstructionLine(56, 106, 88, 106);
  drawInstructionLine(88, 106, 70, 93);
  drawInstructionLine(88, 106, 70, 119);
}

void drawBearLeft() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 62, 112, 4);
  drawInstructionLine(62, 112, 50, 100, 4);
  fillInstructionTriangle(43, 96, 61, 99, 46, 114);
}

void drawBearRight() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 70, 112, 4);
  drawInstructionLine(70, 112, 82, 100, 4);
  fillInstructionTriangle(89, 96, 71, 99, 86, 114);
}

void drawUTurn() {
  drawInstructionLine(82, 128, 82, 100);
  drawInstructionLine(82, 100, 44, 100);
  drawInstructionLine(44, 100, 44, 120);
  drawInstructionLine(44, 120, 31, 107);
  drawInstructionLine(44, 120, 57, 107);
}

void drawStop() {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    nativeLayer.fillRoundRect(instructionX(42) * NATIVE_SCALE,
                              instructionY(98) * NATIVE_SCALE,
                              instructionX(90) * NATIVE_SCALE,
                              instructionY(128) * NATIVE_SCALE, 5 * NATIVE_SCALE, 255);
    return;
  }
#endif
  display.fillRoundRect(lroundf(instructionX(42)), lroundf(instructionY(98)),
                        lroundf(instructionX(90) - instructionX(42)),
                        lroundf(instructionY(128) - instructionY(98)), 5, COLOR_WHITE);
}

void drawArrived() {
  drawInstructionLine(34, 114, 56, 130);
  drawInstructionLine(56, 130, 94, 94);
}

void drawUnknown() {
  drawUiText("?", 2, instructionX(22), instructionY(105));
}

void drawDirection(Direction direction) {
  switch (direction) {
    case Direction::Up:
      drawArrowUp();
      break;
    case Direction::Left:
      drawArrowLeft();
      break;
    case Direction::Right:
      drawArrowRight();
      break;
    case Direction::BearLeft:
      drawBearLeft();
      break;
    case Direction::BearRight:
      drawBearRight();
      break;
    case Direction::UTurn:
      drawUTurn();
      break;
    case Direction::Stop:
      drawStop();
      break;
    case Direction::Arrived:
      drawArrived();
      break;
    default:
      drawUnknown();
      break;
  }
}

void drawFallbackMapRoute(Direction direction) {
  const int16_t centerX = (MAP_LEFT + MAP_RIGHT) / 2;
  const int16_t bottom = MAP_BOTTOM - 8;
  const int16_t top = MAP_TOP + 12;
  const int16_t left = MAP_LEFT + 28;
  const int16_t right = MAP_RIGHT - 28;

  switch (direction) {
    case Direction::Left:
      drawStroke(centerX, bottom, centerX, 55, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 55, centerX - 18, 42, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX - 18, 42, left, 42, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::Right:
      drawStroke(centerX, bottom, centerX, 55, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 55, centerX + 18, 42, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX + 18, 42, right, 42, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearLeft:
      drawStroke(centerX, bottom, centerX, 58, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 58, centerX - 44, top, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearRight:
      drawStroke(centerX, bottom, centerX, 58, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 58, centerX + 44, top, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::UTurn:
      drawStroke(centerX, bottom, centerX, 36, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 36, left + 28, 36, FALLBACK_ROUTE_STROKE);
      drawStroke(left + 28, 36, left + 28, 68, FALLBACK_ROUTE_STROKE);
      break;
    default:
      drawStroke(centerX, bottom, centerX, top, FALLBACK_ROUTE_STROKE);
      break;
  }
}

void drawMiniRouteMap(bool showRider, Direction direction) {
#if NAV_ROUND_DISPLAY
  // Legacy preview coordinates can extend below the map; keep them out of
  // the instruction strip.
  nativeLayer.clipBottom = int16_t(MAP_CLIP_BOTTOM * NATIVE_SCALE);
#endif
  drawSideRoadSegments();

  if (mapMotion.routes >= 2) {
    for (uint8_t i = 0; i + 1 < mapMotion.routes; i++) {
      const float* p = mapMotion.current + i * 2;
      drawStroke(mapPreviewX(p[0]), mapPreviewY(p[1]),
                  mapPreviewX(p[2]), mapPreviewY(p[3]), ROUTE_STROKE);
    }
  } else {
    drawFallbackMapRoute(direction);
  }

  if (showRider) {
    const int16_t markerX = (MAP_LEFT + MAP_RIGHT) / 2;
    const int16_t markerY = MAP_BOTTOM - 12;
    // Only live guidance may show a rider marker. A cached snapshot no longer
    // establishes the bike's current position relative to this road shape.
#if NAV_ROUND_DISPLAY
    if (useNativeLayer()) {
      const float x = layerCoord(markerX), y = layerCoord(markerY);
      constexpr float s = NATIVE_SCALE;
      nativeLayer.fillTriangle(x, y - 21 * s, x - 18 * s, y + 14 * s, x + 18 * s,
                            y + 14 * s, 0);
      nativeLayer.fillTriangle(x, y - 12 * s, x - 10 * s, y + 6 * s, x + 10 * s,
                            y + 6 * s, 255);
    } else {
      display.fillTriangle(markerX, markerY - 21, markerX - 18, markerY + 14,
                           markerX + 18, markerY + 14, COLOR_BG);
      display.fillTriangle(markerX, markerY - 12, markerX - 10, markerY + 6,
                           markerX + 10, markerY + 6, COLOR_WHITE);
    }
#else
    display.fillTriangle(markerX, markerY - 15, markerX - 13, markerY + 10,
                         markerX + 13, markerY + 10, COLOR_BG);
    display.fillTriangle(markerX, markerY - 8, markerX - 7, markerY + 4,
                         markerX + 7, markerY + 4, COLOR_WHITE);
#endif
  }

  // Legacy preview coordinates can extend below the map. Keep them out of
  // the instruction strip without drawing a visible frame or separator.
  display.fillRect(0, MAP_CLIP_BOTTOM, SCREEN_WIDTH, SCREEN_HEIGHT - MAP_CLIP_BOTTOM,
                   COLOR_BG);
#if NAV_ROUND_DISPLAY
  nativeLayer.clipBottom = nativeLayer.height;
#endif
}

#if NAV_ROUND_DISPLAY
// Returns the drawn width.
uint16_t drawFallbackDistanceText(const char* value, const GFXfont* font,
                                  int16_t anchorX, int16_t top, bool rightAligned) {
  int16_t x, y;
  uint16_t width, height;
  display.setFont(font);
  display.setTextSize(1);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor(anchorX - (rightAligned ? int16_t(width) : 0) - x, top - y);
  display.print(value);
  display.setFont(nullptr);
  return width;
}
#endif
