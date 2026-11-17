#include "instrument_clock.h"
#include "board_config.h"
#include "ui_draw.h"

#if NAV_ROUND_DISPLAY
// The existing display adapter owns the frame and presents its sprite once.
// No BLE state or driver parameters are changed by this renderer.
extern const ColorSprite* frameSprite;
#endif

bool drawInstrumentClock(const char* time) {
#if NAV_ROUND_DISPLAY
  static InstrumentClock clock;
  if (useNativeLayer() && clock.prepare(time, PANEL_SIZE)) {
    frameSprite = &clock.sprite;
    return true;
  }
#else
  (void)time;
#endif
  return false;
}
