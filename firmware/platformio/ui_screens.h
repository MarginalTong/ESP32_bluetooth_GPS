#pragma once

#include "board_config.h"
#include "ui_state.h"

// Frame-local data provided by the board adapter. Clock formatting and device
// identity stay outside the renderer; no shared BLE flags are read while drawing.
struct UiRenderContext {
  const char* deviceName;
  const char* clockText;
  int16_t screenHeight;
  float distanceTop;
  float distanceX;
};

void renderUiScreen(const UiState& state, const UiRenderContext& context,
                    bool blinkState);
