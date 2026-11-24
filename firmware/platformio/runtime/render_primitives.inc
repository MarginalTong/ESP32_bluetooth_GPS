// ======================================================
// Drawing
// ======================================================

// Borderless map above a compact instruction strip, with no separator line.
constexpr int16_t MAP_LEFT = 0;
constexpr int16_t MAP_TOP = 0;
constexpr int16_t MAP_RIGHT = SCREEN_WIDTH - 1;
#if NAV_ROUND_DISPLAY
constexpr int16_t MAP_BOTTOM = 166;
constexpr uint8_t ROUTE_STROKE = 7;
constexpr uint8_t FALLBACK_ROUTE_STROKE = 4;
#else
constexpr int16_t MAP_BOTTOM = 94;
constexpr uint8_t ROUTE_STROKE = 6;
constexpr uint8_t FALLBACK_ROUTE_STROKE = 2;
#endif
// Zoom geometry around the rider, without enlarging the instruction strip.
#if NAV_ROUND_DISPLAY
constexpr float MAP_ZOOM = 1.90f;
#else
constexpr float MAP_ZOOM = 1.50f;
#endif
constexpr int16_t MAP_CLIP_BOTTOM = MAP_BOTTOM - 4;
constexpr int16_t ARROW_CENTER_X = 66;
constexpr int16_t DISTANCE_X = 132;

// Route-source coordinates to canvas pixels, unrounded.
float mapPreviewX(float x) {
  const float center = (MAP_LEFT + MAP_RIGHT) / 2.0f;
  const float projected = MAP_LEFT + 6 + (x - 18) * (MAP_RIGHT - MAP_LEFT - 12) / 92.0f;
  return center + (projected - center) * MAP_ZOOM;
}

float mapPreviewY(float y) {
  const float anchor = MAP_BOTTOM - 12;
#if NAV_ROUND_DISPLAY
  // Use the extra round-screen height for the map, but retain the rider at
  // the bottom so the instruction strip cannot be covered by road geometry.
  const float projected = MAP_TOP + 25 + (y - 2) * (MAP_BOTTOM - MAP_TOP - 47) / 32.0f;
  return anchor + (projected - anchor) * 1.90f;
#else
  const float projected = MAP_TOP + 4 + (y - 2) * (MAP_BOTTOM - MAP_TOP - 16) / 32.0f;
  return anchor + (projected - anchor) * MAP_ZOOM;
#endif
}

#if NAV_ROUND_DISPLAY
constexpr float NATIVE_SCALE = float(NATIVE_LAYER_SIZE) / SCREEN_WIDTH;

bool useNativeLayer() { return nativeLayer.pixels != nullptr; }

bool isNumericText(const char* value) {
  if (*value == '\0') return false;
  for (const char* c = value; *c != '\0'; ++c)
    if ((*c < '0' || *c > '9') && *c != ':' && *c != '.') return false;
  return true;
}

// Canvas pixel coordinate to the center of the matching native-layer area.
float layerCoord(float canvasValue) { return (canvasValue + 0.5f) * NATIVE_SCALE; }
#else
bool useNativeLayer() { return false; }
#endif

// Starts a frame: everything drawn until presentDisplay() is shown together.
void beginFrame() {
  display.fillScreen(COLOR_BG);
  display.setTextColor(COLOR_WHITE);
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    nativeLayer.clear();
    nativeLayerDrawn = true;
  }
#endif
}

// Text whose capitals span [top, top + 7 * size] canvas pixels.
void drawUiText(const char* value, uint8_t size, float left, float top) {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    // Numbers use the numeric font, everything else the text font. The
    // classic font's size n is 7n canvas pixels tall; keep those heights.
    const AlphaFont& font = isNumericText(value) ? NAVIO_NUMERIC_FONT : NAVIO_TEXT_FONT;
    textCache.draw(nativeLayer, font, value, left * NATIVE_SCALE,
                   (top + 7.0f * size) * NATIVE_SCALE,
                   7.0f * size * NATIVE_SCALE / font.capHeight, 255);
    return;
  }
#endif
  display.setTextSize(size);
  display.setCursor(lroundf(left), lroundf(top));
  display.print(value);
}

float uiTextWidth(const char* value, uint8_t size) {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    const AlphaFont& font = isNumericText(value) ? NAVIO_NUMERIC_FONT : NAVIO_TEXT_FONT;
    return font.textWidth(value, 7.0f * size / font.capHeight);
  }
#endif
  return strlen(value) * 6.0f * size;
}

void fillUiTriangle(float x0, float y0, float x1, float y1, float x2, float y2) {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    nativeLayer.fillTriangle(layerCoord(x0), layerCoord(y0), layerCoord(x1),
                             layerCoord(y1), layerCoord(x2), layerCoord(y2), 255);
    return;
  }
#endif
  display.fillTriangle(lroundf(x0), lroundf(y0), lroundf(x1), lroundf(y1),
                       lroundf(x2), lroundf(y2), COLOR_WHITE);
}

void presentDisplay() {
  lastFrameTransferUs = 0;
#if NAV_ROUND_DISPLAY
  // Composed and sent in bands, so no full panel framebuffer is needed: the
  // canvas UI upscaled, over the native-resolution map. Native RGB565 words
  // are passed to draw16bitRGBBitmap (not the big-endian variant).
  constexpr int16_t bandRows = 16;
  static uint16_t band[PANEL_VIEW_WIDTH * bandRows];
  const uint16_t* source = display.getBuffer();
  if (!source) return;
  const GrayLayer* layer = nativeLayerDrawn ? &nativeLayer : nullptr;
  for (int16_t y = 0; y < PANEL_VIEW_HEIGHT; y += bandRows) {
    const int16_t rows =
        PANEL_VIEW_HEIGHT - y < bandRows ? int16_t(PANEL_VIEW_HEIGHT - y) : bandRows;
    panelComposer.compose(source, layer, band, y, rows, frameSprite);
    const uint32_t transferStartUs = micros();
    tft.draw16bitRGBBitmap(PANEL_VIEW_X, PANEL_VIEW_Y + y, band, PANEL_VIEW_WIDTH, rows);
    lastFrameTransferUs += micros() - transferStartUs;
  }
  nativeLayerDrawn = false;
  frameSprite = nullptr;
#else
  const uint32_t transferStartUs = micros();
  tft.drawRGBBitmap(0, 0, display.getBuffer(), SCREEN_WIDTH, SCREEN_HEIGHT);
  lastFrameTransferUs = micros() - transferStartUs;
#endif
}

void drawThickLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                   uint16_t color = COLOR_WHITE, uint8_t thickness = 3) {
  const int16_t radius = thickness / 2;
  for (int16_t dx = -radius; dx <= radius; dx++) {
    for (int16_t dy = -radius; dy <= radius; dy++) {
      display.drawLine(x0 + dx, y0 + dy, x1 + dx, y1 + dy, color);
    }
  }
}

// A stroke as wide as drawThickLine() draws it (2 * (thickness / 2) + 1
// canvas pixels), anti-aliased on the native layer.
void drawStroke(float x0, float y0, float x1, float y1, uint8_t thickness) {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    const float width = (thickness / 2 * 2 + 1) * NATIVE_SCALE;
    nativeLayer.strokeSegment(layerCoord(x0), layerCoord(y0), layerCoord(x1),
                              layerCoord(y1), width / 2.0f, 255);
    return;
  }
#endif
  drawThickLine(lroundf(x0), lroundf(y0), lroundf(x1), lroundf(y1), COLOR_ROUTE,
                thickness);
}

void drawSpeedLimit(uint8_t kph) {
#if NAV_ROUND_DISPLAY
  // Canvas pixels to panel-view pixels.
  constexpr float viewScale = float(PANEL_VIEW_WIDTH) / SCREEN_WIDTH;
  if (speedLimitSign.prepare(kph, SpeedSignStyle::centerX * viewScale,
                             SpeedSignStyle::centerY * viewScale,
                             SpeedSignStyle::diameter * viewScale,
                             SpeedSignStyle::halo * viewScale))
    frameSprite = &speedLimitSign.sprite;
#else
  (void)kph;  // The original rectangular panel has no room beside its map.
#endif
}

void drawArrivalCheck(uint8_t progress) {
  const float p = fminf(progress / 100.0f, 1.0f);
#if NAV_ROUND_DISPLAY
  constexpr float ax = 82, ay = 106, bx = 110, by = 132, cx = 162, cy = 74;
#else
  constexpr float ax = 88, ay = 56, bx = 112, by = 78, cx = 152, cy = 34;
#endif
  if (p <= 0) return;
  const float first = fminf(p / 0.35f, 1.0f);
  drawStroke(ax, ay, ax + (bx - ax) * first, ay + (by - ay) * first, 5);
  if (p > 0.35f) {
    const float second = (p - 0.35f) / 0.65f;
    drawStroke(bx, by, bx + (cx - bx) * second, by + (cy - by) * second, 5);
  }
}

void drawSideRoadLine(float x0, float y0, float x1, float y1) {
#if NAV_ROUND_DISPLAY
  constexpr float visibleLength = SideRoadStyle::roundLength;
  constexpr SideRoadArea area = {float(SCREEN_WIDTH), float(MAP_CLIP_BOTTOM),
                                 SCREEN_WIDTH / 2.0f, SCREEN_HEIGHT / 2.0f,
                                 SCREEN_WIDTH / 2.0f};
#else
  constexpr float visibleLength = SideRoadStyle::rectLength;
  constexpr SideRoadArea area = {float(SCREEN_WIDTH), float(MAP_CLIP_BOTTOM),
                                 0.0f, 0.0f, 0.0f};
#endif
  SideRoadRay ray;
  if (!planSideRoadRay(x0, y0, x1, y1, visibleLength, area, ray)) return;
  constexpr float halfWidth = SideRoadStyle::halfWidth;
  constexpr uint8_t peak = SideRoadStyle::peak;
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    nativeLayer.strokeFadingRay(layerCoord(ray.x0), layerCoord(ray.y0), ray.ux,
                                ray.uy, ray.length * NATIVE_SCALE,
                                halfWidth * NATIVE_SCALE, peak);
    return;
  }
#endif
  const int16_t startX = lroundf(ray.x0), startY = lroundf(ray.y0);
  const int16_t stopX = lroundf(ray.x0 + ray.ux * ray.length);
  const int16_t stopY = lroundf(ray.y0 + ray.uy * ray.length);
  // Clip before rasterizing: off-screen geometry never expands frame cost.
  const int16_t left = max(0, min(startX, stopX) - 5);
  const int16_t right = min(int(SCREEN_WIDTH - 1), max(startX, stopX) + 5);
  const int16_t top = max(0, min(startY, stopY) - 5);
  const int16_t bottom = min(int(MAP_CLIP_BOTTOM - 1), max(startY, stopY) + 5);
  uint16_t* pixels = display.getBuffer();
  for (int16_t y = top; y <= bottom; ++y) {
    for (int16_t x = left; x <= right; ++x) {
      const float px = x - startX;
      const float py = y - startY;
      const float along = px * ray.ux + py * ray.uy;
      if (along < 0.0f || along >= ray.length) continue;
      const float distance = fabsf(px * ray.uy - py * ray.ux);
      if (distance >= halfWidth + 0.5f) continue;
      const uint8_t gray =
          GrayLayer::fadingRayLevel(along, ray.length, distance, halfWidth, peak);
      const uint16_t color = ((gray >> 3) << 11) | ((gray >> 2) << 5) | (gray >> 3);
      uint16_t& pixel = pixels[y * SCREEN_WIDTH + x];
      // Overlapping branches must not erase a brighter edge already drawn.
      if (color > pixel) pixel = color;
    }
  }
}
