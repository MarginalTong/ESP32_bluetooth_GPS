#include "board_config.h"

#if NAV_JC3636W518C
static_assert(NAV_ROUND_DISPLAY && !NAV_WAVESHARE_146, "round JC layout");
static_assert(PANEL_SIZE == 360 && NAVIO_RENDER_SIZE == 360, "native raster");
static_assert(TFT_CS_PIN == 10 && TFT_SCLK_PIN == 9, "QSPI control");
static_assert(TFT_DATA0_PIN == 11 && TFT_DATA1_PIN == 12 &&
              TFT_DATA2_PIN == 13 && TFT_DATA3_PIN == 14, "QSPI data");
static_assert(TFT_RESET_PIN == 47 && TFT_BACKLIGHT_PIN == 15, "direct control");
#elif NAV_WAVESHARE_146
static_assert(NAV_ROUND_DISPLAY && PANEL_SIZE == 412, "legacy round panel");
static_assert(TFT_CS_PIN == 21 && TFT_SCLK_PIN == 40, "legacy pins");
static_assert(IO_EXPANDER_ADDRESS == 0x20 && LCD_RESET_MASK == 2, "expander reset");
#else
static_assert(!NAV_ROUND_DISPLAY, "legacy rectangular layout");
#endif

int main() {}
