#pragma once

#include <stdint.h>

// Select the hardware separately from the round/rectangular UI layout.
#ifndef NAV_JC3636W518C
#define NAV_JC3636W518C 0
#endif
#ifndef NAV_WAVESHARE_146
#define NAV_WAVESHARE_146 (!NAV_JC3636W518C)
#endif
#if NAV_JC3636W518C && NAV_WAVESHARE_146
#error "Select only one display board"
#endif
#define NAV_ROUND_DISPLAY (NAV_WAVESHARE_146 || NAV_JC3636W518C)

#if NAV_ROUND_DISPLAY
#if NAV_JC3636W518C
// Manufacturer demo: ST77916_LVGL_DEMO/pincfg.h (JC3636W518EN).
constexpr int8_t TFT_DATA0_PIN = 11;
constexpr int8_t TFT_DATA1_PIN = 12;
constexpr int8_t TFT_DATA2_PIN = 13;
constexpr int8_t TFT_DATA3_PIN = 14;
constexpr int8_t TFT_SCLK_PIN = 9;
constexpr int8_t TFT_CS_PIN = 10;
constexpr int8_t TFT_BACKLIGHT_PIN = 15;
constexpr int8_t TFT_RESET_PIN = 47;
constexpr int16_t PANEL_SIZE = 360;
#else
constexpr int8_t TFT_DATA0_PIN = 46;
constexpr int8_t TFT_DATA1_PIN = 45;
constexpr int8_t TFT_DATA2_PIN = 42;
constexpr int8_t TFT_DATA3_PIN = 41;
constexpr int8_t TFT_SCLK_PIN = 40;
constexpr int8_t TFT_CS_PIN = 21;
constexpr int8_t TFT_BACKLIGHT_PIN = 5;
constexpr int8_t BOARD_I2C_SDA_PIN = 11;
constexpr int8_t BOARD_I2C_SCL_PIN = 10;
constexpr uint8_t LCD_RESET_MASK = 1U << 1;
constexpr uint8_t IO_EXPANDER_ADDRESS = 0x20;
constexpr int16_t PANEL_SIZE = 412;
#endif
#ifndef NAVIO_RENDER_SIZE
#define NAVIO_RENDER_SIZE PANEL_SIZE
#endif
static_assert(NAVIO_RENDER_SIZE >= 240 && NAVIO_RENDER_SIZE <= PANEL_SIZE,
              "AA raster must fit between the logical canvas and physical panel");
#endif
