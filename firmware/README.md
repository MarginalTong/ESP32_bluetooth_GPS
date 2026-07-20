# ESP32 navigation display firmware

Arduino sketch:

- `esp32_nav_display/esp32_nav_display.ino`

Required Arduino libraries:

- `Adafruit GFX Library`
- `Adafruit SH110X`
- `ArduinoJson`
- ESP32 Arduino core BLE library

OLED hardware:

- Current firmware targets a 1.3" 128x64 I2C OLED that uses the SH1106
  controller, via `Adafruit_SH1106G`.
- The firmware tries I2C address `0x3C` first, then `0x3D`.
- If you switch back to a 0.96" SSD1306 module, change the display driver back
  to `Adafruit_SSD1306`.

BLE contract:

- Device name: `ESP32_NAV`
- Service UUID: `12345678-1234-1234-1234-123456789abc`
- Characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456`
- Characteristic properties: `WRITE`, `WRITE_NR`

Payload from the phone:

```json
{"dir":"LEFT","dist":120}
```

Supported `dir` values:

- `UP`
- `LEFT`
- `RIGHT`
- `BEAR_LEFT`
- `BEAR_RIGHT`
- `UTURN`
- `STOP`
- `ARRIVED`

Production behavior:

- BLE advertising restarts automatically after phone disconnect.
- Invalid JSON or invalid directions are rejected.
- If live navigation packets stop for more than 8 seconds, the display shows
  `WAIT` in the top status area but keeps the last direction on screen. The
  phone app throttles repeated BLE packets, so firmware must not clear the
  instruction just because no new packet arrived for a few seconds. Only an
  explicit `STOP` packet or a BLE disconnect clears the navigation state.
- OLED power saving is enabled:
  - standby renders only a minimal BLE status, not the navigation arrow area;
  - while the phone is connected, keep the display awake;
  - when no phone is connected, after 15 seconds idle: dim the display;
  - when no phone is connected, after 60 seconds idle: turn the OLED panel off;
  - BLE keeps advertising/connecting while the OLED is off;
  - the display wakes immediately on BLE connect or a valid navigation packet.
- Demo mode is disabled by default. Set `ENABLE_DEMO_MODE = true` in the sketch
  only for bench testing the OLED without a phone.
