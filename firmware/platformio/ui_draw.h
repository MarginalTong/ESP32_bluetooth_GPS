#pragma once

#include "nav_types.h"

// Drawing boundary implemented by the current board/display adapter. Pages
// depend on these operations, not on TFT drivers, framebuffers or BLE globals.
void beginFrame();
void presentDisplay();
void drawUiText(const char* value, uint8_t size, float left, float top);
float uiTextWidth(const char* value, uint8_t size);
bool useNativeLayer();
uint16_t roundTextHeight(const char* value, uint8_t size);
void drawRoundCenteredText(const char* value, uint8_t size, int16_t top);
void drawRoundCenteredStatus(const char* primary, uint8_t primarySize,
                             const char* secondary, uint8_t secondarySize);
void drawStandbyBrandText(const char* value, bool primary);
void drawMiniRouteMap(bool showRider, Direction direction);
void drawDirection(Direction direction);
void drawDistance(const NavState& navigation, bool blinkState);
void drawBottomError();
