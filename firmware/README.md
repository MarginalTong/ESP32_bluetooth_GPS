# ESP32 navigation display firmware

Arduino sketch:

- `esp32_nav_display/esp32_nav_display.ino`

## PlatformIO in VS Code (macOS)

Open the **repository root** (`ESP32_bluetooth_GPS`) in VS Code so its
`.vscode/tasks.json` is loaded. Use **Terminal → Run Task**:

| Task | Action |
| --- | --- |
| `NAVIO: Verify` | Incremental PlatformIO build; also the default ⇧⌘B build task. |
| `NAVIO: Upload` | Build and upload through PlatformIO. |
| `NAVIO: Upload + Serial Monitor` | Build, upload, then display shared serial output. |
| `NAVIO: Serial Monitor` | View the same serial stream without flashing. |
| `NAVIO: Stop Serial Monitor` | Stop the background reader and release USB. |
| `NAVIO: Status` | Show board options, USB port, monitor state and log path. |

The equivalent agent/terminal commands, from the repository root, are:

```sh
~/.platformio/penv/bin/pio run -e waveshare_146
~/.platformio/penv/bin/pio run -e waveshare_146 -t upload
~/.platformio/penv/bin/python firmware/tools/navo_monitor.py view
~/.platformio/penv/bin/python firmware/tools/navo_monitor.py stop
~/.platformio/penv/bin/python firmware/tools/navo_monitor.py status
```

Install the official `platformio.platformio-ide` VS Code extension. Both the
extension and command line use PlatformIO Core in `~/.platformio/penv`.
The pinned ESP32 platform requires **Python 3.10 or later**; this Mac uses
Python 3.13 and PlatformIO Core 6.2.0. All builds and uploads use PlatformIO;
there is no dependency on Arduino CLI, the Arduino IDE application or its
installed libraries. `platformio.ini` pins the pioarduino platform
**55.03.311**, Espressif Arduino core **3.3.11**, and library versions.
PlatformIO downloads and caches the tools and dependencies itself.
`firmware/platformio/main.cpp` is its C++ entry point and includes the existing
board/drawing `.ino` source, alongside separately compiled UI modules. This
avoids a temporary `.ino.cpp` file being removed
when the monitor's exception decoder requests metadata during a build.

Board settings are fixed in `platformio.ini`: 16 MB Flash, OPI PSRAM,
USB CDC enabled, QIO 80 MHz, 240 MHz CPU, 3 MB app/9.9 MB FATFS, 921600 baud
upload, **no full-flash erase**. The monitor runs at **115200 baud**.
With multiple USB devices, configure matching `upload_port` and `monitor_port`
in `platformio.ini` and pass `--port` to the shared-monitor task.

The PlatformIO toolbar's plug button opens `NAVIO: Serial Monitor`. It runs
one native **`pio device monitor`** with the built-in `time` and
`esp32_exception_decoder` filters, through a small persistent terminal
supervisor (`firmware/tools/navo_monitor.py`). Its UTC-timestamped output is
copied to **`.navo/serial.log`**. VS Code and Codex read the same file; extra
viewers do not open the USB port. The toolbar's upload button runs the upload
task then displays that shared stream.

PlatformIO's upload hooks (`firmware/tools/pio_upload.py`) pause the shared
monitor before flashing and resume it afterward. This works for both toolbar
uploads and direct `pio run -t upload`. Failed/interrupted uploads release
the locks too. Unplug/replug also reconnects automatically when one USB serial
device is present. Use the shared plug button rather than opening a second
independent serial monitor. Close any Arduino IDE serial monitor first.
Ctrl+C closes only a viewer; the Stop Serial Monitor task releases the port.
`.pio/` holds disposable build output/dependencies and `.navo/` holds local
monitor logs/state; both are ignored by Git.

## UI state and screen modules

- `platformio/nav_types.h`: shared maneuver/distance types.
- `platformio/ui_state.h/.cpp`: a pure resolver from one snapshot of device
  facts to one `UiScreen`. It does not read globals or depend on Arduino/BLE.
- `platformio/ui_screens.h/.cpp`: page composition and text/layout. It consumes
  the resolved page and frame-local data, never raw connection/pairing flags.
- `platformio/ui_draw.h`: drawing operations implemented by the current board
  adapter in `esp32_nav_display.ino` (fonts, route geometry, screen transfer).

`loop()` applies BLE data, updates timeout/power state, then resolves the page
once. A page or subtitle change marks the display dirty. Clock and close-turn
blink refreshes are scheduled only for the page that actually uses them.
The existing 25 ms animation frame limit is unchanged.
`[RENDER]` diagnostics aggregate real frame time, CPU drawing/composition time,
and LCD transfer time at most once every five seconds when frames are drawn.
Idle gaps between navigation packets are not interpreted as animation FPS.
Serial logs record page transitions once (for example,
`[UI] navigating -> stale_guidance`), not on every animation frame.

Page priority preserves the existing behavior: an unavailable/off panel wins,
then BOOT pairing; disconnected/idle states are resolved before route states;
rerouting wins over STOP/ARRIVED; STOP shows no guidance; ARRIVED never expires;
otherwise stale guidance and live navigation are distinct pages. Explicit trip
end returns to NAVIO, while an unexpected link loss shows CONNECTION LOST.
Cached/stale pages never show a live rider marker or countdown.

Run the board-free state/renderer tests with:

```sh
bash firmware/tests/run_ui_state_test.sh
```

They check transitions, conflicting flag combinations and drawing commands
for both round and legacy screen layouts. The existing animation,
authentication and rendering host tests remain separate.

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

The round board uses a 240×240 logical layout rasterized across the full
412×412 physical panel. On `experiment/aa-render-360`, PlatformIO sets
`NAVIO_RENDER_SIZE=360`: the AA layer is 360×360 and is enlarged to 412×412
using precomputed nearest-sample tables. Physical UI size, circle clipping,
BLE coordinates and panel transfer resolution do not change. This reduces
AA raster pixels by 23.6% and its PSRAM allocation by 40,144 bytes, but does
not reduce LCD transfer bytes or guarantee 40 FPS. Remove the build flag to
return to the 412×412 default. The renderer uses **anti-aliased edges** for
text, routes, arrows and the rider marker. Font rendering uses bilinear
supersampling and shapes use fractional pixel coverage. Side roads keep their
along-road fade. The 25 ms animation frame limit is unchanged.
The previous no-AA experiment is preserved at commit `9f946c1` on
`experiment/no-antialiasing`; anti-aliasing has been restored on
`fix/restore-antialiasing` using the renderer from `77d92da`.

With OPI PSRAM enabled, drawing uses the configured AA raster resolution.
Pixels outside the visible circle are clipped to black. Large clock and
distance digits retain their pre-rasterized Roboto Medium numeric subset
(Apache License 2.0); its 4-bit mask preserves fractional edge coverage.
`firmware/tools/generate_numeric_font.py` regenerates the
bundled header.
The map uses the upper area and the enlarged turn/distance indications use the
lower area; the original board retains its 240×135 layout. The BLE 128×64
preview-point contract is unchanged. Enable OPI PSRAM for the native gray
layer and the logical framebuffer; allocation failure falls back to the
pixelated 240×240 canvas.
Verify the rasterizer with `bash firmware/tests/run_anti_alias_render_test.sh`.
Its boot log reports the AA raster dimensions and the physical panel dimensions;
actual panel FPS/power must be measured on hardware.
Check orientation on hardware; the SPD2010 library does not implement hardware
rotation. Do not assume changing `TFT_ROTATION` will rotate the new panel.

Official references:

- https://docs.waveshare.com/ESP32-S3-Touch-LCD-1.46
- https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.46
- https://github.com/moononournation/Arduino_GFX/tree/v1.6.9

Compilation does not prove panel initialization, orientation or refresh speed
on a physical board. Upload is a separate step; no board is flashed automatically.

BLE contract:

- Device name: `NAVIO-<device identity>` (derived from this board's chip identity).
  The App still discovers legacy `NAV-…` and `ESP32_NAV` firmware.
  A new physical board has a different identity: use the app's change-screen
  flow and press BOOT on the new screen; an existing binding to the old board
  will not match. BOOT is GPIO0; press it only after the screen asks for it,
  not while powering up/resetting the board.
- First binding: the app writes `{"pair":"start"}` to the pairing
  characteristic, the screen shows `PRESS BOOT`, and a fresh debounced BOOT
  press sets `verified=true` for that connection. The board then generates a
  random 16-byte key, stores it in NVS, and returns it as `"k"` in the pairing
  read, on that connection only. The confirmation window lasts 60 seconds on
  the device and 35 seconds in the app.
- Re-pairing is recoverable. A new BOOT pairing issues a new key, but the
  previously proven key stays valid until the new key is used on a later,
  ordinary connection; only then is the old key retired (one owner at a
  time). So if the link drops right after BOOT, before the phone stores the
  new key, the phone keeps working with its old key. NVS holds `k` (current),
  `kp` (current proven) and `p` (previous, while `k` is unproven).
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

`STOP` is a temporary no-guidance state (pause or lost GPS). Ending a trip
sends the distinct signed payload `{"dir":"STOP","dist":0,"end":true}`.
Only that end marker returns the display to the NAVIO standby page, including
after the app disconnects; an unexpected BLE drop still shows
`CONNECTION LOST`. Both app and display firmware must support this marker.

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
