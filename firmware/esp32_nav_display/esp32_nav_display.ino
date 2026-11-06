#include "../platformio/board_config.h"
#include <SPI.h>
#include <Adafruit_GFX.h>
#if NAV_ROUND_DISPLAY
#include <Wire.h>
#include <Arduino_GFX_Library.h>
#if NAV_JC3636W518C
#include "../platformio/jc3636_panel_init.h"
#endif
#include <Fonts/FreeSans9pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>
#include <Fonts/FreeSansBold24pt7b.h>
#if !defined(CONFIG_IDF_TARGET_ESP32S3)
#error "Select an ESP32-S3 target for the round display boards"
#endif
#else
#include <Adafruit_ST7789.h>
#endif

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#include <ArduinoJson.h>
// Both builds compile the ROUTE RENDER block, which uses them.
#include "numeric_font.h"
#include "text_font.h"
#include <Preferences.h>
#include <esp_random.h>
#include <esp_system.h>
#include <mbedtls/md.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>
#include <math.h>
#include <esp_system.h>
#include <esp_heap_caps.h>
#include "../platformio/ui_screens.h"
#include "../platformio/ui_draw.h"
#include "../platformio/arrival_feedback.h"
#include "../platformio/gray_layer.h"
#include "../platformio/side_road_ray.h"

// BEGIN MAP MOTION - also compiled by the host animation tests.
// Display-only interpolation. Never used for maneuver or distance decisions.
// Each packet starts a linear glide from where the map is drawn now to the
// new geometry, lasting about one packet interval, so ~1 Hz updates read as
// continuous motion instead of a short hop followed by a pause.
struct MapMotion {
  // 20 route points, then 2 side-road segments (x0, y0, x1, y1 each).
  static constexpr uint8_t kRouteValues = 40;
  static constexpr uint8_t kValues = kRouteValues + 8;
  static constexpr uint32_t kMinDurationMs = 120;
  static constexpr uint32_t kMaxDurationMs = 1100;
  // Longer gaps are pauses (phone stopped sending), not the packet rate.
  static constexpr uint32_t kMaxIntervalMs = 3000;
  // Larger moves, in route-source units, are route changes: no glide.
  static constexpr float kSnapDistance = 24.0f;
  float current[kValues] = {};
  float start[kValues] = {};
  float target[kValues] = {};
  uint8_t routes = 0, roads = 0;
  uint32_t started = 0, durationMs = 0, lastPacket = 0;
  float packetIntervalMs = 1000.0f;
  bool valid = false, active = false;

  bool tick(uint32_t now) {
    if (!active) return false;
    const uint32_t elapsed = now - started;
    const float t = elapsed >= durationMs ? 1.0f : float(elapsed) / durationMs;
    for (int i = 0; i < kValues; ++i)
      current[i] = start[i] + (target[i] - start[i]) * t;
    active = elapsed < durationMs;
    return true;
  }

  bool jumped(const float* values, int from, int to) const {
    for (int i = from; i < to; ++i)
      if (fabsf(values[i] - current[i]) > kSnapDistance) return true;
    return false;
  }

  void accept(const float* values, uint8_t routeCount, uint8_t roadCount,
              uint32_t now) {
    tick(now);
    if (valid && now - lastPacket <= kMaxIntervalMs)
      packetIntervalMs += (float(now - lastPacket) - packetIntervalMs) * 0.3f;
    lastPacket = now;
    // The route and the side roads snap independently, so a side road
    // appearing does not make the route jump.
    const bool snapRoute =
        !valid || routes != routeCount || jumped(values, 0, kRouteValues);
    const bool snapRoads =
        !valid || roads != roadCount || jumped(values, kRouteValues, kValues);
    bool changed = snapRoute || snapRoads;
    for (int i = 0; i < kValues; ++i) changed = changed || values[i] != target[i];
    if (!changed) return;
    routes = routeCount;
    roads = roadCount;
    for (int i = 0; i < kValues; ++i) {
      const bool snap = i < kRouteValues ? snapRoute : snapRoads;
      start[i] = snap ? values[i] : current[i];
      target[i] = values[i];
      if (snap) current[i] = values[i];
    }
    const float interval = packetIntervalMs < kMinDurationMs ? kMinDurationMs
                           : packetIntervalMs > kMaxDurationMs ? kMaxDurationMs
                                                               : packetIntervalMs;
    durationMs = uint32_t(interval);
    started = now;
    valid = true;
    active = !(snapRoute && snapRoads);
  }
};
// END MAP MOTION

// ======================================================
// Hardware
// ======================================================

// Keep the old panel's layout; give the round panel a square map/instruction
// layout instead of letterboxing the 240x135 strip in the middle of the LCD.
constexpr int16_t SCREEN_WIDTH = 240;
#if NAV_ROUND_DISPLAY
constexpr int16_t SCREEN_HEIGHT = 240;
#else
constexpr int16_t SCREEN_HEIGHT = 135;
#endif

// Route-preview points use the old 128x64 coordinate system, scaled into the
// large TFT map. Current apps send them in tenths ("P"/"R"); older ones send
// whole units ("p"/"r").
constexpr int16_t ROUTE_SOURCE_WIDTH = 128;
constexpr int16_t ROUTE_SOURCE_HEIGHT = 64;

#if NAV_ROUND_DISPLAY
// Output always fills the physical panel; rendering resolution is independent.
constexpr int16_t PANEL_VIEW_WIDTH = PANEL_SIZE;
constexpr int16_t PANEL_VIEW_HEIGHT = PANEL_SIZE;
constexpr int16_t PANEL_VIEW_X = (PANEL_SIZE - PANEL_VIEW_WIDTH) / 2;
constexpr int16_t PANEL_VIEW_Y = (PANEL_SIZE - PANEL_VIEW_HEIGHT) / 2;
constexpr int16_t PANEL_VISIBLE_RADIUS = PANEL_SIZE / 2 - 3;
constexpr int16_t NATIVE_LAYER_SIZE = NAVIO_RENDER_SIZE;
static_assert(NAVIO_RENDER_SIZE >= SCREEN_WIDTH && NAVIO_RENDER_SIZE <= PANEL_SIZE,
              "Render size must be between the logical canvas and physical panel");
static_assert(PANEL_VIEW_WIDTH * SCREEN_HEIGHT == PANEL_VIEW_HEIGHT * SCREEN_WIDTH,
              "Preserve the logical canvas aspect ratio");
Arduino_ESP32QSPI lcdBus(TFT_CS_PIN, TFT_SCLK_PIN, TFT_DATA0_PIN,
                        TFT_DATA1_PIN, TFT_DATA2_PIN, TFT_DATA3_PIN);
#if NAV_JC3636W518C
// Apply inversion explicitly below; Arduino_GFX XORs it with the IPS flag.
Arduino_ST77916 tft(&lcdBus, TFT_RESET_PIN, TFT_PANEL_ROTATION, false,
                    PANEL_SIZE, PANEL_SIZE,
                    0, 0, 0, 0, jc3636_qspi_init, sizeof(jc3636_qspi_init));
#else
Arduino_SPD2010 tft(&lcdBus, GFX_NOT_DEFINED);
#endif
#else
// ideaspark / ESP32 built-in 1.14-inch ST7789 configuration. If your board is
// mirrored or upside-down, change TFT_ROTATION to 3.
constexpr int8_t TFT_MOSI_PIN = 23;
constexpr int8_t TFT_SCLK_PIN = 18;
constexpr int8_t TFT_CS_PIN = 15;
constexpr int8_t TFT_DC_PIN = 2;
constexpr int8_t TFT_RESET_PIN = 4;
constexpr int8_t TFT_BACKLIGHT_PIN = 32;
constexpr uint8_t TFT_ROTATION = 1;
Adafruit_ST7789 tft(TFT_CS_PIN, TFT_DC_PIN, TFT_RESET_PIN);
#endif
#if NAV_JC3636W518C
// Full backlight lifts this IPS panel's black to a bluish grey around white
// UI; a lower level keeps black darker. Raise it if sunlight demands.
constexpr uint8_t BACKLIGHT_NORMAL = 160;
#else
constexpr uint8_t BACKLIGHT_NORMAL = 255;
#endif
constexpr uint8_t BACKLIGHT_DIM = 24;

GFXcanvas16 display(SCREEN_WIDTH, SCREEN_HEIGHT);

constexpr uint16_t COLOR_BG = 0x0000;
constexpr uint16_t COLOR_WHITE = 0xFFFF;
constexpr uint16_t COLOR_ROUTE = COLOR_WHITE;
// Primary indications are white; side-road edges fade through grayscale.
constexpr uint16_t COLOR_ACCENT = COLOR_WHITE;
bool displayAvailable = false;
volatile bool displayDirty = true;

// ======================================================
// Product behavior
// ======================================================

// If the phone stops sending navigation packets, stop showing a stale turn.
constexpr uint32_t LIVE_PACKET_TIMEOUT_MS = 8000;

// TFT power policy. BLE keeps running while the display is dim/off.
constexpr uint32_t DISPLAY_DIM_AFTER_IDLE_MS = 15000;
constexpr uint32_t DISPLAY_OFF_AFTER_IDLE_MS = 60000;
// At most 40 route-animation frames per second (25 ms between frame starts).
// The loop still draws only when displayDirty; static navigation does not
// continuously redraw. Actual panel FPS also depends on render/SPI time.
constexpr uint32_t DISPLAY_REFRESH_MS = 25;

constexpr int MAX_DISTANCE_M = 9999;
constexpr uint8_t MAX_ROUTE_PREVIEW_POINTS = 20;
// Two junction arms match the reference cluster view and keep the compact JSON
// safely below conservative iOS BLE write-without-response payload sizes.
constexpr uint8_t MAX_SIDE_ROAD_SEGMENTS = 2;

// ======================================================
// BLE contract - must match the Flutter app.
// ======================================================

char DEVICE_NAME[20] = "NAVIO";
char deviceIdentity[13] = "";
// Waveshare's BOOT button pulls GPIO0 low. Never hold it while resetting,
// because GPIO0 is also the ESP32-S3 download-mode strap.
constexpr int8_t BOOT_BUTTON_PIN = 0;
volatile bool pairingActive = false;
volatile bool pairingVerified = false;
volatile bool pairingButtonReleased = false;
volatile uint32_t pairingStartedMs = 0;
uint32_t bootLowSinceMs = 0;
// Power-up pairing: one pairing per power-on, only within PAIR_WINDOW_MS.
volatile bool pairWindowUsed = false;
// A pairing request arrived after the window closed; told to the phone.
volatile bool pairingRefused = false;
constexpr char PAIRING_UUID[] = "abcd1234-5678-1234-5678-abcdef123457";
constexpr char SERVICE_UUID[] = "12345678-1234-1234-1234-123456789abc";
constexpr char CHARACTERISTIC_UUID[] = "abcd1234-5678-1234-5678-abcdef123456";

BLEServer* bleServer = nullptr;
BLEAdvertising* bleAdvertising = nullptr;
BLECharacteristic* pairingCharacteristic = nullptr;

bool bleConnected = false;
bool hadBleConnection = false;

enum class DisplayPowerState : uint8_t {
  On,
  Dim,
  Off,
};

DisplayPowerState displayPowerState = DisplayPowerState::On;
uint32_t lastDisplayActivityMs = 0;

// ======================================================
// Navigation state
// ======================================================

NavState nav = {Direction::Stop, 0};
bool rerouting = false;
bool clockSynced = false;
UiState uiState;
ArrivalFeedback arrivalFeedback;

// Placed after the enum declarations: the Arduino preprocessor inserts its
// generated prototypes before the first function definition.
// BEGIN PACKET AUTH - also compiled by the host authentication tests.
// Must match the App's PacketSigner byte for byte. A navigation write is
// "<json>|<16 hex>": the tag is the first 8 bytes of
// HMAC-SHA256(key, sessionNonce || json). The key is issued at a BOOT-confirmed
// pairing; the nonce is new on every connection, so recorded packets cannot be
// replayed into a later session. The JSON's counter "n" is checked by the
// caller after parsing.
constexpr size_t AUTH_KEY_BYTES = 16;
constexpr size_t AUTH_NONCE_BYTES = 8;
constexpr size_t AUTH_TAG_BYTES = 8;

// Provided by the sketch (mbedtls) or the host test (CommonCrypto).
bool navHmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* a,
                   size_t aLength, const uint8_t* b, size_t bLength,
                   uint8_t out[32]);

inline int authHexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Returns the length of the authenticated JSON before '|', or -1.
inline int verifyPacketTag(const uint8_t key[AUTH_KEY_BYTES],
                           const uint8_t nonce[AUTH_NONCE_BYTES],
                           const char* packet, size_t length) {
  constexpr size_t suffix = 1 + AUTH_TAG_BYTES * 2;
  if (packet == nullptr || length <= suffix + 1) return -1;
  const size_t jsonLength = length - suffix;
  if (packet[jsonLength] != '|') return -1;
  uint8_t tag[AUTH_TAG_BYTES];
  for (size_t i = 0; i < AUTH_TAG_BYTES; ++i) {
    const int high = authHexNibble(packet[jsonLength + 1 + i * 2]);
    const int low = authHexNibble(packet[jsonLength + 2 + i * 2]);
    if (high < 0 || low < 0) return -1;
    tag[i] = static_cast<uint8_t>(high << 4 | low);
  }
  uint8_t mac[32];
  if (!navHmacSha256(key, AUTH_KEY_BYTES, nonce, AUTH_NONCE_BYTES,
                     reinterpret_cast<const uint8_t*>(packet), jsonLength,
                     mac)) {
    return -1;
  }
  // Constant time: do not reveal how many leading tag bytes were right.
  uint8_t difference = 0;
  for (size_t i = 0; i < AUTH_TAG_BYTES; ++i) difference |= mac[i] ^ tag[i];
  return difference == 0 ? static_cast<int>(jsonLength) : -1;
}

// Key rotation that a dropped link cannot break. A BOOT pairing issues a new
// key, but the phone may disconnect before it stores it. So the last proven
// key stays valid until the new key is used on a later, non-pairing
// connection, which proves the phone kept it. Pure state: the sketch persists
// it to NVS and guards it with stateMux.
enum class AuthKeyMatch : uint8_t { None, Current, Previous };

struct KeyRing {
  uint8_t current[AUTH_KEY_BYTES] = {};
  uint8_t previous[AUTH_KEY_BYTES] = {};
  bool hasCurrent = false;
  bool currentProven = false;
  bool hasPrevious = false;

  void rotate(const uint8_t fresh[AUTH_KEY_BYTES]) {
    // Keep the newest key a phone is known to hold. An unproven current key
    // only replaces `previous` when there is nothing better to keep.
    if (hasCurrent && (currentProven || !hasPrevious)) {
      memcpy(previous, current, AUTH_KEY_BYTES);
      hasPrevious = true;
    }
    memcpy(current, fresh, AUTH_KEY_BYTES);
    hasCurrent = true;
    currentProven = false;
  }

  AuthKeyMatch match(const uint8_t nonce[AUTH_NONCE_BYTES], const char* packet,
                     size_t length, int* jsonLength) const {
    if (hasCurrent) {
      *jsonLength = verifyPacketTag(current, nonce, packet, length);
      if (*jsonLength >= 0) return AuthKeyMatch::Current;
    }
    if (hasPrevious) {
      *jsonLength = verifyPacketTag(previous, nonce, packet, length);
      if (*jsonLength >= 0) return AuthKeyMatch::Previous;
    }
    *jsonLength = -1;
    return AuthKeyMatch::None;
  }

  // Record an accepted write. Returns true when the ring changed and must be
  // persisted: the current key was used outside the connection that issued
  // it, so the previous key can be retired.
  bool noteUsed(AuthKeyMatch which, bool pairingConnection) {
    if (which != AuthKeyMatch::Current || pairingConnection || currentProven) {
      return false;
    }
    currentProven = true;
    if (hasPrevious) {
      memset(previous, 0, AUTH_KEY_BYTES);
      hasPrevious = false;
    }
    return true;
  }
};
// END PACKET AUTH

// Native-resolution drawing: platformio/gray_layer.h.

// Explicit: the generated prototype would precede the KeyRing declaration.
bool persistKeyRing(const KeyRing& ring);

constexpr uint8_t MAP_VALUE_COUNT =
    MAX_ROUTE_PREVIEW_POINTS * 2 + MAX_SIDE_ROAD_SEGMENTS * 4;
static_assert(MAP_VALUE_COUNT == MapMotion::kValues &&
                  MAX_ROUTE_PREVIEW_POINTS * 2 == MapMotion::kRouteValues,
              "MapMotion's layout matches the packet limits");

// BLE callbacks run on the Bluetooth stack's FreeRTOS task. They only publish
// into this mailbox under stateMux; loop() takes a snapshot each iteration and
// owns every navigation, timeout, error and backlight variable.
struct BleMailbox {
  bool connected = false;
  uint32_t disconnects = 0;
  bool clockSynced = false;
  bool navReady = false;
  NavState nav = {Direction::Stop, 0};
  bool rerouting = false;
  bool tripEnded = false;
  float map[MAP_VALUE_COUNT] = {};
  uint8_t routes = 0, roads = 0;
  bool errorReady = false;
  char error[48] = "";
  bool wake = false;
  // keyRing changed in the BLE task; loop() writes it to NVS.
  bool persistKeys = false;
};
// Also guards every read and write of the pairing flags and packet-auth
// key/nonce below, which the BLE task and loop() share.
portMUX_TYPE stateMux = portMUX_INITIALIZER_UNLOCKED;

// Issued by BOOT-confirmed pairings and kept in NVS; until the first one every
// navigation write is rejected. Persisted only from loop().
Preferences authStore;
KeyRing keyRing;
// True on the connection where BOOT issued the current key: its own use there
// does not prove the phone stored it.
bool pairingConnection = false;
// New random value on every connection; read by the phone before signing.
uint8_t sessionNonce[AUTH_NONCE_BYTES] = {};
// Highest accepted counter "n" this connection. BLE task only: connect and
// write callbacks run on the same Bluetooth host task.
uint32_t sessionCounter = 0;
BleMailbox mailbox;
MapMotion mapMotion;
#if NAV_ROUND_DISPLAY
// The whole UI at the panel's native resolution, in PSRAM. Drawing code keeps
// the 240x240 canvas coordinates and scales them. Without PSRAM everything is
// drawn into the canvas and upscaled, as before.
GrayLayer nativeLayer;
PanelComposer panelComposer;
// Set when the current frame drew into nativeLayer; cleared once presented.
bool nativeLayerDrawn = false;
#endif

uint32_t lastLivePacketMs = 0;
bool hasReceivedNavPacket = false;
bool tripEnded = false;
bool livePacketTimedOut = false;
uint32_t rejectedPacketCount = 0;
char lastError[48] = "";
uint32_t lastFrameTransferUs = 0;

// Arduino's .ino preprocessor sometimes generates function prototypes before
// custom enum classes are declared, which breaks types like Direction and
// DisplayPowerState. Keep explicit prototypes here so the generated sketch
// compiles reliably in Arduino IDE.
Direction parseDirection(const char* value);
const char* directionName(Direction direction);
void setDisplayPower(DisplayPowerState state);
void presentDisplay();
void drawDirection(Direction direction);
void drawMiniRouteMap(bool showRider, Direction direction);
#if NAV_ROUND_DISPLAY
void drawRoundCenteredText(const char* value, uint8_t size, int16_t top);
#endif

// ======================================================
// Direction helpers
// ======================================================

Direction parseDirection(const char* value) {
  if (value == nullptr) return Direction::Unknown;
  if (strcmp(value, "UP") == 0) return Direction::Up;
  if (strcmp(value, "LEFT") == 0) return Direction::Left;
  if (strcmp(value, "RIGHT") == 0) return Direction::Right;
  if (strcmp(value, "BEAR_LEFT") == 0) return Direction::BearLeft;
  if (strcmp(value, "BEAR_RIGHT") == 0) return Direction::BearRight;
  if (strcmp(value, "UTURN") == 0) return Direction::UTurn;
  if (strcmp(value, "STOP") == 0) return Direction::Stop;
  if (strcmp(value, "ARRIVED") == 0) return Direction::Arrived;
  return Direction::Unknown;
}

const char* directionName(Direction direction) {
  switch (direction) {
    case Direction::Up:
      return "UP";
    case Direction::Left:
      return "LEFT";
    case Direction::Right:
      return "RIGHT";
    case Direction::BearLeft:
      return "BEAR_LEFT";
    case Direction::BearRight:
      return "BEAR_RIGHT";
    case Direction::UTurn:
      return "UTURN";
    case Direction::Stop:
      return "STOP";
    case Direction::Arrived:
      return "ARRIVED";
    default:
      return "UNKNOWN";
  }
}

void setLastError(const char* message) {
  if (strncmp(lastError, message, sizeof(lastError)) == 0) return;
  strlcpy(lastError, message, sizeof(lastError));
  displayDirty = true;
}

// BLE task only: hand an error message to loop().
void publishError(const char* message) {
  portENTER_CRITICAL(&stateMux);
  strlcpy(mailbox.error, message, sizeof(mailbox.error));
  mailbox.errorReady = true;
  portEXIT_CRITICAL(&stateMux);
  displayDirty = true;
}

void publishBadDirectionError(const char* value) {
  char message[sizeof(lastError)];
  snprintf(message, sizeof(message), "bad:%.24s", value == nullptr ? "" : value);
  publishError(message);
}

bool navHmacSha256(const uint8_t* key, size_t keyLength, const uint8_t* a,
                   size_t aLength, const uint8_t* b, size_t bLength,
                   uint8_t out[32]) {
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (info == nullptr) return false;
  mbedtls_md_context_t context;
  mbedtls_md_init(&context);
  const bool ok = mbedtls_md_setup(&context, info, 1) == 0 &&
                  mbedtls_md_hmac_starts(&context, key, keyLength) == 0 &&
                  mbedtls_md_hmac_update(&context, a, aLength) == 0 &&
                  mbedtls_md_hmac_update(&context, b, bLength) == 0 &&
                  mbedtls_md_hmac_finish(&context, out) == 0;
  mbedtls_md_free(&context);
  return ok;
}

// NVS layout (namespace "navauth"): "k" current key, "kp" whether the current
// key is proven, "p" the previous key while the current one is unproven.
void loadAuthKey() {
  KeyRing loaded;
  if (authStore.begin("navauth", true)) {
    loaded.hasCurrent = authStore.getBytes("k", loaded.current,
                                           AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
    // Keys stored before rotation existed are proven: their phone has them.
    loaded.currentProven = authStore.getBool("kp", true);
    loaded.hasPrevious = authStore.getBytes("p", loaded.previous,
                                            AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
  }
  authStore.end();
  portENTER_CRITICAL(&stateMux);
  keyRing = loaded;
  portEXIT_CRITICAL(&stateMux);
  Serial.println(loaded.hasCurrent ? "[AUTH] Pairing key loaded"
                                   : "[AUTH] Not paired yet");
}

// loop() only. Writes every field so a partial earlier write cannot linger.
bool persistKeyRing(const KeyRing& ring) {
  if (!authStore.begin("navauth", false)) return false;
  bool ok = !ring.hasCurrent ||
            authStore.putBytes("k", ring.current, AUTH_KEY_BYTES) == AUTH_KEY_BYTES;
  ok = ok && authStore.putBool("kp", ring.currentProven) > 0;
  if (ring.hasPrevious) {
    ok = ok && authStore.putBytes("p", ring.previous, AUTH_KEY_BYTES) ==
                   AUTH_KEY_BYTES;
  } else if (authStore.isKey("p")) {
    ok = ok && authStore.remove("p");
  }
  authStore.end();
  return ok;
}

// Rotate to a fresh key on a BOOT pairing. Persisted before it is exposed: a
// power cut right after the phone saves it must not lose it. The previously
// proven key keeps working until the new one is proven (see KeyRing).
bool issueAuthKey() {
  uint8_t fresh[AUTH_KEY_BYTES];
  esp_fill_random(fresh, sizeof(fresh));
  KeyRing next;
  portENTER_CRITICAL(&stateMux);
  next = keyRing;
  portEXIT_CRITICAL(&stateMux);
  next.rotate(fresh);
  memset(fresh, 0, sizeof(fresh));
  if (!persistKeyRing(next)) return false;
  portENTER_CRITICAL(&stateMux);
  keyRing = next;
  portEXIT_CRITICAL(&stateMux);
  memset(&next, 0, sizeof(next));
  return true;
}

bool isLiveFresh() {
  return lastLivePacketMs > 0 && millis() - lastLivePacketMs <= LIVE_PACKET_TIMEOUT_MS;
}

bool shouldKeepDisplayAwake() {
  return bleConnected || hasReceivedNavPacket ||
         nav.direction == Direction::Arrived;
}

UiInputs captureUiInputs() {
  UiInputs inputs;
  // The BLE task owns pairing/auth changes; all other facts below belong to
  // loop(). Take this pair together instead of reading them during drawing.
  portENTER_CRITICAL(&stateMux);
  inputs.pairing = pairingActive;
  inputs.paired = keyRing.hasCurrent;
  portEXIT_CRITICAL(&stateMux);
  inputs.displayAvailable = displayAvailable;
  inputs.displayOn = displayPowerState != DisplayPowerState::Off;
  inputs.connected = bleConnected;
  inputs.hadConnection = hadBleConnection;
  inputs.hasNavigation = hasReceivedNavPacket;
  inputs.tripEnded = tripEnded;
  inputs.clockSynced = clockSynced;
  inputs.rerouting = rerouting;
  inputs.packetTimedOut = livePacketTimedOut;
  inputs.routePointCount = mapMotion.routes;
  inputs.navigation = nav;
  const uint32_t now = millis();
  arrivalFeedback.update(inputs.connected && inputs.hasNavigation &&
      !inputs.tripEnded && !inputs.rerouting && nav.direction == Direction::Arrived, now);
  inputs.arrivalElapsedMs = arrivalFeedback.elapsed(now);
  return inputs;
}

void refreshUiState() {
  const UiState next = resolveUiState(captureUiInputs());
  if (next.screen != uiState.screen) {
    Serial.printf("[UI] %s -> %s\n", uiScreenName(uiState.screen),
                  uiScreenName(next.screen));
  }
  if (next.screen != uiState.screen || next.connected != uiState.connected ||
      next.navigation.direction != uiState.navigation.direction ||
      next.navigation.distanceMeters != uiState.navigation.distanceMeters ||
      (next.screen == UiScreen::Arrived && next.arrivalProgress != uiState.arrivalProgress)) {
    displayDirty = true;
  }
  uiState = next;
}

void setDisplayPower(DisplayPowerState state) {
  if (!displayAvailable) return;
  if (displayPowerState == state) return;
  displayPowerState = state;
  displayDirty = true;

  switch (state) {
    case DisplayPowerState::On:
      analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);
      break;
    case DisplayPowerState::Dim:
      analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_DIM);
      break;
    case DisplayPowerState::Off:
      analogWrite(TFT_BACKLIGHT_PIN, 0);
      break;
  }
}

void wakeDisplay() {
  lastDisplayActivityMs = millis();
  setDisplayPower(DisplayPowerState::On);
}

// ======================================================
// BLE
// ======================================================

// The stack keeps the last read response as the attribute value. Wipe it
// between connections so a later client (e.g. a Read Blob at an offset)
// cannot see a response that carried the pairing key.
void clearPairingValue() {
  if (pairingCharacteristic != nullptr) pairingCharacteristic->setValue("{}");
}

// Why the chip last started, reported to the phone on every pairing read so
// a dropped connection can be told apart from a crash or brownout reset.
const char* resetReasonName(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "poweron";
    case ESP_RST_EXT: return "ext";
    case ESP_RST_SW: return "sw";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "int_wdt";
    case ESP_RST_TASK_WDT: return "task_wdt";
    case ESP_RST_WDT: return "wdt";
    case ESP_RST_DEEPSLEEP: return "deepsleep";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_SDIO: return "sdio";
    default: return "unknown";
  }
}

void startBleAdvertising() {
  if (bleAdvertising == nullptr) return;
  bleAdvertising->start();
  Serial.println("[BLE] Advertising started");
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    uint8_t nonce[AUTH_NONCE_BYTES];
    esp_fill_random(nonce, sizeof(nonce));
    sessionCounter = 0;
    portENTER_CRITICAL(&stateMux);
    memcpy(sessionNonce, nonce, sizeof(sessionNonce));
    pairingActive = false;
    pairingVerified = false;
    pairingConnection = false;
    pairingRefused = false;
    mailbox.connected = true;
    mailbox.error[0] = '\0';
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;
    clearPairingValue();
    Serial.println("[BLE] Central connected");
  }

  void onDisconnect(BLEServer* server) override {
    portENTER_CRITICAL(&stateMux);
    pairingActive = false;
    pairingVerified = false;
    pairingButtonReleased = false;
    pairingRefused = false;
    mailbox.connected = false;
    // loop() clears the maneuver and geometry when this counter changes.
    mailbox.disconnects++;
    // A packet queued before the drop is obsolete and must not be shown.
    mailbox.navReady = false;
    strlcpy(mailbox.error, "BLE disconnected", sizeof(mailbox.error));
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;
    clearPairingValue();
    Serial.println("[BLE] Central disconnected");

    // Critical for iPhone reconnects. While connected, an ESP32 peripheral
    // normally stops advertising. After disconnect it must advertise again,
    // otherwise the app cannot find it until the ESP32 is power-cycled.
    delay(100);
    startBleAdvertising();
  }
};

// Reads up to `maxItems` groups of `stride` route-source coordinates (x, y,
// ...) into `out`, preferring the tenths key over the legacy whole-unit one.
// Stops at the first malformed group; returns the number of groups read.
uint8_t readMapValues(JsonDocument& doc, const char* fineKey, const char* coarseKey,
                      float* out, uint8_t maxItems, uint8_t stride) {
  JsonArray values = doc[fineKey].as<JsonArray>();
  float scale = 0.1f;
  if (values.isNull()) {
    values = doc[coarseKey].as<JsonArray>();
    scale = 1.0f;
  }
  if (values.isNull()) return 0;
  uint8_t count = 0;
  while (count < maxItems && size_t(count + 1) * stride <= values.size()) {
    const size_t base = size_t(count) * stride;
    bool wellFormed = true;
    for (uint8_t i = 0; i < stride; ++i)
      wellFormed = wellFormed && values[base + i].is<int>();
    if (!wellFormed) break;
    for (uint8_t i = 0; i < stride; ++i) {
      const float limit = (i % 2 == 0 ? ROUTE_SOURCE_WIDTH : ROUTE_SOURCE_HEIGHT) - 1;
      const float value = values[base + i].as<int>() * scale;
      out[base + i] = value < 0.0f ? 0.0f : (value > limit ? limit : value);
    }
    ++count;
  }
  return count;
}

class NavWriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const auto rawValue = characteristic->getValue();
    String value(rawValue.c_str());
    value.trim();

    if (value.length() == 0) {
      rejectedPacketCount++;
      publishError("empty packet");
      return;
    }

    // 360 bytes of JSON plus the counter and the 17-byte signature suffix.
    if (value.length() > 400) {
      rejectedPacketCount++;
      publishError("packet too large");
      Serial.println("[BLE] Rejected oversized packet");
      return;
    }

    KeyRing ring;
    uint8_t nonce[AUTH_NONCE_BYTES];
    portENTER_CRITICAL(&stateMux);
    ring = keyRing;
    memcpy(nonce, sessionNonce, sizeof(nonce));
    portEXIT_CRITICAL(&stateMux);
    if (!ring.hasCurrent) {
      rejectedPacketCount++;
      publishError("not paired");
      return;
    }
    // Anyone in range can write to this characteristic; only a phone that
    // paired with a BOOT press can produce a valid tag for this session.
    int jsonLength = -1;
    const AuthKeyMatch keyUsed =
        ring.match(nonce, value.c_str(), value.length(), &jsonLength);
    uint8_t matchedCurrent[AUTH_KEY_BYTES];
    memcpy(matchedCurrent, ring.current, sizeof(matchedCurrent));
    memset(&ring, 0, sizeof(ring));
    if (keyUsed == AuthKeyMatch::None) {
      rejectedPacketCount++;
      publishError("bad signature");
      Serial.println("[BLE] Rejected unauthenticated packet");
      return;
    }

    StaticJsonDocument<768> doc;
    DeserializationError error =
        deserializeJson(doc, value.c_str(), static_cast<size_t>(jsonLength));
    if (error) {
      rejectedPacketCount++;
      publishError("bad json");
      Serial.print("[BLE] JSON error: ");
      Serial.println(error.c_str());
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    // A signed packet from earlier in this session must not be replayed.
    if (!doc["n"].is<uint32_t>() || doc["n"].as<uint32_t>() <= sessionCounter) {
      rejectedPacketCount++;
      publishError("replayed packet");
      memset(matchedCurrent, 0, sizeof(matchedCurrent));
      return;
    }
    sessionCounter = doc["n"].as<uint32_t>();

    // A fully accepted write with the current key on an ordinary connection
    // proves the phone stored it, retiring the previous key. Skip it if a
    // BOOT rotation replaced the current key since it was matched.
    portENTER_CRITICAL(&stateMux);
    if (memcmp(keyRing.current, matchedCurrent, AUTH_KEY_BYTES) == 0 &&
        keyRing.noteUsed(keyUsed, pairingConnection)) {
      mailbox.persistKeys = true;
    }
    portEXIT_CRITICAL(&stateMux);
    memset(matchedCurrent, 0, sizeof(matchedCurrent));

    // Phone-local wall time, separate from navigation: never starts guidance
    // or refreshes the live-navigation packet timeout.
    if (doc["clock"].is<uint32_t>()) {
      const uint32_t seconds = doc["clock"].as<uint32_t>();
      if (seconds < 1700000000UL) {
        publishError("bad clock");
        return;
      }
      timeval now = {static_cast<time_t>(seconds), 0};
      settimeofday(&now, nullptr);
      portENTER_CRITICAL(&stateMux);
      mailbox.clockSynced = true;
      mailbox.wake = true;
      portEXIT_CRITICAL(&stateMux);
      displayDirty = true;
      return;
    }

    const char* dirText = doc["dir"] | "";
    Direction direction = parseDirection(dirText);
    if (direction == Direction::Unknown) {
      rejectedPacketCount++;
      publishBadDirectionError(dirText);
      Serial.print("[BLE] Unknown dir: ");
      Serial.println(dirText);
      Serial.print("[BLE] Raw: ");
      Serial.println(value);
      return;
    }

    if (!doc["dist"].is<int>()) {
      rejectedPacketCount++;
      publishError("bad dist");
      Serial.println("[BLE] Missing/invalid dist");
      return;
    }

    int distance = doc["dist"].as<int>();
    distance = constrain(distance, 0, MAX_DISTANCE_M);

    const bool reroutingPacket = doc["rerouting"] | false;
    const bool endTripPacket = doc["end"] | false;
    if (endTripPacket && (direction != Direction::Stop || reroutingPacket)) {
      rejectedPacketCount++;
      publishError("bad end packet");
      return;
    }
    float mapValues[MAP_VALUE_COUNT] = {};
    const uint8_t routePreviewPointCount = readMapValues(
        doc, "P", "p", mapValues, MAX_ROUTE_PREVIEW_POINTS, 2);
    const uint8_t sideRoadSegmentCount =
        readMapValues(doc, "R", "r", mapValues + MapMotion::kRouteValues,
                      MAX_SIDE_ROAD_SEGMENTS, 4);

    // Publish the whole packet at once so loop() never sees a new direction
    // with the previous distance, flags or geometry.
    portENTER_CRITICAL(&stateMux);
    memcpy(mailbox.map, mapValues, sizeof(mailbox.map));
    mailbox.nav = {direction, distance};
    mailbox.rerouting = reroutingPacket;
    mailbox.tripEnded = endTripPacket;
    mailbox.routes = routePreviewPointCount;
    mailbox.roads = sideRoadSegmentCount;
    mailbox.navReady = true;
    mailbox.error[0] = '\0';
    mailbox.errorReady = true;
    mailbox.wake = true;
    portEXIT_CRITICAL(&stateMux);
    displayDirty = true;

    Serial.print("[NAV] ");
    Serial.print(directionName(direction));
    Serial.print(" ");
    Serial.print(distance);
    Serial.print("m route=");
    Serial.print(routePreviewPointCount);
    Serial.print(" roads=");
    Serial.println(sideRoadSegmentCount);
  }
};

// Pairing: a physical BOOT press confirms the phone in front of the display,
// which then receives the key that signs every navigation write (see PACKET
// AUTH). Kept separate from the navigation characteristic. Every read also
// returns this connection's session nonce.
class PairingCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    uint8_t nonce[AUTH_NONCE_BYTES];
    uint8_t key[AUTH_KEY_BYTES];
    portENTER_CRITICAL(&stateMux);
    // pairingVerified is cleared on every connect/disconnect, so the key is
    // only ever readable on the connection where BOOT was just pressed.
    const bool verified = pairingVerified && keyRing.hasCurrent;
    const bool refused = pairingRefused;
    memcpy(nonce, sessionNonce, sizeof(nonce));
    memcpy(key, keyRing.current, sizeof(key));
    portEXIT_CRITICAL(&stateMux);

    char nonceHex[AUTH_NONCE_BYTES * 2 + 1];
    char keyHex[AUTH_KEY_BYTES * 2 + 1];
    for (size_t i = 0; i < AUTH_NONCE_BYTES; ++i)
      snprintf(nonceHex + i * 2, 3, "%02x", nonce[i]);
    for (size_t i = 0; i < AUTH_KEY_BYTES; ++i)
      snprintf(keyHex + i * 2, 3, "%02x", key[i]);
    memset(key, 0, sizeof(key));

    const char* boot = resetReasonName(esp_reset_reason());
    const unsigned long uptime = millis() / 1000;
    // How this display confirms a pairing, so the app can say what to do.
    const char* confirm = NAV_PAIR_ON_POWER_UP ? "power" : "boot";
    char response[256];
    if (verified) {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":true,\"s\":\"%s\",\"k\":\"%s\","
               "\"boot\":\"%s\",\"up\":%lu,\"confirm\":\"%s\"}",
               deviceIdentity, nonceHex, keyHex, boot, uptime, confirm);
    } else {
      snprintf(response, sizeof(response),
               "{\"id\":\"%s\",\"verified\":false,\"s\":\"%s\","
               "\"boot\":\"%s\",\"up\":%lu,\"confirm\":\"%s\"%s}",
               deviceIdentity, nonceHex, boot, uptime, confirm,
               refused ? ",\"replug\":true" : "");
    }
    memset(keyHex, 0, sizeof(keyHex));
    characteristic->setValue(response);
  }
  void onWrite(BLECharacteristic* characteristic) override {
    const auto value = characteristic->getValue();
    StaticJsonDocument<128> doc;
    if (value.length() > 80 || deserializeJson(doc, value.c_str())) return;
    const char* action = doc["pair"] | "";
    if (strcmp(action, "start") == 0) {
#if NAV_PAIR_ON_POWER_UP
      if (pairWindowUsed || millis() >= PAIR_WINDOW_MS) {
        portENTER_CRITICAL(&stateMux);
        pairingRefused = true;
        portEXIT_CRITICAL(&stateMux);
        Serial.println("[BLE] Pairing refused: replug the display to pair");
        return;
      }
#endif
      portENTER_CRITICAL(&stateMux);
      pairingRefused = false;
      pairingStartedMs = millis();
      pairingActive = true;
      pairingVerified = false;
      pairingButtonReleased = false; // Require a fresh press after arming.
      bootLowSinceMs = 0;
      mailbox.wake = true;
      portEXIT_CRITICAL(&stateMux);
      displayDirty = true;
    }
  }
};

void setupBle() {
  BLEDevice::init(DEVICE_NAME);
  // Stability first: use positive TX power so the phone can rediscover the
  // device reliably after power switch cycles and app backgrounding.
  BLEDevice::setPower(ESP_PWR_LVL_P3);
  // Accept a large MTU so a signed packet (~170 bytes) arrives in one write.
  // The local default is 23, which would force Android into slower queued
  // long writes. iOS negotiates its own (typically 185).
  BLEDevice::setMTU(517);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);
  BLECharacteristic* pairing = service->createCharacteristic(
      PAIRING_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pairing->setCallbacks(new PairingCallbacks());
  pairingCharacteristic = pairing;

  BLECharacteristic* characteristic = service->createCharacteristic(
      CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  characteristic->setCallbacks(new NavWriteCallbacks());

  service->start();

  bleAdvertising = BLEDevice::getAdvertising();
  bleAdvertising->addServiceUUID(SERVICE_UUID);
  bleAdvertising->setScanResponse(true);
  bleAdvertising->setMinPreferred(0x06);
  bleAdvertising->setMinPreferred(0x12);
  startBleAdvertising();
}

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
    nativeLayer.drawText(font, value, left * NATIVE_SCALE,
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
    panelComposer.compose(source, layer, band, y, rows);
    const uint32_t transferStartUs = micros();
    tft.draw16bitRGBBitmap(PANEL_VIEW_X, PANEL_VIEW_Y + y, band, PANEL_VIEW_WIDTH, rows);
    lastFrameTransferUs += micros() - transferStartUs;
  }
  nativeLayerDrawn = false;
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

void drawSideRoadSegments() {
  for (uint8_t i = 0; i < mapMotion.roads; i++) {
    const float* p = mapMotion.current + MapMotion::kRouteValues + i * 4;
    drawSideRoadLine(mapPreviewX(p[0]), mapPreviewY(p[1]),
                     mapPreviewX(p[2]), mapPreviewY(p[3]));
  }
}

#if NAV_ROUND_DISPLAY
// The instruction row sits where the round aperture narrows. These values
// keep every arrow (stroke included) and the widest distance text ("NOW")
// 3 canvas px inside the visible circle of the full 412 px view, below the
// map, with the arrow and the text centred on the same line.
constexpr float INSTRUCTION_SCALE = 1.0f;
constexpr float INSTRUCTION_CENTER_X = 67.5f;
constexpr float INSTRUCTION_CENTER_Y = 185.5f;
// Size-4 distance text: right edge, and top of its capitals (baseline 199).
constexpr float DISTANCE_RIGHT = 203.0f;
constexpr float DISTANCE_TOP = 171.0f;
#endif

// Arrow artwork is drawn in the original strip's coordinates, centred on
// (66, 111.5).
float instructionX(float x) {
#if NAV_ROUND_DISPLAY
  return INSTRUCTION_CENTER_X + (x - 66.0f) * INSTRUCTION_SCALE;
#else
  return x;
#endif
}

float instructionY(float y) {
#if NAV_ROUND_DISPLAY
  return INSTRUCTION_CENTER_Y + (y - 111.5f) * INSTRUCTION_SCALE;
#else
  return y;
#endif
}

void drawInstructionLine(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                         uint8_t thickness = 3) {
  drawStroke(instructionX(x0), instructionY(y0), instructionX(x1),
             instructionY(y1),
#if NAV_ROUND_DISPLAY
             thickness + 1
#else
             thickness
#endif
  );
}

void fillInstructionTriangle(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                             int16_t x2, int16_t y2) {
  fillUiTriangle(instructionX(x0), instructionY(y0), instructionX(x1),
                 instructionY(y1), instructionX(x2), instructionY(y2));
}

void drawArrowUp() {
  drawInstructionLine(ARROW_CENTER_X, 128, ARROW_CENTER_X, 98);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X - 15, 113);
  drawInstructionLine(ARROW_CENTER_X, 98, ARROW_CENTER_X + 15, 113);
}

void drawArrowLeft() {
  drawInstructionLine(82, 128, 82, 116);
  drawInstructionLine(82, 116, 74, 106);
  drawInstructionLine(74, 106, 42, 106);
  drawInstructionLine(42, 106, 60, 93);
  drawInstructionLine(42, 106, 60, 119);
}

void drawArrowRight() {
  drawInstructionLine(48, 128, 48, 116);
  drawInstructionLine(48, 116, 56, 106);
  drawInstructionLine(56, 106, 88, 106);
  drawInstructionLine(88, 106, 70, 93);
  drawInstructionLine(88, 106, 70, 119);
}

void drawBearLeft() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 62, 112, 4);
  drawInstructionLine(62, 112, 50, 100, 4);
  fillInstructionTriangle(43, 96, 61, 99, 46, 114);
}

void drawBearRight() {
  drawInstructionLine(66, 128, 66, 118, 4);
  drawInstructionLine(66, 118, 70, 112, 4);
  drawInstructionLine(70, 112, 82, 100, 4);
  fillInstructionTriangle(89, 96, 71, 99, 86, 114);
}

void drawUTurn() {
  drawInstructionLine(82, 128, 82, 100);
  drawInstructionLine(82, 100, 44, 100);
  drawInstructionLine(44, 100, 44, 120);
  drawInstructionLine(44, 120, 31, 107);
  drawInstructionLine(44, 120, 57, 107);
}

void drawStop() {
#if NAV_ROUND_DISPLAY
  if (useNativeLayer()) {
    nativeLayer.fillRoundRect(instructionX(42) * NATIVE_SCALE,
                              instructionY(98) * NATIVE_SCALE,
                              instructionX(90) * NATIVE_SCALE,
                              instructionY(128) * NATIVE_SCALE, 5 * NATIVE_SCALE, 255);
    return;
  }
#endif
  display.fillRoundRect(lroundf(instructionX(42)), lroundf(instructionY(98)),
                        lroundf(instructionX(90) - instructionX(42)),
                        lroundf(instructionY(128) - instructionY(98)), 5, COLOR_WHITE);
}

void drawArrived() {
  drawInstructionLine(34, 114, 56, 130);
  drawInstructionLine(56, 130, 94, 94);
}

void drawUnknown() {
  drawUiText("?", 2, instructionX(22), instructionY(105));
}

void drawDirection(Direction direction) {
  switch (direction) {
    case Direction::Up:
      drawArrowUp();
      break;
    case Direction::Left:
      drawArrowLeft();
      break;
    case Direction::Right:
      drawArrowRight();
      break;
    case Direction::BearLeft:
      drawBearLeft();
      break;
    case Direction::BearRight:
      drawBearRight();
      break;
    case Direction::UTurn:
      drawUTurn();
      break;
    case Direction::Stop:
      drawStop();
      break;
    case Direction::Arrived:
      drawArrived();
      break;
    default:
      drawUnknown();
      break;
  }
}

void drawFallbackMapRoute(Direction direction) {
  const int16_t centerX = (MAP_LEFT + MAP_RIGHT) / 2;
  const int16_t bottom = MAP_BOTTOM - 8;
  const int16_t top = MAP_TOP + 12;
  const int16_t left = MAP_LEFT + 28;
  const int16_t right = MAP_RIGHT - 28;

  switch (direction) {
    case Direction::Left:
      drawStroke(centerX, bottom, centerX, 55, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 55, centerX - 18, 42, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX - 18, 42, left, 42, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::Right:
      drawStroke(centerX, bottom, centerX, 55, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 55, centerX + 18, 42, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX + 18, 42, right, 42, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearLeft:
      drawStroke(centerX, bottom, centerX, 58, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 58, centerX - 44, top, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::BearRight:
      drawStroke(centerX, bottom, centerX, 58, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 58, centerX + 44, top, FALLBACK_ROUTE_STROKE);
      break;
    case Direction::UTurn:
      drawStroke(centerX, bottom, centerX, 36, FALLBACK_ROUTE_STROKE);
      drawStroke(centerX, 36, left + 28, 36, FALLBACK_ROUTE_STROKE);
      drawStroke(left + 28, 36, left + 28, 68, FALLBACK_ROUTE_STROKE);
      break;
    default:
      drawStroke(centerX, bottom, centerX, top, FALLBACK_ROUTE_STROKE);
      break;
  }
}

void drawMiniRouteMap(bool showRider, Direction direction) {
#if NAV_ROUND_DISPLAY
  // Legacy preview coordinates can extend below the map; keep them out of
  // the instruction strip.
  nativeLayer.clipBottom = int16_t(MAP_CLIP_BOTTOM * NATIVE_SCALE);
#endif
  drawSideRoadSegments();

  if (mapMotion.routes >= 2) {
    for (uint8_t i = 0; i + 1 < mapMotion.routes; i++) {
      const float* p = mapMotion.current + i * 2;
      drawStroke(mapPreviewX(p[0]), mapPreviewY(p[1]),
                  mapPreviewX(p[2]), mapPreviewY(p[3]), ROUTE_STROKE);
    }
  } else {
    drawFallbackMapRoute(direction);
  }

  if (showRider) {
    const int16_t markerX = (MAP_LEFT + MAP_RIGHT) / 2;
    const int16_t markerY = MAP_BOTTOM - 12;
    // Only live guidance may show a rider marker. A cached snapshot no longer
    // establishes the bike's current position relative to this road shape.
#if NAV_ROUND_DISPLAY
    if (useNativeLayer()) {
      const float x = layerCoord(markerX), y = layerCoord(markerY);
      constexpr float s = NATIVE_SCALE;
      nativeLayer.fillTriangle(x, y - 21 * s, x - 18 * s, y + 14 * s, x + 18 * s,
                            y + 14 * s, 0);
      nativeLayer.fillTriangle(x, y - 12 * s, x - 10 * s, y + 6 * s, x + 10 * s,
                            y + 6 * s, 255);
    } else {
      display.fillTriangle(markerX, markerY - 21, markerX - 18, markerY + 14,
                           markerX + 18, markerY + 14, COLOR_BG);
      display.fillTriangle(markerX, markerY - 12, markerX - 10, markerY + 6,
                           markerX + 10, markerY + 6, COLOR_WHITE);
    }
#else
    display.fillTriangle(markerX, markerY - 15, markerX - 13, markerY + 10,
                         markerX + 13, markerY + 10, COLOR_BG);
    display.fillTriangle(markerX, markerY - 8, markerX - 7, markerY + 4,
                         markerX + 7, markerY + 4, COLOR_WHITE);
#endif
  }

  // Legacy preview coordinates can extend below the map. Keep them out of
  // the instruction strip without drawing a visible frame or separator.
  display.fillRect(0, MAP_CLIP_BOTTOM, SCREEN_WIDTH, SCREEN_HEIGHT - MAP_CLIP_BOTTOM,
                   COLOR_BG);
#if NAV_ROUND_DISPLAY
  nativeLayer.clipBottom = nativeLayer.height;
#endif
}

#if NAV_ROUND_DISPLAY
// Returns the drawn width.
uint16_t drawFallbackDistanceText(const char* value, const GFXfont* font,
                                  int16_t anchorX, int16_t top, bool rightAligned) {
  int16_t x, y;
  uint16_t width, height;
  display.setFont(font);
  display.setTextSize(1);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor(anchorX - (rightAligned ? int16_t(width) : 0) - x, top - y);
  display.print(value);
  display.setFont(nullptr);
  return width;
}
#endif

void drawDistance(const NavState& navigation, bool blinkState) {
  const int distanceMeters = navigation.distanceMeters;
  display.setTextColor(COLOR_WHITE);
#if NAV_ROUND_DISPLAY
  // The circle narrows at the bottom: lay the group out leftwards from the
  // safe right edge, unit first, both on the same baseline.
  const char* label = nullptr;
  const char* unit = nullptr;
  char number[8];
  if (navigation.direction == Direction::Arrived) {
    label = "ARR";
  } else if (distanceMeters <= 30) {
    if (blinkState) label = "NOW";
  } else {
    if (distanceMeters < 1000) {
      snprintf(number, sizeof(number), "%d", distanceMeters);
    } else {
      snprintf(number, sizeof(number), "%.1f", distanceMeters / 1000.0);
    }
    label = number;
    unit = distanceMeters < 1000 ? "m" : "km";
  }
  float right = DISTANCE_RIGHT;
  if (!useNativeLayer()) {
    if (unit != nullptr)
      right -= drawFallbackDistanceText(unit, &FreeSans9pt7b, lroundf(right),
                                        DISTANCE_TOP + 15, true) + 3;
    if (label != nullptr)
      drawFallbackDistanceText(label, &FreeSansBold18pt7b, lroundf(right),
                               DISTANCE_TOP, true);
    return;
  }
  if (unit != nullptr) {
    right -= uiTextWidth(unit, 2);
    drawUiText(unit, 2, right, DISTANCE_TOP + 14);
    right -= 3;
  }
  if (label != nullptr) drawUiText(label, 4, right - uiTextWidth(label, 4), DISTANCE_TOP);
#else
  display.setTextSize(3);
  display.setCursor(DISTANCE_X, 104);
  if (navigation.direction == Direction::Arrived) {
    display.println("ARR");
    return;
  }

  if (distanceMeters <= 30) {
    if (blinkState) {
      display.println("NOW");
    }
  } else if (distanceMeters < 1000) {
    display.print(distanceMeters);
    display.println("m");
  } else {
    display.print(distanceMeters / 1000.0, 1);
    display.println("k");
  }
#endif
}

void drawBottomError() {
  if (lastError[0] == '\0') return;

  display.setTextColor(COLOR_ACCENT);
#if NAV_ROUND_DISPLAY
  // Below the distance the round aperture is narrow: centre the message there
  // and drop trailing characters until it fits the visible width at its
  // lowest row (3 px margin).
  constexpr float top = 208.0f;
  const float dy = top + 7.0f - SCREEN_HEIGHT / 2.0f;
  const float radius = PANEL_VISIBLE_RADIUS * float(SCREEN_WIDTH) / PANEL_VIEW_WIDTH - 3.0f;
  const float available = 2.0f * sqrtf(fmaxf(0.0f, radius * radius - dy * dy));
  char visible[25];
  strlcpy(visible, lastError, sizeof(visible));
  for (size_t length = strlen(visible); length > 0 && uiTextWidth(visible, 1) > available;)
    visible[--length] = '\0';
  drawRoundCenteredText(visible, 1, top);
#else
  display.setTextSize(1);
  display.setCursor(8, SCREEN_HEIGHT - 10);
  display.print(lastError);
#endif
}

#if NAV_ROUND_DISPLAY
uint16_t roundTextHeight(const char* value, uint8_t size) {
  if (useNativeLayer()) return 7 * size;
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  return height;
}

void drawRoundCenteredText(const char* value, uint8_t size, int16_t top) {
  if (useNativeLayer()) {
    drawUiText(value, size, (SCREEN_WIDTH - uiTextWidth(value, size)) / 2.0f, top);
    return;
  }
  int16_t x, y;
  uint16_t width, height;
  display.setTextSize(size);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor((SCREEN_WIDTH - width) / 2 - x, top - y);
  display.print(value);
}

void drawRoundCenteredStatus(const char* primary, uint8_t primarySize,
                             const char* secondary = nullptr,
                             uint8_t secondarySize = 1) {
  const int16_t primaryHeight = roundTextHeight(primary, primarySize);
  const int16_t secondaryHeight = secondary == nullptr
                                      ? 0
                                      : roundTextHeight(secondary, secondarySize);
  const int16_t gap = secondary == nullptr ? 0 : 18;
  const int16_t top = (SCREEN_HEIGHT - primaryHeight - gap - secondaryHeight) / 2;
  drawRoundCenteredText(primary, primarySize, top);
  if (secondary != nullptr)
    drawRoundCenteredText(secondary, secondarySize, top + primaryHeight + gap);
}

// Keep the idle brand legible even when the native gray layer could not be
// allocated. GFX's built-in font scales square pixels; outline-derived fonts
// give the fallback a proper sans-serif shape instead.
void drawStandbyBrandText(const char* value, bool primary) {
  const GFXfont* font = primary ? &FreeSansBold24pt7b : &FreeSans9pt7b;
  const int16_t centerY = primary ? 105 : 146;
  int16_t x, y;
  uint16_t width, height;
  display.setFont(font);
  display.setTextSize(1);
  display.getTextBounds(value, 0, 0, &x, &y, &width, &height);
  display.setCursor((SCREEN_WIDTH - width) / 2 - x,
                    centerY - int16_t(height / 2) - y);
  display.print(value);
  display.setFont(nullptr);
}
#endif

void renderDisplay(const UiState& state, bool blinkState) {
  char clockText[6] = "";
  if (state.screen == UiScreen::Clock) {
    const time_t now = time(nullptr);
    struct tm localClock;
    // The phone has already applied its local UTC offset.
    gmtime_r(&now, &localClock);
    snprintf(clockText, sizeof(clockText), "%02d:%02d", localClock.tm_hour,
             localClock.tm_min);
  }
  const UiRenderContext context = {
      DEVICE_NAME, clockText, SCREEN_HEIGHT,
#if NAV_ROUND_DISPLAY
      DISTANCE_TOP,
#else
      100.0f,
#endif
      float(DISTANCE_X)};
  renderUiScreen(state, context, blinkState);
}

// ======================================================
// State updates
// ======================================================

void updateLiveTimeout() {
  if (lastLivePacketMs == 0) return;
  if (isLiveFresh()) return;

  if (!livePacketTimedOut) {
    livePacketTimedOut = true;
    displayDirty = true;
  }

  // Keep the last direction: only an explicit STOP packet replaces it.
  // The UI resolver marks it as stale instead. The app re-sends every ~2 s
  // while stopped, backed by a fresh fix, so a timeout means a real problem.
  setLastError("");
}

void updateDisplayPower() {
  if (shouldKeepDisplayAwake()) {
    wakeDisplay();
    return;
  }

  const uint32_t idleMs = millis() - lastDisplayActivityMs;
  if (idleMs >= DISPLAY_OFF_AFTER_IDLE_MS) {
    setDisplayPower(DisplayPowerState::Off);
  } else if (idleMs >= DISPLAY_DIM_AFTER_IDLE_MS) {
    setDisplayPower(DisplayPowerState::Dim);
  } else {
    setDisplayPower(DisplayPowerState::On);
  }
}

#if NAV_WAVESHARE_146
bool readExpanderRegister(uint8_t reg, uint8_t& value) {
  Wire.beginTransmission(IO_EXPANDER_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(IO_EXPANDER_ADDRESS, uint8_t(1)) != 1) return false;
  value = Wire.read();
  return true;
}

bool writeExpanderRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(IO_EXPANDER_ADDRESS);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool resetRoundPanel() {
  // Preserve every unrelated expander pin (touch reset, SD CS, etc.).
  uint8_t output, config;
  if (!readExpanderRegister(0x01, output) ||
      !readExpanderRegister(0x03, config)) return false;
  if (!writeExpanderRegister(0x01, output & ~LCD_RESET_MASK) ||
      !writeExpanderRegister(0x03, config & ~LCD_RESET_MASK)) return false;
  delay(50);
  if (!writeExpanderRegister(0x01, output | LCD_RESET_MASK)) return false;
  delay(120);
  return true;
}
#endif

bool initDisplay() {
  if (!display.getBuffer()) {
    Serial.println("[TFT] Canvas allocation failed");
    return false;
  }
#if NAV_ROUND_DISPLAY
#if NAV_JC3636W518C
  Serial.println("[TFT] init JC3636W518C ST77916 QSPI (vendor command transactions)...");
#else
  Serial.println("[TFT] init Waveshare 1.46 SPD2010 QSPI...");
#endif
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, 0);
#if NAV_WAVESHARE_146
  if (!Wire.begin(BOARD_I2C_SDA_PIN, BOARD_I2C_SCL_PIN, 400000) ||
      !resetRoundPanel()) {
    Serial.println("[TFT] TCA9554 reset failed (address 0x20)");
    return false;
  }
#endif
  if (!tft.begin(40000000)) {
    Serial.println("[TFT] QSPI initialization failed");
    return false;
  }
#if NAV_JC3636W518C
  tft.invertDisplay(true);  // Same polarity as the manufacturer's LCD demo.
#endif
  tft.fillScreen(COLOR_BG);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);
  panelComposer.init(PANEL_VIEW_WIDTH, PANEL_VIEW_HEIGHT, SCREEN_WIDTH, SCREEN_HEIGHT,
                     PANEL_SIZE / 2.0f - PANEL_VIEW_X, PANEL_SIZE / 2.0f - PANEL_VIEW_Y,
                     PANEL_VISIBLE_RADIUS, NATIVE_LAYER_SIZE, NATIVE_LAYER_SIZE);
  nativeLayer.pixels = static_cast<uint8_t*>(heap_caps_malloc(
      size_t(NATIVE_LAYER_SIZE) * NATIVE_LAYER_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (nativeLayer.pixels != nullptr) {
    nativeLayer.width = NATIVE_LAYER_SIZE;
    nativeLayer.height = NATIVE_LAYER_SIZE;
    nativeLayer.clipBottom = NATIVE_LAYER_SIZE;
    nativeLayer.clear();
    Serial.printf("[TFT] NAVIO UI: %dx%d anti-aliased rendering -> %dx%d panel\n",
                  NATIVE_LAYER_SIZE, NATIVE_LAYER_SIZE, PANEL_VIEW_WIDTH, PANEL_VIEW_HEIGHT);
  } else {
    Serial.println("[TFT] NAVIO UI: low-resolution fallback (check OPI PSRAM setting)");
  }
#if NAV_JC3636W518C
  Serial.println("[TFT] ST77916 360x360 ready");
#else
  Serial.println("[TFT] SPD2010 412x412 ready");
#endif
#else
  Serial.println("[TFT] init ST7789...");
  pinMode(TFT_BACKLIGHT_PIN, OUTPUT);
  analogWrite(TFT_BACKLIGHT_PIN, BACKLIGHT_NORMAL);

  SPI.begin(TFT_SCLK_PIN, -1, TFT_MOSI_PIN, TFT_CS_PIN);
  tft.init(SCREEN_HEIGHT, SCREEN_WIDTH);
  tft.setRotation(TFT_ROTATION);
  tft.fillScreen(COLOR_BG);
  Serial.println("[TFT] ST7789 ready");
#endif
  return true;
}

// ======================================================
// Arduino lifecycle
// ======================================================

void setup() {
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(deviceIdentity, sizeof(deviceIdentity), "%04X%08lX",
           static_cast<unsigned int>((chipId >> 32) & 0xffff),
           static_cast<unsigned long>(chipId & 0xffffffff));
  snprintf(DEVICE_NAME, sizeof(DEVICE_NAME), "NAVIO-%s", deviceIdentity);
  Serial.begin(115200);
  delay(100);
  Serial.println();
  Serial.println("[BOOT] ESP32 navigation display");
  Serial.print("[BOOT] reset reason: ");
  Serial.println(resetReasonName(esp_reset_reason()));

  displayAvailable = initDisplay();
  if (!displayAvailable) {
    Serial.println("[TFT] init failed");
    Serial.println("[TFT] continuing without display so BLE still works");
  } else {
    refreshUiState();
    renderDisplay(uiState, true);
  }
  wakeDisplay();

  loadAuthKey();
  setupBle();
  Serial.println("[BOOT] Ready");
}

void updatePairing() {
  bool changed = false;
  bool confirmed = false;
  // The BLE task can re-arm pairing at any moment; keep this check atomic.
  portENTER_CRITICAL(&stateMux);
  const uint32_t connection = mailbox.disconnects;
  if (pairingActive && millis() - pairingStartedMs >= 60000) {
    pairingActive = false;
    changed = true;
  }
#if NAV_PAIR_ON_POWER_UP
  // The request already arrived inside the power-up window: confirm it, and
  // close the window so a second phone cannot pair before the next power-on.
  if (pairingActive) {
    pairingActive = false;
    pairWindowUsed = true;
    changed = confirmed = true;
  }
#else
  if (pairingActive) {
    if (digitalRead(BOOT_BUTTON_PIN) == HIGH) {
      pairingButtonReleased = true;
      bootLowSinceMs = 0;
    } else if (pairingButtonReleased) {
      if (bootLowSinceMs == 0) bootLowSinceMs = millis();
      if (millis() - bootLowSinceMs >= 80) {
        pairingActive = false;
        pairingButtonReleased = false;
        changed = confirmed = true;
      }
    }
  }
#endif
  portEXIT_CRITICAL(&stateMux);
  if (changed) displayDirty = true;
  if (!confirmed) return;

  // The NVS write happens outside the critical section. Publish "verified"
  // (which makes the new key readable) only if the phone that started pairing
  // is still connected. If it left, the rotation is harmless: the previously
  // proven key keeps working until the new one is proven (see KeyRing).
  bool stillConnected;
  portENTER_CRITICAL(&stateMux);
  stillConnected = mailbox.disconnects == connection && mailbox.connected;
  portEXIT_CRITICAL(&stateMux);
  if (!stillConnected) {
    Serial.println("[BLE] Pairing phone left before confirmation");
    return;
  }
  if (!issueAuthKey()) {
    setLastError("pairing key save failed");
    Serial.println("[AUTH] Could not store pairing key");
    return;
  }
  bool sameConnection;
  portENTER_CRITICAL(&stateMux);
  sameConnection = mailbox.disconnects == connection && mailbox.connected;
  if (sameConnection) {
    pairingVerified = true;
    pairingConnection = true;
  }
  portEXIT_CRITICAL(&stateMux);
  Serial.println(sameConnection ? (NAV_PAIR_ON_POWER_UP
                                     ? "[BLE] Pairing confirmed within power-up window"
                                     : "[BLE] Pairing confirmed with BOOT")
                                : "[BLE] Pairing phone left before confirmation");
}

// Applies everything the BLE task published since the previous iteration.
void applyBleMailbox() {
  static uint32_t seenDisconnects = 0;
  BleMailbox snapshot;
  portENTER_CRITICAL(&stateMux);
  snapshot = mailbox;
  mailbox.navReady = false;
  mailbox.errorReady = false;
  mailbox.wake = false;
  mailbox.persistKeys = false;
  KeyRing ringToPersist;
  if (snapshot.persistKeys) ringToPersist = keyRing;
  portEXIT_CRITICAL(&stateMux);

  if (snapshot.persistKeys) {
    // A failed write only delays retiring the previous key: the RAM ring is
    // already correct and both keys stay accepted after a reboot.
    if (persistKeyRing(ringToPersist)) {
      Serial.println("[AUTH] New pairing key proven; previous key retired");
    } else {
      Serial.println("[AUTH] Could not persist proven key; will retry");
      portENTER_CRITICAL(&stateMux);
      mailbox.persistKeys = true;
      portEXIT_CRITICAL(&stateMux);
    }
    memset(&ringToPersist, 0, sizeof(ringToPersist));
  }

  if (snapshot.disconnects != seenDisconnects) {
    // Counted, so a drop and reconnect between two iterations still clears
    // the last maneuver and map geometry.
    seenDisconnects = snapshot.disconnects;
    hasReceivedNavPacket = false;
    lastLivePacketMs = 0;
    livePacketTimedOut = false;
    nav = {Direction::Stop, 0};
    rerouting = false;
    displayDirty = true;
  }
  if (snapshot.connected) hadBleConnection = true;
  bleConnected = snapshot.connected;
  clockSynced = snapshot.clockSynced;
  if (snapshot.errorReady) setLastError(snapshot.error);
  if (snapshot.navReady) {
    nav = snapshot.nav;
    rerouting = snapshot.rerouting;
    tripEnded = snapshot.tripEnded;
    lastLivePacketMs = tripEnded ? 0 : millis();
    livePacketTimedOut = false;
    hasReceivedNavPacket = !tripEnded;
    displayDirty = true;
  }
  if (snapshot.wake) wakeDisplay();

  if (!bleConnected || !hasReceivedNavPacket ||
      (nav.direction == Direction::Stop && !rerouting)) {
    mapMotion.valid = false;
    mapMotion.active = false;
  }
  if (snapshot.navReady && !snapshot.tripEnded) {
    mapMotion.accept(snapshot.map, snapshot.routes, snapshot.roads, millis());
  }
}

// Aggregate actual frame work; idle gaps are deliberately not called low FPS.
// A 40 FPS target leaves 25 ms per frame, including panel transfer.
void reportRenderTiming(uint32_t frameUs, uint32_t transferUs) {
  static uint32_t frames = 0, peakUs = 0, lastReportMs = 0;
  static uint64_t totalUs = 0, totalTransferUs = 0;
  ++frames;
  totalUs += frameUs;
  totalTransferUs += transferUs;
  if (frameUs > peakUs) peakUs = frameUs;
  const uint32_t now = millis();
  if (lastReportMs != 0 && now - lastReportMs < 5000) return;
  Serial.printf("[RENDER] frames=%lu frame_ms=%.1f max_ms=%.1f cpu_ms=%.1f lcd_ms=%.1f budget_ms=%lu\n",
                static_cast<unsigned long>(frames), double(totalUs) / frames / 1000.0,
                peakUs / 1000.0, double(totalUs - totalTransferUs) / frames / 1000.0,
                double(totalTransferUs) / frames / 1000.0,
                static_cast<unsigned long>(DISPLAY_REFRESH_MS));
  frames = peakUs = 0;
  totalUs = totalTransferUs = 0;
  lastReportMs = now;
}

void loop() {
  updatePairing();
  applyBleMailbox();
  updateLiveTimeout();
  updateDisplayPower();
  refreshUiState();
  if (mapMotion.tick(millis())) displayDirty = true;
  static time_t lastClockMinute = -1;
  const time_t clockMinute = time(nullptr) / 60;
  if (clockMinute != lastClockMinute) {
    lastClockMinute = clockMinute;
    if (uiState.screen == UiScreen::Clock) displayDirty = true;
  }
  static bool blinkState = true;
  static uint32_t lastBlinkMs = 0;
  static uint32_t lastRenderMs = 0;

  if (millis() - lastBlinkMs > 300) {
    blinkState = !blinkState;
    lastBlinkMs = millis();
    if (uiState.screen == UiScreen::Navigating &&
        uiState.navigation.distanceMeters <= 30) {
      displayDirty = true;
    }
  }

  if (displayDirty && millis() - lastRenderMs >= DISPLAY_REFRESH_MS) {
    lastRenderMs = millis();
    // Clear before drawing so a BLE callback arriving during the SPI transfer
    // schedules another frame instead of having its update erased here.
    displayDirty = false;
    const uint32_t renderStartUs = micros();
    renderDisplay(uiState, blinkState);
    if (uiState.screen != UiScreen::Off)
      reportRenderTiming(micros() - renderStartUs, lastFrameTransferUs);
  }

  delay(5);
}
