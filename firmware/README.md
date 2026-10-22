# ESP32 navigation display firmware

Arduino sketch:

- `esp32_nav_display/esp32_nav_display.ino`

## Current board: Waveshare ESP32-S3-Touch-LCD-1.46

The sketch defaults to `NAV_WAVESHARE_146=1`. Set it to `0` at the top
to build for the original ideaspark 240×135 ST7789 board instead.

Arduino IDE settings for the new board:

- Board: **ESP32S3 Dev Module**
- Flash Size: **16MB**; PSRAM: **OPI PSRAM**
- USB CDC On Boot: **Enabled**
- Partition Scheme: **16M Flash (3MB APP/9.9MB FATFS)**
- Tested toolchain target: Espressif Arduino core **3.3.11**

Required Arduino libraries:

- `Adafruit GFX Library`
- `GFX Library for Arduino` by moononournation (**1.6.9**, SPD2010 support)
- For the OLD board only: `Adafruit ST7735 and ST7789 Library`
- `ArduinoJson`
- ESP32 Arduino core BLE library

Hardware mapping (new board):

- SPD2010, 412×412 round LCD, QSPI data0/1/2/3 = GPIO46/45/42/41.
- Clock GPIO40, CS GPIO21, backlight GPIO5. No separate DC GPIO.
- LCD reset EXIO2 = **bit 1** of TCA9554 at I²C address `0x20`.
  It is **not GPIO2**. Reset initialization preserves other expander pins.
- Shared I²C: SDA GPIO11, SCL GPIO10, 400kHz.
- Touch INT GPIO4 and touch reset EXIO1 are not driven by this sketch.
  Touch input, speaker, battery power-button handling and sensors are not yet
  implemented. First test with USB power; this is a display/BLE port only.

The round board now uses a 240×240 logical canvas, scaled into a centered
380×380 view. Pixels outside the visible circle are clipped to black. Its map
uses the upper area and enlarged turn/distance indications use the lower area;
the original board retains its 240×135 layout. The BLE 128×64 preview-point
contract is unchanged. The scanline buffer is 760 bytes, but the larger logical
canvas needs about 115 KB of framebuffer memory; enable OPI PSRAM.
Check orientation on hardware; the SPD2010 library does not implement hardware
rotation. Do not assume changing `TFT_ROTATION` will rotate the new panel.

Official references:

- https://docs.waveshare.com/ESP32-S3-Touch-LCD-1.46
- https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.46
- https://github.com/moononournation/Arduino_GFX/tree/v1.6.9

Compilation does not prove panel initialization, orientation or refresh speed
on a physical board. Upload is a separate step; no board is flashed automatically.

BLE contract:

- Device name: `NAV-<device identity>` (derived from this board's chip identity).
  A new physical board has a different identity: use the app's change-screen
  flow and press BOOT on the new screen; an existing binding to the old board
  will not match. BOOT is GPIO0; press it only after the screen asks for it,
  not while powering up/resetting the board.
- First binding: the app writes `{"pair":"start"}` to the pairing
  characteristic, the screen shows `PRESS BOOT`, and a fresh debounced BOOT
  press sets `verified=true` for that connection. The board then generates a
  random 16-byte key, stores it in NVS, and returns it as `"k"` in the pairing
  read, on that connection only. The confirmation window lasts 60 seconds on
  the device and 35 seconds in the app. A new BOOT pairing replaces the key,
  so a previously paired phone stops working (one owner at a time).
- Every pairing read also returns `"s"`: a random 8-byte session nonce that
  is new on each connection.
- Service UUID: `12345678-1234-1234-1234-123456789abc`
- Characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456`
- Characteristic properties: `WRITE`, `WRITE_NR`

Payload from the phone (signed; unsigned writes are rejected):

```text
{"dir":"LEFT","dist":120,"n":7}|1f2e3d4c5b6a7980
```

- `n` is a counter that must increase within the connection (replay guard).
- The suffix is the first 8 bytes of HMAC-SHA256(key, nonce ‖ JSON), in hex.
  It must match the app's `PacketSigner` byte for byte;
  `tests/run_packet_auth_test.sh` checks the shared reference vectors.
- An unpaired board shows `NOT PAIRED` while connected and ignores all
  navigation writes. Upgrading from unsigned firmware requires one BOOT
  pairing; the app drops its old keyless binding automatically.
- This authenticates the phone; it does not encrypt the link. The key crosses
  the air once, in the BOOT window, so pair where nobody is sniffing BLE.

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
- If live navigation packets stop for more than 8 seconds, the display keeps
  the last arrow as context but drops the rider marker and distance and shows
  `NO UPDATE / CHECK PHONE`. While stopped, the app re-sends about every 2 s,
  backed by a fresh GPS fix, so this only appears when the phone or its GPS
  has really gone quiet. Only an explicit `STOP` packet or a BLE disconnect
  clears the navigation state. `ARRIVED` never shows as stale.
- OLED power saving is enabled:
  - standby renders only a minimal BLE status, not the navigation arrow area;
  - while the phone is connected, keep the display awake;
  - when no phone is connected, after 15 seconds idle: dim the display;
  - when no phone is connected, after 60 seconds idle: turn the OLED panel off;
  - BLE keeps advertising/connecting while the OLED is off;
  - the display wakes immediately on BLE connect or a valid navigation packet.
- Demo mode is disabled by default. Set `ENABLE_DEMO_MODE = true` in the sketch
  only for bench testing the OLED without a phone.
