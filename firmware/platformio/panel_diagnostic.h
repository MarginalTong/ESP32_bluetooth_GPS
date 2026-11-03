#pragma once

#include <Arduino.h>
#include <Arduino_DataBus.h>  // Opcode names only; no Arduino_GFX bus is opened.
#include <driver/spi_master.h>
#include <esp_lcd_io_spi.h>
#include <esp_lcd_panel_io.h>
#include <esp_heap_caps.h>
#include <freertos/semphr.h>
#include "board_config.h"
#include "jc3636_panel_init.h"
#include "panel_test_pattern.h"

// Isolation test: native ESP-IDF LCD IO, hardware CS, one window/one RAMWR
// transfer per band, internal DMA memory, explicit completion before reuse.
// No NAVIO compositor, PSRAM framebuffer, fonts, BLE or pairing-key access.
namespace panelDiagnostic {
constexpr unsigned rows = 8;
esp_lcd_panel_io_handle_t io = nullptr;
SemaphoreHandle_t finished = nullptr;
uint16_t* pixels = nullptr;

bool colorDone(esp_lcd_panel_io_handle_t, esp_lcd_panel_io_event_data_t*, void*) {
  BaseType_t wake = pdFALSE;
  xSemaphoreGiveFromISR(finished, &wake);
  return wake == pdTRUE;
}

bool checked(esp_err_t result, const char* step) {
  if (result == ESP_OK) return true;
  Serial.printf("[PANEL TEST] %s failed: %s\n", step, esp_err_to_name(result));
  return false;
}

bool command(uint8_t address, const void* data, size_t length) {
  return checked(esp_lcd_panel_io_tx_param(
      io, (0x02U << 24) | (uint32_t(address) << 8), data, length), "command");
}

bool begin() {
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, 0);
  finished = xSemaphoreCreateBinary();
  pixels = static_cast<uint16_t*>(heap_caps_malloc(
      PANEL_SIZE * rows * sizeof(uint16_t), MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
  if (!finished || !pixels) {
    Serial.println("[PANEL TEST] internal DMA allocation failed");
    return false;
  }
  spi_bus_config_t bus = {};
  bus.sclk_io_num = TFT_SCLK_PIN;
  bus.mosi_io_num = TFT_DATA0_PIN;
  bus.miso_io_num = TFT_DATA1_PIN;
  bus.quadwp_io_num = TFT_DATA2_PIN;
  bus.quadhd_io_num = TFT_DATA3_PIN;
  bus.data4_io_num = bus.data5_io_num = bus.data6_io_num = bus.data7_io_num = -1;
  bus.max_transfer_sz = PANEL_SIZE * rows * sizeof(uint16_t);
  if (!checked(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO), "SPI bus"))
    return false;
  esp_lcd_panel_io_spi_config_t config = {};
  config.cs_gpio_num = TFT_CS_PIN;
  config.dc_gpio_num = -1;
  config.spi_mode = 0;
  config.pclk_hz = 10000000;  // Conservative first pass, not a speed benchmark.
  config.trans_queue_depth = 1;
  config.on_color_trans_done = colorDone;
  config.lcd_cmd_bits = 32;
  config.lcd_param_bits = 8;
  config.flags.quad_mode = 1;
  if (!checked(esp_lcd_new_panel_io_spi(SPI2_HOST, &config, &io), "LCD IO"))
    return false;
  pinMode(TFT_RESET_PIN, OUTPUT);
  digitalWrite(TFT_RESET_PIN, HIGH);
  delay(100);
  digitalWrite(TFT_RESET_PIN, LOW);
  delay(120);
  digitalWrite(TFT_RESET_PIN, HIGH);
  delay(120);
  const auto& ops = jc3636_qspi_init;
  for (size_t i = 0; i < sizeof(ops);) {
    const auto op = ops[i++];
    if (op == BEGIN_WRITE || op == END_WRITE) continue;
    if (op == DELAY && i < sizeof(ops)) {
      delay(ops[i++]);
    } else if (op == WRITE_C8_BYTES && i + 2 <= sizeof(ops)) {
      const auto address = ops[i++];
      const size_t length = ops[i++];
      if (i + length > sizeof(ops) || !command(address, ops + i, length))
        return false;
      i += length;
    } else {
      Serial.println("[PANEL TEST] invalid init stream");
      return false;
    }
  }
  Serial.println("[PANEL TEST] direct ESP-IDF QSPI 10MHz; no BLE/NVS/navigation");
  return true;
}

bool draw(unsigned stage) {
  for (unsigned y = 0; y < PANEL_SIZE; y += rows) {
    const unsigned h = min(rows, unsigned(PANEL_SIZE) - y);
    for (unsigned r = 0; r < h; ++r)
      for (unsigned x = 0; x < PANEL_SIZE; ++x)
        pixels[r * PANEL_SIZE + x] = __builtin_bswap16(panelTestPixel(stage, x, y + r));
    const uint8_t columns[] = {0, 0, uint8_t((PANEL_SIZE - 1) >> 8),
                              uint8_t(PANEL_SIZE - 1)};
    const uint8_t lines[] = {uint8_t(y >> 8), uint8_t(y),
                             uint8_t((y + h - 1) >> 8), uint8_t(y + h - 1)};
    if (!command(0x2A, columns, sizeof(columns)) ||
        !command(0x2B, lines, sizeof(lines))) return false;
    if (!checked(esp_lcd_panel_io_tx_color(io, (0x32U << 24) | (0x2CU << 8),
                 pixels, PANEL_SIZE * h * sizeof(uint16_t)), "RAMWR")) return false;
    if (xSemaphoreTake(finished, pdMS_TO_TICKS(2000)) != pdTRUE) {
      Serial.println("[PANEL TEST] DMA completion timeout; stopped");
      return false;  // Never reuse the pending buffer.
    }
  }
  return true;
}
}  // namespace panelDiagnostic

bool panelTestReady = false;
unsigned panelTestStage = 0;
uint32_t panelTestAt = 0;

void setup() {
  Serial.begin(115200);
  delay(1000);
  panelTestReady = panelDiagnostic::begin() && panelDiagnostic::draw(0);
  if (panelTestReady) {
    analogWrite(TFT_BACKLIGHT_PIN, 128);
    Serial.println("[PANEL TEST] stage=BLACK; each stage lasts 3 seconds");
    panelTestAt = millis();
  }
}

void loop() {
  if (panelTestReady && panelTestStage < 5 && millis() - panelTestAt >= 3000) {
    const char* names[] = {"BLACK", "WHITE", "RED", "GREEN", "BLUE", "GRID"};
    ++panelTestStage;
    panelTestReady = panelDiagnostic::draw(panelTestStage);
    panelTestAt = millis();
    Serial.printf("[PANEL TEST] stage=%s status=%s\n", names[panelTestStage],
                  panelTestReady ? "transfer completed" : "FAILED");
  }
  delay(10);
}
